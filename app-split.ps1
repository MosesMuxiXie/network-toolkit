param(
    [int]$Port = 1080,
    [ValidateSet('split', 'primary', 'secondary')][string]$Mode = 'split',
    [string]$Primary = '',
    [string]$Secondary = '',
    [switch]$List,
    [switch]$Verify,
    [switch]$Stop,
    [int]$ProcId = 0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-ProxyAlive {
    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Start-Proxy {
    if (Test-ProxyAlive) { return }
    Write-Host "启动分流器（$Mode）于 127.0.0.1:$Port ..."
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'split-proxy.ps1'), '-Port', "$Port", '-Mode', $Mode)
    if ($Primary) { $childArgs += @('-Primary', $Primary) }
    if ($Secondary) { $childArgs += @('-Secondary', $Secondary) }
    Start-Process powershell.exe -ArgumentList $childArgs -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-ProxyAlive) { return }
    }
    $tail = (Get-Content (Join-Path $env:TEMP 'split-proxy.log') -Tail 3 -ErrorAction SilentlyContinue) -join "`n"; throw ("分流器启动失败：" + $tail)
}

function Stop-Proxy {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $c) { Write-Host "分流器本来就没在跑。"; return }
    foreach ($conn in $c) {
        try { Stop-Process -Id $conn.OwningProcess -Force; Write-Host "已停止分流器 PID=$($conn.OwningProcess)" } catch {}
    }
}

function Get-Candidates {
    $netPids = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique)
    $all = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object Id, ProcessName, MainWindowTitle, Path, @{n = 'Net'; e = { $netPids -contains $_.Id } }
    return $all | Sort-Object @{ Expression = 'Net'; Descending = $true }, ProcessName
}

$script:StaticCache = @{}

$SupportFull = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'curl', 'aria2c', 'wget', 'powershell', 'pwsh', 'python', 'python3', 'node', 'git', '7z', 'idman', 'qbittorrent', 'transmission', 'fdm', 'discord', 'telegram', 'code', 'vscode')
$SupportPartial = @('thunder', 'xunlei', 'weixin', 'wechat', 'qq', 'baidunetdisk', 'quark', 'aliyundrive', 'dingtalk', 'feishu', 'wps')
$SupportNone = @('steam', 'steamwebhelper', 'epicgameslauncher', 'battle.net', 'battlenet', 'origin', 'eadesktop', 'ubisoftconnect', 'uplay', 'uu', 'xunyou', 'wegame', 'riotclient', 'leagueclient', 'msiexec')

function Get-RvaOffset($sections, [uint32]$rva) {
    foreach ($s in $sections) {
        $size = [Math]::Max([int64]$s.VSize, [int64]$s.RawSize)
        if ($rva -ge $s.VA -and $rva -lt ([int64]$s.VA + $size)) { return [int64]$s.Raw + ([int64]$rva - [int64]$s.VA) }
    }
    return [int64]-1
}

function Get-PeImports([string]$path) {
    $names = @()
    $fs = $null; $br = $null
    try {
        $fs = [IO.File]::OpenRead($path)
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $lfanew = [int64]$br.ReadInt32()
        $fs.Position = $lfanew
        if ($br.ReadUInt32() -ne 0x4550) { return $names }
        $fs.Position = $lfanew + 6
        $numSections = [int]$br.ReadUInt16()
        $fs.Position = $lfanew + 20
        $optSize = [int]$br.ReadUInt16()
        $optStart = $lfanew + 24
        $fs.Position = $optStart
        $magic = $br.ReadUInt16()
        $dataDirOff = if ($magic -eq 0x20B) { $optStart + 112 } else { $optStart + 96 }
        $fs.Position = $dataDirOff + 8
        $importRva = [uint32]$br.ReadUInt32()
        if ($importRva -eq 0) { return $names }
        $sections = @()
        $secStart = $optStart + $optSize
        for ($i = 0; $i -lt $numSections; $i++) {
            $fs.Position = $secStart + $i * 40
            [void]$br.ReadBytes(8)
            $vsize = [uint32]$br.ReadUInt32(); $vaddr = [uint32]$br.ReadUInt32()
            $rawsize = [uint32]$br.ReadUInt32(); $rawptr = [uint32]$br.ReadUInt32()
            $sections += [pscustomobject]@{ VSize = $vsize; VA = $vaddr; RawSize = $rawsize; Raw = $rawptr }
        }
        $off = Get-RvaOffset $sections $importRva
        if ($off -lt 0) { return $names }
        for ($k = 0; $k -lt 300; $k++) {
            $fs.Position = $off + $k * 20
            $nameRva = [uint32]$br.ReadUInt32()
            [void]$br.ReadBytes(16)
            if ($nameRva -eq 0) { break }
            $noff = Get-RvaOffset $sections $nameRva
            if ($noff -lt 0) { continue }
            $fs.Position = $noff
            $sb = New-Object Text.StringBuilder
            for ($j = 0; $j -lt 256; $j++) {
                $b = $br.ReadByte()
                if ($b -eq 0) { break }
                [void]$sb.Append([char]$b)
            }
            $names += $sb.ToString()
        }
    }
    catch { }
    finally { if ($br) { $br.Dispose() }; if ($fs) { $fs.Dispose() } }
    return $names
}

function Get-FrameworkHints([string]$path) {
    $out = @()
    try {
        $dir = Split-Path -Parent $path
        if (Test-Path (Join-Path $dir 'resources\app.asar')) { $out += 'Electron' }
        if (Test-Path (Join-Path $dir 'chrome_elf.dll')) { $out += 'Chromium' }
        if (Test-Path (Join-Path $dir 'libcef.dll')) { $out += 'CEF' }
        if (Get-ChildItem $dir -Filter 'Qt*Network*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1) { $out += 'Qt' }
    }
    catch { }
    return $out
}

function Get-StaticProfile([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return @{ Mark = '[未知*]'; Text = '无路径' } }
    if ($script:StaticCache.ContainsKey($path)) { return $script:StaticCache[$path] }
    $imports = @(Get-PeImports $path | ForEach-Object { $_.ToLowerInvariant() })
    $hints = @(Get-FrameworkHints $path)
    if (($imports -contains 'winhttp.dll') -or ($imports -contains 'wininet.dll') -or ($imports -contains 'libcurl.dll')) {
        $ev = @()
        if ($imports -contains 'winhttp.dll') { $ev += 'winhttp' }
        if ($imports -contains 'wininet.dll') { $ev += 'wininet' }
        if ($imports -contains 'libcurl.dll') { $ev += 'libcurl' }
        $profile = @{ Mark = '[支持*]'; Text = ($ev -join '/') }
    }
    elseif (($hints -contains 'Electron') -or ($hints -contains 'Chromium') -or ($hints -contains 'CEF')) {
        $profile = @{ Mark = '[支持*]'; Text = ($hints -join '/') }
    }
    elseif ($hints -contains 'Qt') {
        $profile = @{ Mark = '[很可能*]'; Text = 'Qt Network' }
    }
    elseif ($imports -contains 'ws2_32.dll') {
        $profile = @{ Mark = '[未知*]'; Text = '仅 ws2_32' }
    }
    else {
        $profile = @{ Mark = '[不支持*]'; Text = '无网络导入' }
    }
    $script:StaticCache[$path] = $profile
    return $profile
}

function Get-Support($procName, $path) {
    $n = $procName.ToLowerInvariant()
    if ($SupportNone -contains $n) { return @{ Mark = '[不支持]'; Text = '名单' } }
    if ($SupportFull -contains $n) { return @{ Mark = '[支持]'; Text = '名单' } }
    if ($SupportPartial -contains $n) { return @{ Mark = '[部分]'; Text = '名单' } }
    return (Get-StaticProfile $path)
}

function Show-Candidates($cands) {
    $i = 0
    foreach ($c in $cands) {
        $i++
        $mark = if ($c.Net) { '●' } else { '○' }
        $sup = Get-Support $c.ProcessName $c.Path
        $name = $c.ProcessName
        if ($name.Length -gt 18) { $name = $name.Substring(0, 18) }
        $ev = [string]$sup.Text
        if ($ev.Length -gt 16) { $ev = $ev.Substring(0, 16) }
        $title = $c.MainWindowTitle
        if ($title.Length -gt 26) { $title = $title.Substring(0, 26) + '...' }
        Write-Host ("  [{0,2}] {1} {2,-18} PID={3,-7} {4,-8} {5,-16} {6}" -f $i, $mark, $name, $c.Id, $sup.Mark, $ev, $title)
    }
    Write-Host ""
    Write-Host "  带 * = 静态扫描（EXE 导入表/框架）推断，未运行验证；无 * = 内置名单"
    Write-Host "  [支持] 认代理 | [不支持] 不认代理 | [部分] 看版本 | [很可能] 有机会 | [未知] 判断不了"
}

function Get-LinkIndexesFromLog() {
    $lines = Get-Content (Join-Path $env:TEMP 'split-proxy.log') -Tail 20 -ErrorAction SilentlyContinue
    $m = ($lines | Select-String -Pattern 'ifIndex=([\d,]+)' | Select-Object -Last 1)
    if ($m) { return @(($m.Matches[0].Groups[1].Value -split ',') | ForEach-Object { [int]$_ }) }
    return @()
}

function Watch-DualLink([int]$port, [int[]]$ifIndexes, [int]$seconds = 12) {
    $base = @(Get-NetTCPConnection -RemotePort $port -ErrorAction SilentlyContinue).Count
    $prev = @{}
    $adNames = @{}
    foreach ($i in $ifIndexes) {
        $adNames[$i] = (Get-NetAdapter -InterfaceIndex $i -ErrorAction SilentlyContinue).Name
        $s = Get-NetAdapterStatistics -Name $adNames[$i] -ErrorAction SilentlyContinue
        $prev[$i] = [int64]$s.ReceivedBytes
    }
    $maxConns = 0
    $peak = @{}
    foreach ($i in $ifIndexes) { $peak[$i] = 0.0 }
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $cur = @(Get-NetTCPConnection -RemotePort $port -ErrorAction SilentlyContinue).Count
        $delta = $cur - $base
        if ($delta -gt $maxConns) { $maxConns = $delta }
        foreach ($i in $ifIndexes) {
            $s = Get-NetAdapterStatistics -Name $adNames[$i] -ErrorAction SilentlyContinue
            $bytes = [int64]$s.ReceivedBytes
            $mbps = [math]::Round((($bytes - $prev[$i]) * 8 / 1e6) / 2.0, 1)
            if ($mbps -gt $peak[$i]) { $peak[$i] = $mbps }
            $prev[$i] = $bytes
        }
    }
    return [pscustomobject]@{ MaxProxyConns = $maxConns; Peak = $peak }
}
function Start-AppProxied($proc) {
    $exe = $proc.Path
    if (-not $exe -or -not (Test-Path $exe)) { throw "拿不到 $($proc.ProcessName) 的可执行文件路径，请手动用代理启动" }
    $proxyUrl = "http://127.0.0.1:$Port"
    $old = @{
        HTTP_PROXY = $env:HTTP_PROXY; HTTPS_PROXY = $env:HTTPS_PROXY; ALL_PROXY = $env:ALL_PROXY; NO_PROXY = $env:NO_PROXY
    }
    try {
        $env:HTTP_PROXY = $proxyUrl
        $env:HTTPS_PROXY = $proxyUrl
        $env:ALL_PROXY = "socks5h://127.0.0.1:$Port"
        $env:NO_PROXY = "localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16"
        $launchArgs = @()
        if ($proc.ProcessName -match 'chrome|msedge|brave') { $launchArgs += "--proxy-server=$proxyUrl" }
        Write-Host "以代理环境启动 $exe ..."
        $p = Start-Process -FilePath $exe -ArgumentList $launchArgs -WorkingDirectory (Split-Path $exe) -PassThru
        return $p
    }
    finally {
        $env:HTTP_PROXY = $old.HTTP_PROXY
        $env:HTTPS_PROXY = $old.HTTPS_PROXY
        $env:ALL_PROXY = $old.ALL_PROXY
        $env:NO_PROXY = $old.NO_PROXY
    }
}

if ($Verify) {
    $idx = Get-LinkIndexesFromLog
    Write-Host ("观察 10 秒（端口 {0}）..." -f $Port)
    $w = Watch-DualLink $Port $idx 10
    Write-Host ("  经代理连接峰值: {0} 条" -f $w.MaxProxyConns)
    foreach ($i in $idx) {
        $ad = Get-NetAdapter -InterfaceIndex $i -ErrorAction SilentlyContinue
        Write-Host ("  {0}: 峰值 {1} Mbps" -f $ad.Name, $w.Peak[$i])
    }
    return
}

if ($Stop) { Stop-Proxy; return }

$cands = @(Get-Candidates)
if ($List -or $ProcId -eq 0) {
    Write-Host "带窗口且联网的进程（● 已联网 / ○ 未联网，附支持度）："
    Show-Candidates $cands
    if ($List) { return }
    $sel = Read-Host "输入编号选择要代理的软件（回车取消）"
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $cands.Count) { throw "编号无效" }
    $target = $cands[$idx - 1]
}
else {
    $target = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if (-not $target) { throw "PID $ProcId 不存在" }
    $target = [pscustomobject]@{ Id = $target.Id; ProcessName = $target.ProcessName; MainWindowTitle = $target.MainWindowTitle; Path = $target.Path }
}

Write-Host ""
Write-Host ("目标: {0} (PID={1})" -f $target.ProcessName, $target.Id)
Write-Host ("文件: {0}" -f $target.Path)

if (-not $target.Path -or -not (Test-Path $target.Path)) {
    throw "拿不到可执行文件路径，无法以代理环境重启"
}

$sup = Get-Support $target.ProcessName
Write-Host ("支持度: {0} {1}" -f $sup.Mark, $sup.Text)
if ($sup.Mark -eq '[不支持]' -or $sup.Mark -eq '[未知]') {
    Write-Host "注意：这类软件通常不认代理，用本方式分流不会生效（Steam、游戏启动器尤其如此）。"
    $go = Read-Host "仍要以代理环境启动？(y/N)"
    if ($go -notmatch '^[Yy]') { Write-Host "已取消。"; return }
}

Start-Proxy
$running = Get-Process -Id $target.Id -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "该进程正在运行，需要先退出才能应用代理环境。"
    $ans = Read-Host "现在结束它并重新启动？(y/N)"
    if ($ans -match '^[Yy]') {
        try { Stop-Process -Id $target.Id -Force } catch {}
        Start-Sleep -Milliseconds 800
    }
    else {
        Write-Host "已取消。"
        return
    }
}

$newProc = Start-AppProxied $target
$linkIdx = Get-LinkIndexesFromLog
Write-Host ""
Write-Host "正在观察 12 秒：确认是否真的走代理、两条链路是否都在动 ..."
$watch = Watch-DualLink $Port $linkIdx 12
if ($watch.MaxProxyConns -gt 0) { Write-Host ("  实测：经代理的连接峰值 {0} 条 → 该软件确实走了代理" -f $watch.MaxProxyConns) }
else { Write-Host "  实测：12 秒内没看到它连代理（可能还没开始下载，或它不认代理）" }
foreach ($i in $linkIdx) {
    $ad = Get-NetAdapter -InterfaceIndex $i -ErrorAction SilentlyContinue
    Write-Host ("  {0}: 峰值 {1} Mbps" -f $ad.Name, $watch.Peak[$i])
}

Write-Host ""
Write-Host "=========================================================================="
Write-Host "已用分流器启动（SOCKS5 + HTTP，127.0.0.1:$Port，模式 $Mode）"
Write-Host "该进程的所有连接会轮流走 Wi-Fi 和手机 USB 共享。"
Write-Host "关闭这个软件即恢复原状（环境变量只对它生效，没有改系统任何设置）。"
Write-Host "全部用完想彻底停掉分流器：app-split.ps1 -Stop"
Write-Host "=========================================================================="

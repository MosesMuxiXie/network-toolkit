param(
    [int]$Port = 1080,
    [ValidateSet('split', 'primary', 'secondary')][string]$Mode = 'split',
    [string]$Primary = '',
    [string]$Secondary = '',
    [switch]$List,
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

$SupportFull = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'curl', 'aria2c', 'wget', 'powershell', 'pwsh', 'python', 'python3', 'node', 'git', '7z', 'idman', 'qbittorrent', 'transmission', 'fdm', 'discord', 'telegram', 'code', 'vscode')
$SupportPartial = @('thunder', 'xunlei', 'weixin', 'wechat', 'qq', 'baidunetdisk', 'quark', 'aliyundrive', 'dingtalk', 'feishu', 'wps')
$SupportNone = @('steam', 'steamwebhelper', 'epicgameslauncher', 'battle.net', 'battlenet', 'origin', 'eadesktop', 'ubisoftconnect', 'uplay', 'uu', 'xunyou', 'wegame', 'riotclient', 'leagueclient', 'msiexec')

function Get-Support([string]$procName) {
    $n = $procName.ToLowerInvariant()
    if ($SupportFull -contains $n) { return [pscustomobject]@{ Mark = '[支持]'; Text = '认代理 + 可多连接，能吃到双线' } }
    if ($SupportPartial -contains $n) { return [pscustomobject]@{ Mark = '[部分]'; Text = '看版本或只认系统代理，需实测' } }
    if ($SupportNone -contains $n) { return [pscustomobject]@{ Mark = '[不支持]'; Text = '不认代理，需 /32 路由或双 WAN' } }
    return [pscustomobject]@{ Mark = '[未知]'; Text = '多半不认代理，需实测' }
}

function Show-Candidates($cands) {
    $i = 0
    foreach ($c in $cands) {
        $i++
        $mark = if ($c.Net) { '●' } else { '○' }
        $sup = Get-Support $c.ProcessName
        $name = $c.ProcessName
        if ($name.Length -gt 20) { $name = $name.Substring(0, 20) }
        $title = $c.MainWindowTitle
        if ($title.Length -gt 34) { $title = $title.Substring(0, 34) + '...' }
        Write-Host ("  [{0,2}] {1} {2,-20} PID={3,-7} {4,-6} {5}" -f $i, $mark, $name, $c.Id, $sup.Mark, $title)
    }
    Write-Host ""
    Write-Host "  支持度: [支持] 认代理+多连接 → 能吃到双线 | [部分] 看版本/只认系统代理 | [不支持] 不认代理（需路由或双 WAN） | [未知] 多半不认"
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
        $args = @()
        if ($proc.ProcessName -match 'chrome|msedge|brave') { $args += "--proxy-server=$proxyUrl" }
        Write-Host "以代理环境启动 $exe ..."
        Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory (Split-Path $exe) | Out-Null
    }
    finally {
        $env:HTTP_PROXY = $old.HTTP_PROXY
        $env:HTTPS_PROXY = $old.HTTPS_PROXY
        $env:ALL_PROXY = $old.ALL_PROXY
        $env:NO_PROXY = $old.NO_PROXY
    }
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

Start-AppProxied $target

Write-Host ""
Write-Host "=========================================================================="
Write-Host "已用分流器启动（SOCKS5 + HTTP，127.0.0.1:$Port，模式 $Mode）"
Write-Host "该进程的所有连接会轮流走 Wi-Fi 和手机 USB 共享。"
Write-Host "关闭这个软件即恢复原状（环境变量只对它生效，没有改系统任何设置）。"
Write-Host "全部用完想彻底停掉分流器：app-split.ps1 -Stop"
Write-Host "=========================================================================="

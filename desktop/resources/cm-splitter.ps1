param(
    [ValidateSet('enable','disable','status','test','run','sethosts')][string]$Action = 'status',
    [ValidateSet('on','off')][string]$Mode = 'on',
    [switch]$NoElevate,
    [string]$ResultFile = ''
)

$ErrorActionPreference = 'Continue'
$Root     = $PSScriptRoot
$PidFile  = Join-Path $Root 'cm-splitter.pid'
$LogFile  = Join-Path $Root 'cm-splitter.log'
$HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$BeginMark = '# === SteamCM BEGIN ==='
$EndMark   = '# === SteamCM END ==='
$Chunk     = 20
$DelayMs   = 3
$Ports     = 27015..27036

# 本地回环 IP -> 真实 CM IP / 域名
$Dcs = @(
    @{ ip='127.0.0.2';  host='cmp1-hkg1'; target='103.28.54.100'  }
    @{ ip='127.0.0.3';  host='cmp2-hkg1'; target='103.28.54.101'  }
    @{ ip='127.0.0.4';  host='cmp3-hkg1'; target='103.28.54.102'  }
    @{ ip='127.0.0.5';  host='cmp1-sgp1'; target='103.10.124.4'   }
    @{ ip='127.0.0.6';  host='cmp2-sgp1'; target='103.10.124.5'   }
    @{ ip='127.0.0.7';  host='cmp1-tyo3'; target='45.121.184.100' }
    @{ ip='127.0.0.8';  host='cmp2-tyo3'; target='45.121.184.101' }
    @{ ip='127.0.0.9';  host='cmp1-lax1'; target='162.254.195.69' }
    @{ ip='127.0.0.10'; host='cmp2-lax1'; target='162.254.195.75' }
    @{ ip='127.0.0.11'; host='cmp1-dfw2'; target='162.254.194.56' }
    @{ ip='127.0.0.12'; host='cmp2-dfw2'; target='162.254.194.57' }
    @{ ip='127.0.0.13'; host='cmp1-syd1'; target='103.10.125.22'  }
    @{ ip='127.0.0.14'; host='ext1-bom2'; target='155.133.224.22' }
    @{ ip='127.0.0.15'; host='ext2-bom2'; target='155.133.224.23' }
    @{ ip='127.0.0.16'; host='ext1-maa2'; target='155.133.225.20' }
    @{ ip='127.0.0.17'; host='ext2-maa2'; target='155.133.225.21' }
    @{ ip='127.0.0.18'; host='cmp1-sea1'; target='205.196.6.132'  }
    @{ ip='127.0.0.19'; host='cmp2-sea1'; target='205.196.6.133'  }
    @{ ip='127.0.0.20'; host='cmp1-atl3'; target='162.254.199.165'}
    @{ ip='127.0.0.21'; host='cmp2-atl3'; target='162.254.199.184'}
    @{ ip='127.0.0.22'; host='cmp1-iad1'; target='162.254.192.98' }
    @{ ip='127.0.0.23'; host='cmp2-iad1'; target='162.254.192.99' }
    @{ ip='127.0.0.24'; host='cmp1-ord1'; target='162.254.193.103'}
    @{ ip='127.0.0.25'; host='cmp2-ord1'; target='162.254.193.75' }
)

# ==================== 基础工具 ====================

function Format-Err($e) {
    if ($null -eq $e) { return '未知错误' }
    $msg = ''
    try { $msg = $e.Exception.Message } catch { }
    if (-not $msg) { try { $msg = [string]$e } catch { $msg = '未知错误' } }
    $msg = ($msg -replace "`r", ' ') -replace "`n", ' '
    $msg = $msg.Trim()
    if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) + '…' }
    if (-not $msg) { $msg = '未知错误' }
    return $msg
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return [bool]$pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

$IsAdmin = Test-Admin

# hosts 原编码：有 BOM 按 BOM，否则按系统 ANSI 代码页（不要用 Encoding::Default，
# 它在 pwsh 7 里是 UTF-8，会把 ANSI 的 hosts 读坏再写回）
function Get-AnsiEncoding {
    try {
        $acp = [int][Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        if ($acp -gt 0) { return [Text.Encoding]::GetEncoding($acp) }
    } catch { }
    return [Text.Encoding]::Default
}

function Get-RelayPid {
    if (-not (Test-Path $PidFile)) { return 0 }
    try { return [int]((Get-Content $PidFile -Raw -ErrorAction Stop).Trim()) } catch { return 0 }
}

function Test-RelayRunning {
    $p = Get-RelayPid
    if ($p -le 0) { return $false }
    return [bool](Get-Process -Id $p -ErrorAction SilentlyContinue)
}

function Get-ListenCount {
    try {
        $all = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                 Where-Object { $_.LocalPort -ge 27015 -and $_.LocalPort -le 27036 -and $_.LocalAddress -like '127.0.0.*' })
        return $all.Count
    } catch { return 0 }
}

# ==================== hosts 读写（带编码保持 / 备份 / 只读属性 / 提权） ====================

function Read-HostsInfo {
    $info = @{ Text = ''; Enc = (Get-AnsiEncoding); Bom = $false; Ok = $true; Err = '' }
    try {
        if (-not (Test-Path -LiteralPath $HostsFile)) {
            $info.Ok = $false
            $info.Err = 'hosts 文件不存在'
            return $info
        }
        $bytes = [IO.File]::ReadAllBytes($HostsFile)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
            $info.Enc = New-Object Text.UTF8Encoding($true)
            $info.Bom = $true
            $info.Text = $info.Enc.GetString($bytes, 3, $bytes.Length - 3)
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
            $info.Enc = [Text.Encoding]::Unicode
            $info.Bom = $true
            $info.Text = $info.Enc.GetString($bytes, 2, $bytes.Length - 2)
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
            $info.Enc = [Text.Encoding]::BigEndianUnicode
            $info.Bom = $true
            $info.Text = $info.Enc.GetString($bytes, 2, $bytes.Length - 2)
        } else {
            $info.Text = $info.Enc.GetString($bytes)
        }
    } catch {
        $info.Ok = $false
        $info.Err = Format-Err $_
    }
    return $info
}

function Get-BlockLines {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($BeginMark)
    foreach ($d in $Dcs) { $lines.Add("$($d.ip) $($d.host).steamserver.net") }
    $lines.Add($EndMark)
    return $lines
}

# 当前块的内容（换行归一化后），没有块返回空串
function Get-CurrentBlock([string]$Text) {
    $m = [regex]::Match($Text, '(?s)' + [regex]::Escape($BeginMark) + '.*?' + [regex]::Escape($EndMark))
    if (-not $m.Success) { return '' }
    return (($m.Value -replace "`r`n", "`n") -replace "`r", "`n").Trim()
}

function Get-HostsFlags {
    $c = Read-HostsInfo
    $on = 0; $stale = 0
    if ($c.Ok -and $c.Text.Contains($BeginMark)) {
        $on = 1
        $exp = ((Get-BlockLines) -join "`n")
        if ((Get-CurrentBlock $c.Text) -ne $exp) { $stale = 1 }
    }
    return @{ On = $on; Stale = $stale; Ok = $c.Ok; Err = $c.Err }
}

# 在原文上只替换/追加 CM 块，块外的内容逐字节保留
function Get-DesiredText([bool]$On) {
    $info = Read-HostsInfo
    if (-not $info.Ok) { throw ('读取 hosts 失败：' + $info.Err) }
    $raw = $info.Text
    $pat = '(?s)(?:\r?\n)?' + [regex]::Escape($BeginMark) + '.*?' + [regex]::Escape($EndMark) + '(?:\r?\n)?'

    $base = $raw
    while ($true) {
        $m = [regex]::Match($base, $pat)
        if (-not $m.Success) { break }
        $base = $base.Substring(0, $m.Index) + $base.Substring($m.Index + $m.Length)
    }
    # 残缺的 BEGIN（没有 END）：从 BEGIN 截到末尾
    $i = $base.IndexOf($BeginMark)
    if ($i -ge 0) { $base = $base.Substring(0, $i) }

    $base = $base.TrimEnd("`r", "`n")
    $nl = "`r`n"
    if ($On) {
        $text = $base + $nl + $nl + ((Get-BlockLines) -join $nl) + $nl
    } else {
        $text = $base + $nl
    }
    return $text
}

function Backup-Hosts {
    try {
        $bak = Join-Path $Root ('hosts.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $HostsFile -Destination $bak -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath $Root -Filter 'hosts.bak.*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Write-HostsText([string]$Text, [int]$Tries = 8) {
    $res = @{ Ok = $false; Err = '' }
    $info = Read-HostsInfo
    Backup-Hosts

    $wasReadOnly = $false
    try {
        $item = Get-Item -LiteralPath $HostsFile -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $wasReadOnly = $true
            $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    } catch { }

    for ($i = 0; $i -lt $Tries; $i++) {
        try {
            [IO.File]::WriteAllText($HostsFile, $Text, $info.Enc)
            $res.Ok = $true
            break
        } catch {
            $res.Err = Format-Err $_
            Start-Sleep -Milliseconds 500
        }
    }

    if ($wasReadOnly) {
        try {
            $item = Get-Item -LiteralPath $HostsFile -Force -ErrorAction Stop
            $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly
        } catch { }
    }

    # 写完回读校验，避免“写成功但没落盘”
    if ($res.Ok) {
        $check = Read-HostsInfo
        if (-not $check.Ok) {
            $res.Ok = $false
            $res.Err = '写入后回读失败：' + $check.Err
        } elseif ($check.Text -ne $Text) {
            $res.Ok = $false
            $res.Err = '写入后回读内容不一致（可能被其他程序改写或权限只到临时层）'
        }
    }
    return $res
}

# 提权子进程只负责写 hosts；结果通过 -ResultFile 回传
function Invoke-ElevatedHosts([bool]$On) {
    $res = @{ Ok = $false; Err = '' }
    $mode = 'off'
    if ($On) { $mode = 'on' }
    $rf = Join-Path ([IO.Path]::GetTempPath()) ('cm-hosts-' + [guid]::NewGuid().ToString('N') + '.txt')
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"' + $PSCommandPath + '"'),
        '-Action', 'sethosts', '-Mode', $mode, '-NoElevate',
        '-ResultFile', ('"' + $rf + '"')
    )

    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
        if ($p) { $p.Dispose() }
    } catch {
        $ex = $_.Exception
        $code = 0
        if ($ex -is [System.ComponentModel.Win32Exception]) { $code = $ex.NativeErrorCode }
        if ($code -eq 0 -and $ex.InnerException -is [System.ComponentModel.Win32Exception]) {
            $code = $ex.InnerException.NativeErrorCode
        }
        if ($code -eq 1223) {
            $res.Err = 'UAC 授权被取消（错误 1223）：写入 hosts 需要管理员权限'
        } elseif ($code -eq 740) {
            $res.Err = 'UAC 无法弹出（错误 740）：当前会话不在交互桌面，无法提权'
        } else {
            $res.Err = '提权写入失败：' + (Format-Err $ex)
        }
        return $res
    }

    if (Test-Path -LiteralPath $rf) {
        $txt = ''
        try { $txt = [IO.File]::ReadAllText($rf, [Text.Encoding]::UTF8) } catch { }
        Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue
        $kv = @{}
        foreach ($line in ($txt -split "`r?`n")) {
            $eq = $line.IndexOf('=')
            if ($eq -gt 0) { $kv[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
        }
        if ($kv['HOSTS_WRITE'] -eq '1') {
            $res.Ok = $true
            return $res
        }
        if ($kv.ContainsKey('HOSTS_ERR') -and $kv['HOSTS_ERR']) { $res.Err = $kv['HOSTS_ERR'] }
    }

    # 兜底：不看返回值，直接看 hosts 的实际状态
    $c = Read-HostsInfo
    if ($c.Ok) {
        if ($On -and ((Get-CurrentBlock $c.Text) -eq ((Get-BlockLines) -join "`n"))) {
            $res.Ok = $true
            return $res
        }
        if ((-not $On) -and (-not $c.Text.Contains($BeginMark))) {
            $res.Ok = $true
            return $res
        }
    }
    if (-not $res.Err) { $res.Err = '提权子进程没有返回结果（可能被 UAC 或安全软件拦截）' }
    return $res
}

function Set-HostsState([bool]$On, [bool]$AllowElevate) {
    $res = @{ Ok = $false; Err = ''; Hint = ''; Skipped = $false; Elevated = $false; NeedAdmin = $false }

    # 幂等：已经是目标状态就不动 hosts，避免每次开启都弹 UAC
    $hf = Get-HostsFlags
    if ($On -and $hf.On -eq 1 -and $hf.Stale -eq 0) { $res.Ok = $true; $res.Skipped = $true; return $res }
    if ((-not $On) -and $hf.On -eq 0)               { $res.Ok = $true; $res.Skipped = $true; return $res }

    $desired = ''
    $readFailed = $false
    try { $desired = Get-DesiredText $On } catch { $readFailed = $true; $res.Err = Format-Err $_ }
    # 读都读不到（被 ACL / 安全软件挡住）时，如果还能提权就交给提权子进程自己读
    if ($readFailed -and ($IsAdmin -or (-not $AllowElevate))) { return $res }

    # 提权状态下一次就成；非提权先试一次（少数机器 Users 组有写权限），失败再提权
    $tries = 8
    if (-not $IsAdmin) { $tries = 1 }
    if (-not $readFailed) {
        $w = Write-HostsText $desired $tries
        if ($w.Ok) { $res.Ok = $true; return $res }
        $res.Err = $w.Err
    }

    if (-not $IsAdmin) { $res.NeedAdmin = $true }

    if (-not $IsAdmin -and $AllowElevate) {
        $e = Invoke-ElevatedHosts $On
        if ($e.Ok) {
            $res.Ok = $true
            $res.Elevated = $true
            $res.Err = ''
            return $res
        }
        $res.Err = $e.Err
        $res.Hint = '开启时会弹一次 UAC，请在弹窗里点“是”；拒绝或超时都会导致 hosts 写不进去'
    } elseif (-not $IsAdmin) {
        $res.Hint = '当前进程没有管理员权限，且本次不允许提权'
    }
    return $res
}

function Write-CmStatus([bool]$Run, [int]$Lis, [int]$PidValue, $HostsResult) {
    $admin = 0
    if ($IsAdmin) { $admin = 1 }
    Write-Output ('CM_ENABLED=' + $(if ($Run -and $Lis -gt 0) { 1 } else { 0 }))
    Write-Output ('CM_PID=' + $PidValue)
    Write-Output ('CM_LISTENERS=' + $Lis)
    Write-Output ('CM_DC=' + $Dcs.Count)

    $hf = Get-HostsFlags
    Write-Output ('CM_HOSTS=' + $hf.On)
    Write-Output ('CM_HOSTS_ADMIN=' + $admin)
    if ($hf.Stale -eq 1) { Write-Output 'CM_HOSTS_STALE=1' }

    if ($HostsResult -and (-not $HostsResult.Ok) -and $HostsResult.Err) {
        Write-Output ('CM_HOSTS_ERR=' + $HostsResult.Err)
        if ($HostsResult.Hint) { Write-Output ('CM_HOSTS_HINT=' + $HostsResult.Hint) }
    } elseif (-not $hf.Ok) {
        Write-Output ('CM_HOSTS_ERR=' + $hf.Err)
    } elseif ($hf.On -eq 0 -and $admin -eq 0) {
        Write-Output ('CM_HOSTS_HINT=非管理员运行：写入 hosts 时会请求 UAC 授权')
    }
}

switch ($Action) {

    'run' {
        Add-Type -Path (Join-Path $Root 'CmSplitter.cs')
        [CmSplitter]::LogPath = $LogFile
        $total = 0
        foreach ($d in $Dcs) {
            $total += [CmSplitter]::StartMany($d.ip, [int[]]$Ports, $d.target, $Chunk, $DelayMs, $d.host)
        }
        $PID | Out-File -FilePath $PidFile -Encoding ASCII -Force
        [CmSplitter]::L("=== started PID $PID, $total listeners, $($Dcs.Count) DC, chunk=$Chunk delay=${DelayMs}ms ===")
        while ($true) { Start-Sleep -Seconds 20 }
    }

    'enable' {
        foreach ($n in @('no_proxy','NO_PROXY','http_proxy','HTTP_PROXY','https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY')) {
            Remove-Item ('Env:' + $n) -ErrorAction SilentlyContinue
        }
        if (-not (Test-RelayRunning)) {
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', ('"' + $PSCommandPath + '"'), '-Action','run')
            $sp = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $Root -WindowStyle Hidden -PassThru
            if ($sp) { $sp.Dispose() }
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 400
                if ((Get-ListenCount) -ge ($Dcs.Count * $Ports.Count) - 24) { break }
            }
        }
        # 中继没起来就别写 hosts：528 个 127.0.0.x 条目全是死路，
        # Steam 会连到没人监听的本地端口，表现为「转圈后连不上」，
        # 比不写 hosts（直连不生效但仍能正常连）更糟。
        $lis0 = Get-ListenCount
        if ($lis0 -gt 0) {
            $hostsRes = Set-HostsState $true $true
        } else {
            $hostsRes = @{ Ok = $false; Err = '中继未启动（本机 0 个监听），已跳过 hosts 写入'; Hint = '看 CM 日志确认 CmSplitter.cs 加载成功、27015-27036 端口没被占用'; Skipped = $false; Elevated = $false; NeedAdmin = $false }
        }
        & ipconfig /flushdns 2>&1 | Out-Null
        $lis = Get-ListenCount
        Write-CmStatus ((Test-RelayRunning) -and $lis -gt 0) $lis (Get-RelayPid) $hostsRes
    }

    'disable' {
        $p = Get-RelayPid
        if ($p -gt 0) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 800
        $hostsRes = Set-HostsState $false $true
        & ipconfig /flushdns 2>&1 | Out-Null
        if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
        $lis = Get-ListenCount
        Write-CmStatus ((Test-RelayRunning) -and $lis -gt 0) $lis 0 $hostsRes
    }

    'sethosts' {
        # 提权子进程入口：只写 hosts，不递归提权
        $on = ($Mode -eq 'on')
        $r = Set-HostsState $on $false

        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('HOSTS_MODE=' + $Mode)
        $lines.Add('HOSTS_WRITE=' + $(if ($r.Ok) { 1 } else { 0 }))
        if ($r.Skipped) { $lines.Add('HOSTS_SKIPPED=1') }
        if ($r.Elevated) { $lines.Add('HOSTS_ELEVATED=1') }
        if ($r.Err) { $lines.Add('HOSTS_ERR=' + $r.Err) }
        $lines.Add('HOSTS_ADMIN=' + $(if ($IsAdmin) { 1 } else { 0 }))
        $text = ($lines -join "`r`n") + "`r`n"

        if ($ResultFile) {
            try {
                [IO.File]::WriteAllText($ResultFile, $text, (New-Object Text.UTF8Encoding($false)))
            } catch {
                Write-Output ('HOSTS_ERR=写结果文件失败：' + (Format-Err $_))
            }
        }
        Write-Output $text.TrimEnd()
    }

    'status' {
        $run = Test-RelayRunning
        $lis = Get-ListenCount
        Write-CmStatus ($run -and $lis -gt 0) $lis (Get-RelayPid) $null
    }

    'test' {
        $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
        if (-not $curl) { Write-Output 'CM_TEST=0'; break }
        $savedH = $env:HTTP_PROXY; $savedS = $env:HTTPS_PROXY; $savedA = $env:ALL_PROXY
        $env:HTTP_PROXY = ''; $env:HTTPS_PROXY = ''; $env:ALL_PROXY = ''
        $ok = 0; $tot = 0
        foreach ($h in @('cmp1-hkg1','cmp2-hkg1','cmp1-sgp1','cmp1-lax1')) {
            $tot++
            $r = & $curl -s -o NUL -w '%{http_code}|%{time_appconnect}' --noproxy '*' --connect-timeout 8 --max-time 15 ('https://' + $h + '.steamserver.net:27018/') 2>$null
            $a = "$r" -split '\|'
            if ($a[0] -eq '403') { $ok++; Write-Output ('CM_DC_' + $h + '=OK:' + $a[1]) }
            else { Write-Output ('CM_DC_' + $h + '=FAIL:' + $a[0]) }
        }
        $env:HTTP_PROXY = $savedH; $env:HTTPS_PROXY = $savedS; $env:ALL_PROXY = $savedA
        Write-Output ('CM_TEST_OK=' + $ok)
        Write-Output ('CM_TEST_TOTAL=' + $tot)
    }
}

exit 0

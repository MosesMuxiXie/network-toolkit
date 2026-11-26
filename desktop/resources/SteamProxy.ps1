#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Test,
    [switch]$EnableQuiet,
    [switch]$DisableQuiet,
    # 内部开关：提权子进程带它启动，用来保证「只提权一次」
    [switch]$AsAdmin
)
<#
  Steam 社区直连工具 (SteamProxy)
  ================================================================
  原理：本机 Caddy 终结 TLS，再用 Akamai 域前置转发到 Valve 白名单域名
        SNI = steampowered.com（未被封），Host = steamcommunity.com
  作用：SNI 黑名单重新生效时，仍能让 steamcommunity.com 在本机可用
        不依赖虚拟网卡，不依赖代理，只改 hosts + 本地 443
  用法：双击运行看图形界面；或 powershell -File SteamProxy.ps1 -Test
  ================================================================
#>

# ==================== 自提权 ====================
# 桌面端会用 -EnableQuiet / -DisableQuiet / -Test 调本脚本，这几个开关都要写 hosts
# 或改证书，非管理员一定失败。提权时必须把这些开关一起带过去，否则提权后的那份
# 会退化成「开个 GUI 等人点」，而原来那份已经 exit 0 —— 桌面端拿不到任何输出，
# 用户看到的是「点了没反应，然后莫名多个窗口」。
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $AsAdmin) {
    # 提权子进程仍然不是管理员：说明这次 runas 被系统默默降权了（UAC 关闭时的
    # 受限令牌、安全软件拦截等）。再拉一次就是无限自我复制的进程炸弹，直接失败。
    [Console]::Error.WriteLine("提权未生效：子进程仍不是管理员，已停止，避免反复自启动")
    exit 2
}
if (-not $isAdmin) {
    # 参数是从 $PSBoundParameters 重建的：有了 param() 和 [CmdletBinding()] 之后
    # $args 里只剩没被声明的多余参数，直接用它会一个开关都带不过去。
    $passArgs = ''
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $name = '-' + $kv.Key
        $val = $kv.Value
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $passArgs += ' ' + $name }
        } elseif ($null -ne $val -and "$val" -ne '') {
            $s = [string]$val
            if ($s -match '[\s"]') { $passArgs += ' ' + $name + ' "' + ($s -replace '"', '\"') + '"' }
            else { $passArgs += ' ' + $name + ' ' + $s }
        }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" + $passArgs + ' -AsAdmin'
    $psi.Verb = "runas"
    $psi.UseShellExecute = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not ($Test -or $EnableQuiet -or $DisableQuiet)) {
            # 双击启动的 GUI 模式：提权后的那份就是用户要的窗口，父进程没必要陪着
            exit 0
        }
        $p.WaitForExit()
        # 提权子进程的输出走它自己的控制台，桌面端抓不到；把失败写在父进程的 stdout 上，
        # 才能落到「CM/Steam 日志」面板里让人看见原因。
        if ($p.ExitCode -ne 0) {
            Write-Output ('STEAM_ERR=提权子进程退出码 ' + $p.ExitCode + '（UAC 被拒绝，或提权没有真正生效）')
        }
        exit $p.ExitCode
    } catch {
        # 典型是用户在 UAC 上点了「否」（1223）
        Write-Output ('STEAM_ERR=提权失败：' + $_.Exception.Message)
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==================== 全局常量 ====================
$script:Root      = $PSScriptRoot
$script:CaddyExe  = Join-Path $script:Root "caddy.exe"
$script:Caddyfile = Join-Path $script:Root "Caddyfile"
$script:HostsFile = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$script:CaThumb   = "7267A3CF9810C3C41E2F0F2DF530A07500F3EA4C"
$script:TaskName  = "SteamProxyAutostart"
$script:BeginMark = "# === SteamProxy BEGIN ==="
$script:EndMark   = "# === SteamProxy END ==="
$script:OldMarkA  = "# === Steam Community"
$script:OldMarkB  = "# === end Steam Community ==="
$script:Domains   = @("steamcommunity.com", "www.steamcommunity.com")

# ==================== 日志 ====================
function Log {
    param([string]$Message, [string]$Color = "Gray")
    $ts = Get-Date -Format "HH:mm:ss"
    if ($script:logBox) {
        $script:logBox.SelectionStart = $script:logBox.TextLength
        $script:logBox.SelectionLength = 0
        switch ($Color) {
            "Green"  { $script:logBox.SelectionColor = [System.Drawing.Color]::FromArgb(120, 220, 140) }
            "Red"    { $script:logBox.SelectionColor = [System.Drawing.Color]::FromArgb(255, 120, 120) }
            "Yellow" { $script:logBox.SelectionColor = [System.Drawing.Color]::FromArgb(240, 200, 100) }
            "Cyan"   { $script:logBox.SelectionColor = [System.Drawing.Color]::FromArgb(120, 200, 240) }
            default  { $script:logBox.SelectionColor = [System.Drawing.Color]::FromArgb(200, 200, 205) }
        }
        $script:logBox.AppendText("[$ts] $Message`r`n")
        $script:logBox.SelectionStart = $script:logBox.TextLength
        $script:logBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        $cc = "Gray"
        switch ($Color) {
            "Green"  { $cc = "Green" }
            "Red"    { $cc = "Red" }
            "Yellow" { $cc = "Yellow" }
            "Cyan"   { $cc = "Cyan" }
        }
        Write-Host "[$ts] $Message" -ForegroundColor $cc
    }
}

# ==================== 状态检测 ====================
function Get-ProxyStatus {
    $caddyProc = @(Get-Process -Name "caddy" -ErrorAction SilentlyContinue)
    $listening = @(Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue).Count -gt 0
    $hostsOn = $false
    if (Test-Path $script:HostsFile) {
        try { $raw = [IO.File]::ReadAllText($script:HostsFile, [Text.Encoding]::Default) } catch { $raw = "" }
        if ($null -ne $raw) {
            foreach ($d in $script:Domains) {
                if ($raw -match ('(?m)^\s*127\.0\.0\.1\s+' + [regex]::Escape($d) + '\s*$')) { $hostsOn = $true }
            }
        }
    }
    $caOn = $false
    try {
        $caOn = [bool](Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
                       Where-Object { $_.Thumbprint -eq $script:CaThumb })
    } catch { }
    $taskState = "none"
    try {
        $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        if ($t) { $taskState = [string]$t.State }
    } catch { }

    $pidText = ""
    if ($caddyProc.Count -gt 0) { $pidText = ($caddyProc.Id -join ",") }

    [pscustomobject]@{
        CaddyRunning = ($caddyProc.Count -gt 0)
        CaddyPid     = $pidText
        Listening    = $listening
        HostsOn      = $hostsOn
        CaOn         = $caOn
        TaskState    = $taskState
    }
}

function Set-StatusLabel {
    param($Label, [string]$Name, [bool]$Ok, [string]$Detail)
    if ($null -eq $Label) { return }
    $mark = "O"
    if ($Ok) { $mark = "*" }
    $Label.Text = ("{0}  {1}  {2}" -f $mark, $Name, $Detail)
    if ($Ok) { $Label.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 140) }
    else     { $Label.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 158) }
}

function Refresh-Status {
    $s = Get-ProxyStatus
    $d1 = if ($s.CaddyRunning) { "运行中 PID " + $s.CaddyPid } else { "未运行" }
    $d2 = if ($s.HostsOn) { "已指向 127.0.0.1" } else { "未生效" }
    $d3 = if ($s.CaOn) { "已信任" } else { "未安装" }
    $d4 = if ($s.Listening) { "监听中" } else { "未监听" }
    Set-StatusLabel $script:lblCaddy "Caddy"  $s.CaddyRunning $d1
    Set-StatusLabel $script:lblHosts "hosts"  $s.HostsOn      $d2
    Set-StatusLabel $script:lblCa    "证书"   $s.CaOn         $d3
    Set-StatusLabel $script:lblPort  "443"    $s.Listening    $d4

    if ($null -ne $script:lblOverall) {
        if ($s.CaddyRunning -and $s.HostsOn -and $s.CaOn -and $s.Listening) {
            $script:lblOverall.Text = "已开启 — 社区走本机直连"
            $script:lblOverall.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 140)
        } elseif ((-not $s.CaddyRunning) -and (-not $s.HostsOn)) {
            $script:lblOverall.Text = "已关闭 — 社区走系统默认网络"
            $script:lblOverall.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 158)
        } else {
            $script:lblOverall.Text = "状态不完整 — 建议重新点「开启」或「关闭」"
            $script:lblOverall.ForeColor = [System.Drawing.Color]::FromArgb(240, 200, 100)
        }
    }
    return $s
}

# ==================== Caddy 进程 ====================
function Start-CaddyService {
    $existing = @(Get-Process -Name "caddy" -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        Log ("Caddy 已在运行 (PID " + ($existing.Id -join ",") + ")") "Cyan"
        return $true
    }
    if (-not (Test-Path $script:CaddyExe))  { Log ("找不到 caddy.exe：" + $script:CaddyExe) "Red"; return $false }
    if (-not (Test-Path $script:Caddyfile)) { Log ("找不到 Caddyfile：" + $script:Caddyfile) "Red"; return $false }

    $busy = @(Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) {
        $ownerPid = ($busy | Select-Object -First 1).OwningProcess
        $owner = "?"
        try { $owner = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName } catch { }
        Log ("443 已被占用：PID " + $ownerPid + " (" + $owner + ")，请先关掉该程序") "Red"
        return $false
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:CaddyExe
        $psi.Arguments = "run --config `"$script:Caddyfile`""
        $psi.WorkingDirectory = $script:Root
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($k in @("HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy","NO_PROXY","no_proxy","ALL_PROXY","all_proxy")) {
            try { $psi.EnvironmentVariables.Remove($k) } catch { }
        }
        $proc = [System.Diagnostics.Process]::Start($psi)
        Log ("已启动 Caddy (PID " + $proc.Id + ")，等待就绪 ...") "Cyan"

        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 400
            if ($proc.HasExited) {
                $err = ""
                try { $err = $proc.StandardError.ReadToEnd() } catch { }
                Log ("Caddy 启动后立即退出：" + $err) "Red"
                return $false
            }
            if (@(Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {
                Log "443 已监听" "Green"
                return $true
            }
        }
        Log "等待 443 监听超时（进程仍在，可稍后刷新状态）" "Yellow"
        return $true
    } catch {
        Log ("启动 Caddy 失败：" + $_.Exception.Message) "Red"
        return $false
    }
}

function Stop-CaddyService {
    $procs = @(Get-Process -Name "caddy" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Log "Caddy 未在运行" "Gray"; return $true }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Log ("已停止 Caddy (PID " + $p.Id + ")") "Cyan"
        } catch {
            Log ("停止 PID " + $p.Id + " 失败：" + $_.Exception.Message) "Red"
        }
    }
    try { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue } catch { }
    try { Stop-ScheduledTask -TaskName "SteamCommunityCaddy" -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 600
    return (@(Get-Process -Name "caddy" -ErrorAction SilentlyContinue).Count -eq 0)
}

# ==================== 根证书 ====================
function Enable-RootCA {
    $caOk = $false
    try {
        $caOk = [bool](Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
                       Where-Object { $_.Thumbprint -eq $script:CaThumb })
    } catch { }
    if ($caOk) { Log "根证书已信任，跳过" "Gray"; return $true }

    $rootCrt = Join-Path $env:APPDATA "Caddy\pki\authorities\local\root.crt"
    if (-not (Test-Path $rootCrt)) {
        Log "未找到 Caddy 根证书，先让 Caddy 生成一次 ..." "Yellow"
        Start-CaddyService | Out-Null
        Start-Sleep -Seconds 2
    }
    if (-not (Test-Path $rootCrt)) {
        Log ("仍找不到 " + $rootCrt + "，无法安装证书") "Red"
        return $false
    }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($rootCrt)
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
        $store.Open("ReadWrite")
        $store.Add($cert)
        $store.Close()
        Log ("根证书已装入 LocalMachine\Root：" + $cert.Subject) "Green"
        return $true
    } catch {
        Log ("安装根证书失败：" + $_.Exception.Message) "Red"
        return $false
    }
}

function Disable-RootCA {
    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
        $store.Open("ReadWrite")
        $found = @($store.Certificates | Where-Object { $_.Thumbprint -eq $script:CaThumb })
        foreach ($c in $found) { $store.Remove($c) }
        $store.Close()
        if ($found.Count -gt 0) { Log "已从系统删除 Caddy 根证书" "Cyan" }
        else { Log "系统里没有该根证书" "Gray" }
    } catch {
        Log ("删除根证书失败：" + $_.Exception.Message) "Red"
    }
}

# ==================== hosts ====================
function Write-HostsFile {
    param([string]$Content)
    $lastErr = $null
    for ($i = 0; $i -lt 6; $i++) {
        try {
            Set-Content -LiteralPath $script:HostsFile -Value $Content -Encoding ASCII -Force -ErrorAction Stop
            return $true
        } catch {
            $lastErr = $_
            Start-Sleep -Milliseconds 400
        }
    }
    $m = "unknown"
    if ($lastErr) { $m = $lastErr.Exception.Message }
    Log ("写 hosts 失败：" + $m) "Red"
    return $false
}

function Set-HostsOn {
    $raw = ""
    if (Test-Path $script:HostsFile) {
        try { $raw = [IO.File]::ReadAllText($script:HostsFile, [Text.Encoding]::Default) } catch { $raw = "" }
    }
    if ($null -eq $raw) { $raw = "" }

    $raw = [regex]::Replace($raw, '(?ms)^' + [regex]::Escape($script:BeginMark) + '.*?' + [regex]::Escape($script:EndMark) + '\s*\r?\n?', '')
    $raw = [regex]::Replace($raw, '(?ms)^' + [regex]::Escape($script:OldMarkA) + '.*?' + [regex]::Escape($script:OldMarkB) + '\s*\r?\n?', '')

    $bak = Join-Path $script:Root ("hosts.bak." + (Get-Date -Format "yyyyMMdd-HHmmss"))
    try { Copy-Item -LiteralPath $script:HostsFile -Destination $bak -Force -ErrorAction SilentlyContinue } catch { }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($script:BeginMark)
    foreach ($d in $script:Domains) { [void]$sb.AppendLine("127.0.0.1 " + $d) }
    [void]$sb.AppendLine($script:EndMark)

    $new = $raw.TrimEnd() + "`r`n`r`n" + $sb.ToString()
    if (Write-HostsFile $new) {
        Log "hosts 已写入（127.0.0.1 -> steamcommunity.com / www）" "Green"
        try { ipconfig /flushdns | Out-Null } catch { }
    }
}

function Set-HostsOff {
    if (-not (Test-Path $script:HostsFile)) { return }
    try { $raw = [IO.File]::ReadAllText($script:HostsFile, [Text.Encoding]::Default) } catch { $raw = "" }
    if ($null -eq $raw) { return }
    $orig = $raw
    $raw = [regex]::Replace($raw, '(?ms)^' + [regex]::Escape($script:BeginMark) + '.*?' + [regex]::Escape($script:EndMark) + '\s*\r?\n?', '')
    $raw = [regex]::Replace($raw, '(?ms)^' + [regex]::Escape($script:OldMarkA) + '.*?' + [regex]::Escape($script:OldMarkB) + '\s*\r?\n?', '')
    foreach ($d in $script:Domains) {
        $raw = [regex]::Replace($raw, ('(?m)^\s*127\.0\.0\.1\s+' + [regex]::Escape($d) + '\s*\r?\n'), '')
    }
    if ($raw -ne $orig) {
        if (Write-HostsFile $raw.TrimEnd()) {
            Log "hosts 中的 Steam 条目已清除" "Cyan"
            try { ipconfig /flushdns | Out-Null } catch { }
        }
    } else {
        Log "hosts 里没有需要清理的条目" "Gray"
    }
}

# ==================== 开机自启 ====================
function Register-Autostart {
    try {
        foreach ($oldName in @("SteamCommunityCaddy")) {
            $ot = Get-ScheduledTask -TaskName $oldName -ErrorAction SilentlyContinue
            if ($ot) {
                Stop-ScheduledTask -TaskName $oldName -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $oldName -Confirm:$false -ErrorAction SilentlyContinue
                Log ("已删除旧版自启任务 " + $oldName) "Cyan"
            }
        }
        $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        if ($existing) { Log ("自启任务已存在（" + $existing.State + "）") "Gray"; return }
        $inner = 'cd /d "' + $script:Root + '" && "' + $script:CaddyExe + '" run --config "' + $script:Caddyfile + '"'
        $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument ('/c ' + $inner)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 `
                        -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
        $p = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + "\" + $env:USERNAME) -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $p -Force | Out-Null
        Log ("已注册开机自启任务：" + $script:TaskName) "Green"
    } catch {
        Log ("注册自启任务失败：" + $_.Exception.Message) "Yellow"
    }
}

function Unregister-Autostart {
    try {
        $removed = 0
        foreach ($tn in @($script:TaskName, "SteamCommunityCaddy")) {
            $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
            if ($t) {
                Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
                $removed++
                Log ("已删除自启任务：" + $tn) "Cyan"
            }
        }
        if ($removed -eq 0) { Log "没有自启任务" "Gray" }
    } catch {
        Log ("删除自启任务失败：" + $_.Exception.Message) "Yellow"
    }
}

# ==================== 连通性自检 ====================
function Get-CurlPath {
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return (Join-Path $env:SystemRoot "System32\curl.exe")
}

function Invoke-CurlRaw {
    param([string[]]$CurlArgs)
    $curl = Get-CurlPath
    if (-not (Test-Path $curl)) { return @("", "curl not found") }
    $backup = @{}
    foreach ($k in @("HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy","ALL_PROXY","all_proxy")) {
        $backup[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $null)
    }
    try {
        $out = & $curl @CurlArgs 2>$null
        return @(($out -join ""), "")
    } catch {
        return @("", $_.Exception.Message)
    } finally {
        foreach ($k in $backup.Keys) { [Environment]::SetEnvironmentVariable($k, $backup[$k]) }
    }
}

function Resolve-RealIP {
    param([string]$Domain)
    $r = Invoke-CurlRaw @("-s", "--max-time", "10", "-H", "accept: application/dns-json",
                          ("https://cloudflare-dns.com/dns-query?name={0}&type=A" -f $Domain))
    $txt = $r[0]
    $m = [regex]::Matches($txt, '"data"\s*:\s*"([0-9]{1,3}(\.[0-9]{1,3}){3})"')
    if ($m.Count -gt 0) { return $m[0].Groups[1].Value }
    return $null
}

function Test-SniBlocked {
    $ip = Resolve-RealIP "steamcommunity.com"
    if (-not $ip) { return @{ Blocked = $null; IP = ""; Code = ""; Tls = 0.0; Detail = "DoH 查询失败" } }
    $r = Invoke-CurlRaw @("--noproxy", "*", "-s", "-o", "NUL", "--max-time", "12",
                          "--resolve", ("steamcommunity.com:443:{0}" -f $ip),
                          "-w", "%{http_code}|%{time_appconnect}",
                          "https://steamcommunity.com/")
    $parts = $r[0].Split("|")
    $code = ""
    $tls = 0.0
    if ($parts.Count -ge 1) { $code = $parts[0] }
    if ($parts.Count -ge 2) { [double]::TryParse($parts[1], [ref]$tls) | Out-Null }
    $detail = "TLS 被重置"
    if ($tls -gt 0) { $detail = "TLS 握手成功 " + [math]::Round($tls, 3) + "s" }
    return @{ Blocked = ($tls -le 0); IP = $ip; Code = $code; Tls = $tls; Detail = $detail }
}

function Test-LocalProxyHealth {
    $r = Invoke-CurlRaw @("--noproxy", "*", "--ssl-no-revoke", "-s", "-o", "NUL", "--max-time", "12",
                          "-w", "%{http_code}|%{time_total}", "https://steamcommunity.com/")
    return $r[0]
}

# ==================== 主操作 ====================
function Invoke-Enable {
    Log "========== 开启 ==========" "Cyan"
    if (-not (Start-CaddyService)) { Log "开启失败：Caddy 未就绪" "Red"; return }
    Enable-RootCA | Out-Null
    Set-HostsOn
    Start-Sleep -Milliseconds 500
    $health = Test-LocalProxyHealth
    $p = $health.Split("|")
    if ($p.Count -ge 1 -and $p[0] -match '^(200|301|302|403)$') {
        Log ("验证通过：HTTP " + $p[0] + "，耗时 " + $p[1] + "s") "Green"
    } else {
        Log ("验证未通过：返回 [" + $health + "]（可能是上游波动，稍后点「自检」再看）") "Yellow"
    }
    Register-Autostart
    Start-Sleep -Milliseconds 900
    if (@(Get-Process -Name "caddy" -ErrorAction SilentlyContinue).Count -eq 0) {
        Log "旧任务清理后 Caddy 已停止，重新启动 ..." "Yellow"
        Start-CaddyService | Out-Null
    }
    Log "========== 完成 ==========" "Cyan"
}

function Invoke-Disable {
    Log "========== 关闭 ==========" "Cyan"
    Stop-CaddyService | Out-Null
    Set-HostsOff
    Unregister-Autostart
    Log "========== 已回到系统默认网络 ==========" "Cyan"
}

function Invoke-SelfTest {
    Log "========== 自检 ==========" "Cyan"
    $s = Get-ProxyStatus
    $v1 = if ($s.CaddyRunning) { "运行中 PID " + $s.CaddyPid } else { "未运行" }
    $v2 = if ($s.Listening) { "是" } else { "否" }
    $v3 = if ($s.HostsOn) { "127.0.0.1" } else { "未指向" }
    $v4 = if ($s.CaOn) { "已信任" } else { "未安装" }
    Log ("Caddy 进程：" + $v1)
    Log ("443 监听：" + $v2)
    Log ("hosts 指向：" + $v3)
    Log ("根证书：" + $v4)

    Log "--- 探测 SNI 封禁状态（Cloudflare DoH + 直连真实 IP）---"
    $sni = Test-SniBlocked
    if ($null -eq $sni.Blocked) {
        Log ("SNI 探测失败：" + $sni.Detail) "Yellow"
    } elseif ($sni.Blocked) {
        Log ("SNI 已被封：真实 IP " + $sni.IP + "，HTTP " + $sni.Code + "，" + $sni.Detail) "Red"
        Log "本工具的反代路径正是为这个场景准备的，请保持「开启」。" "Yellow"
    } else {
        Log ("SNI 未封：真实 IP " + $sni.IP + "，HTTP " + $sni.Code + "，" + $sni.Detail) "Green"
        Log "当前直连即可；保留本工具开启也不会变慢，只多一跳本地转发。" "Gray"
    }

    Log "--- 本机反代连通性 ---"
    if (-not $s.CaddyRunning) {
        Log "Caddy 未运行，跳过" "Yellow"
    } else {
        $h = Test-LocalProxyHealth
        $p = $h.Split("|")
        if ($p.Count -ge 1 -and $p[0] -match '^(200|301|302|403)$') {
            Log ("通过：HTTP " + $p[0] + "，耗时 " + $p[1] + "s") "Green"
        } else {
            Log ("未通过：[" + $h + "]") "Red"
        }
    }

    Log "--- 浏览器加载测试（Edge 无头，约 5 秒）---"
    $edgeList = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe")
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($edgeList.Count -eq 0) {
        Log "未找到 Edge，跳过" "Gray"
    } elseif (-not $s.CaddyRunning) {
        Log "Caddy 未运行，跳过" "Gray"
    } else {
        $edge = @($edgeList)[0]
        $tmp = Join-Path $env:TEMP ("sp_edge_" + [guid]::NewGuid().ToString("N").Substring(0,8))
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $edge
            $psi.Arguments = "--headless=new --disable-gpu --no-first-run --no-default-browser-check --user-data-dir=`"" + $tmp + "`" --virtual-time-budget=12000 --dump-dom https://steamcommunity.com/"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            foreach ($k in @("HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy","NO_PROXY","no_proxy")) {
                try { $psi.EnvironmentVariables.Remove($k) } catch { }
            }
            $p2 = [System.Diagnostics.Process]::Start($psi)
            $dom = $p2.StandardOutput.ReadToEnd()
            $p2.WaitForExit(30000) | Out-Null
            $title = [regex]::Match($dom, '<title[^>]*>(.*?)</title>', 'IgnoreCase,Singleline').Groups[1].Value.Trim()
            if ($dom.Length -gt 1000) {
                Log ("浏览器加载：DOM " + $dom.Length + " 字符，title=[" + $title + "]") "Green"
            } else {
                Log ("浏览器加载异常：DOM " + $dom.Length + " 字符，title=[" + $title + "]") "Red"
            }
        } catch {
            Log ("浏览器测试失败：" + $_.Exception.Message) "Yellow"
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Log "========== 自检结束 ==========" "Cyan"
}

function Invoke-Uninstall {
    $msg = "将执行：" + [Environment]::NewLine +
           "  1) 停止 Caddy 并关闭自启" + [Environment]::NewLine +
           "  2) 清除 hosts 里的 Steam 条目" + [Environment]::NewLine +
           "  3) 从系统移除 Caddy 根证书" + [Environment]::NewLine + [Environment]::NewLine +
           "（不会删除本目录文件）继续？"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, "确认卸载", "YesNo", "Warning")
    if ($ans -ne "Yes") { Log "已取消" "Gray"; return }
    Log "========== 卸载 ==========" "Red"
    Stop-CaddyService | Out-Null
    Set-HostsOff
    Unregister-Autostart
    Disable-RootCA
    Log "已清理系统改动。要彻底删除请手动删除本目录。" "Cyan"
    Log "========== 卸载完成 ==========" "Red"
}

# ==================== 命令行模式 ====================
if ($Test -or $EnableQuiet -or $DisableQuiet) {
    if ($Test)             { Invoke-SelfTest }
    elseif ($EnableQuiet)  { Invoke-Enable }
    elseif ($DisableQuiet) { Invoke-Disable }
    [Environment]::Exit(0)
}

# ==================== 界面 ====================
[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = "Steam 社区直连工具"
$form.Size = New-Object System.Drawing.Size(660, 620)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:CaddyExe) } catch { }

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Steam 社区直连（Caddy 域前置）"
$lblTitle.Location = New-Object System.Drawing.Point(16, 14)
$lblTitle.Size = New-Object System.Drawing.Size(600, 26)
$lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 235)
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "SNI 被墙时照样可用：本机终结 TLS，再转发到 Valve 白名单域名"
$lblSub.Location = New-Object System.Drawing.Point(18, 40)
$lblSub.Size = New-Object System.Drawing.Size(600, 20)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 148)
$form.Controls.Add($lblSub)

$script:lblOverall = New-Object System.Windows.Forms.Label
$script:lblOverall.Text = "正在读取状态 ..."
$script:lblOverall.Location = New-Object System.Drawing.Point(16, 68)
$script:lblOverall.Size = New-Object System.Drawing.Size(600, 24)
$script:lblOverall.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($script:lblOverall)

$yy = 100
$script:lblCaddy = New-Object System.Windows.Forms.Label
$script:lblHosts = New-Object System.Windows.Forms.Label
$script:lblCa    = New-Object System.Windows.Forms.Label
$script:lblPort  = New-Object System.Windows.Forms.Label
foreach ($lb in @($script:lblCaddy, $script:lblHosts, $script:lblCa, $script:lblPort)) {
    $lb.Location = New-Object System.Drawing.Point(20, $yy)
    $lb.Size = New-Object System.Drawing.Size(600, 20)
    $lb.Text = "..."
    $form.Controls.Add($lb)
    $yy += 22
}

function New-FlatButton {
    param([string]$Text, [int]$X, [int]$W, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, 196)
    $b.Size = New-Object System.Drawing.Size($W, 36)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

$btnOn   = New-FlatButton "开  启"   20  120 ([System.Drawing.Color]::FromArgb(46, 110, 72))  ([System.Drawing.Color]::White)
$btnOff  = New-FlatButton "关  闭"   150 120 ([System.Drawing.Color]::FromArgb(72, 72, 80))   ([System.Drawing.Color]::White)
$btnTest = New-FlatButton "自  检"   280 120 ([System.Drawing.Color]::FromArgb(48, 82, 120))  ([System.Drawing.Color]::White)
$btnDir  = New-FlatButton "打开目录" 410 100 ([System.Drawing.Color]::FromArgb(50, 50, 56))   ([System.Drawing.Color]::FromArgb(210,210,215))
$btnUn   = New-FlatButton "卸  载"   520 110 ([System.Drawing.Color]::FromArgb(96, 44, 44))   ([System.Drawing.Color]::White)
foreach ($b in @($btnOn, $btnOff, $btnTest, $btnDir, $btnUn)) { $form.Controls.Add($b) }

$script:logBox = New-Object System.Windows.Forms.RichTextBox
$script:logBox.Location = New-Object System.Drawing.Point(20, 248)
$script:logBox.Size = New-Object System.Drawing.Size(610, 300)
$script:logBox.BackColor = [System.Drawing.Color]::FromArgb(16, 16, 20)
$script:logBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 205)
$script:logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:logBox.ReadOnly = $true
$script:logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:logBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$form.Controls.Add($script:logBox)

$lblFoot = New-Object System.Windows.Forms.Label
$lblFoot.Text = "改动：hosts 2 行 / 本地根证书 / 443 本地监听 / 可选开机自启。全部可用「卸载」还原。"
$lblFoot.Location = New-Object System.Drawing.Point(20, 556)
$lblFoot.Size = New-Object System.Drawing.Size(610, 18)
$lblFoot.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 128)
$form.Controls.Add($lblFoot)

$btnOn.Add_Click({
    $btnOn.Enabled = $false; $btnOff.Enabled = $false; $btnTest.Enabled = $false
    try { Invoke-Enable } catch { Log ("异常：" + $_.Exception.Message) "Red" }
    finally {
        $btnOn.Enabled = $true; $btnOff.Enabled = $true; $btnTest.Enabled = $true
        Refresh-Status | Out-Null
    }
})
$btnOff.Add_Click({
    $btnOn.Enabled = $false; $btnOff.Enabled = $false; $btnTest.Enabled = $false
    try { Invoke-Disable } catch { Log ("异常：" + $_.Exception.Message) "Red" }
    finally {
        $btnOn.Enabled = $true; $btnOff.Enabled = $true; $btnTest.Enabled = $true
        Refresh-Status | Out-Null
    }
})
$btnTest.Add_Click({
    $btnOn.Enabled = $false; $btnOff.Enabled = $false; $btnTest.Enabled = $false
    try { Invoke-SelfTest } catch { Log ("异常：" + $_.Exception.Message) "Red" }
    finally {
        $btnOn.Enabled = $true; $btnOff.Enabled = $true; $btnTest.Enabled = $true
        Refresh-Status | Out-Null
    }
})
$btnDir.Add_Click({ Start-Process explorer.exe $script:Root })
$btnUn.Add_Click({
    try { Invoke-Uninstall } catch { Log ("异常：" + $_.Exception.Message) "Red" }
    finally { Refresh-Status | Out-Null }
})

$form.Add_Shown({
    Log "Steam 社区直连工具已启动" "Cyan"
    Log ("工作目录：" + $script:Root)
    $caddyState = "缺失！"
    if (Test-Path $script:CaddyExe) { $caddyState = "存在" }
    Log ("caddy.exe：" + $caddyState)
    Refresh-Status | Out-Null
    Log "点「开启」启用反代，点「自检」查看 SNI 是否被墙。" "Gray"
})

[void]$form.ShowDialog()
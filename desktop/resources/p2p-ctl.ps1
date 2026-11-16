<#
  p2p-ctl.ps1 — P2P 直连三通道控制器

  A) hole    UDP 打洞：STUN 发现映射 + 端口喷射 + 心跳/时延/字节统计 + 可选 UDP 端口转发
  B) relay   Cloudflare Workers WebSocket 中继：连到同一个 room，由 Worker 双向转发
  C) tunnel  现成免费 TCP 隧道：cpolar / ngrok / bore / cloudflared / frpc

  用法：
    p2p-ctl.ps1 -Action probe
    p2p-ctl.ps1 -Action status
    p2p-ctl.ps1 -Action hole-start  -Peer 1.2.3.4:5678 [-Port 26999] [-LocalUdp 19132 -PeerUdp 19132]
    p2p-ctl.ps1 -Action hole-stop
    p2p-ctl.ps1 -Action relay-start -Worker wss://xxx.workers.dev -Room demo
    p2p-ctl.ps1 -Action relay-stop
    p2p-ctl.ps1 -Action tunnel-list
    p2p-ctl.ps1 -Action tunnel-start -Provider cpolar -LocalPort 25565
    p2p-ctl.ps1 -Action tunnel-stop

  状态全部落在脚本同目录的 p2p-*.json，界面读文件即可，不必起进程。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Action,
  [int]$Port = 26999,
  [string]$Peer = '',
  [int]$Spray = 64,
  [int]$LocalUdp = 0,
  [int]$PeerUdp = 0,
  [string]$Room = '',
  [string]$Worker = '',
  [string]$Provider = 'auto',
  [int]$LocalPort = 25565,
  [string]$StunServer = '111.206.174.2:3478',
  [string]$StunServer2 = '106.13.248.6:3478'
)

$ErrorActionPreference = 'Stop'
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path -Parent $ScriptPath
$HoleState = Join-Path $ScriptDir 'p2p-hole.json'
$HoleLog   = Join-Path $ScriptDir 'p2p-hole.log'
$RelayState = Join-Path $ScriptDir 'p2p-relay.json'
$RelayLog   = Join-Path $ScriptDir 'p2p-relay.log'
$TunnelState = Join-Path $ScriptDir 'p2p-tunnel.json'
$TunnelLog   = Join-Path $ScriptDir 'p2p-tunnel.log'
$ToolsDir    = Join-Path $ScriptDir 'tools'
$CfLog       = Join-Path $ScriptDir 'p2p-cf.log'
if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }

# ==================== 通用 ====================

function Write-P2PLog {
  param([string]$File, [string]$Text)
  $line = ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text)
  Add-Content -LiteralPath $File -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Save-State {
  param([string]$Path, [hashtable]$Data)
  try {
    $json = $Data | ConvertTo-Json -Compress -Depth 4
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
  } catch { }
}

function Load-State {
  param([string]$Path)
  $empty = @{ state = 'idle' }
  if (-not (Test-Path -LiteralPath $Path)) { return $empty }
  try {
    $txt = [IO.File]::ReadAllText($Path)
    if (-not $txt.Trim()) { return $empty }
    $o = $txt | ConvertFrom-Json
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
  } catch { return $empty }
}

function Get-S {
  param([hashtable]$H, [string]$Key, [string]$Default = '')
  if ($H.ContainsKey($Key) -and $null -ne $H[$Key]) { return [string]$H[$Key] }
  return $Default
}

# 结束整棵进程树。
# WMI 兜底启动时我们拿到的 PID 是 cmd.exe，真正的 bore / wrangler 是它的子进程，
# 只杀父进程会留下孤儿——用户看到「已停止」但端口还被占着。
function Stop-Tree {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return }
  try {
    $children = Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $ProcessId) -ErrorAction SilentlyContinue
    foreach ($c in $children) { Stop-Tree -ProcessId ([int]$c.ProcessId) }
  } catch { }
  try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
}

# 先查 PATH，再查我们自己下载的工具目录
function Find-Exe {
  param([string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $local = Join-Path $ToolsDir ($Name + '.exe')
  if (Test-Path -LiteralPath $local) { return $local }
  return ''
}

# 起一个隐藏的后台进程，返回 PID。
#
# 为什么不能直接用 Start-Process：如果这台机器的环境块里同一变量有大小写两份
# （装了 Clash / 各类代理工具后很常见，比如 HTTPS_PROXY 和 https_proxy 同时存在），
# Start-Process 会抛 "Item has already been added"，而且这个错与我们的参数无关，
# 表现是「点了启动什么都没发生」。这种情况下改走 WMI 创建进程：
# 由 WMI 服务端起进程，不复制我们这块环境，问题消失。
function Start-Hidden {
  param(
    [string]$FilePath,
    [string]$ArgumentString = '',
    [string]$WorkingDirectory = '',
    [string]$OutLog = ''
  )
  # npm 装出来的 wrangler 是 .cmd / .ps1 垫片，Windows 不把它当可执行文件，
  # 直接 Start-Process 会报「不是有效的应用程序」，先换成对应的宿主。
  $origPath = $FilePath
  $origArgs = $ArgumentString
  $lower = $FilePath.ToLowerInvariant()
  if ($lower.EndsWith('.cmd') -or $lower.EndsWith('.bat')) {
    $FilePath = 'cmd.exe'
    $ArgumentString = '/c "' + $origPath + '" ' + $origArgs
  } elseif ($lower.EndsWith('.ps1')) {
    $FilePath = 'powershell.exe'
    $ArgumentString = '-NoProfile -ExecutionPolicy Bypass -File "' + $origPath + '" ' + $origArgs
  }
  try {
    $psArgs = @{
      FilePath     = $FilePath
      WindowStyle  = 'Hidden'
      PassThru     = $true
      ErrorAction  = 'Stop'
    }
    if ($ArgumentString) { $psArgs['ArgumentList'] = $ArgumentString }
    if ($WorkingDirectory) { $psArgs['WorkingDirectory'] = $WorkingDirectory }
    if ($OutLog) {
      $psArgs['RedirectStandardOutput'] = $OutLog
      $psArgs['RedirectStandardError']  = ($OutLog + '.err')
    }
    $p = Start-Process @psArgs
    return [int]$p.Id
  } catch {
    if ($_.Exception.Message -notmatch 'already been added') { throw }
    Write-P2PLog $CfLog ('环境变量大小写重复，改用 WMI 启动：' + $FilePath)
    $inner = '"' + $FilePath + '"'
    if ($ArgumentString) { $inner = $inner + ' ' + $ArgumentString }
    if ($WorkingDirectory) { $inner = 'cd /d "' + $WorkingDirectory + '" & ' + $inner }
    if ($OutLog) { $inner = $inner + ' > "' + $OutLog + '" 2>&1' }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('cmd.exe /c "' + $inner + '"') }
    if ($null -eq $r -or $r.ReturnValue -ne 0) {
      throw ('WMI 启动失败，返回码 ' + $(if ($r) { $r.ReturnValue } else { 'null' }))
    }
    return [int]$r.ProcessId
  }
}

# ==================== STUN ====================

function New-StunRequest {
  $b = New-Object byte[] 20
  $b[0] = 0; $b[1] = 1; $b[2] = 0; $b[3] = 0
  $b[4] = 0x21; $b[5] = 0x12; $b[6] = 0xA4; $b[7] = 0x42
  $rnd = [Security.Cryptography.RandomNumberGenerator]::Create()
  $t = New-Object byte[] 12
  $rnd.GetBytes($t)
  [Array]::Copy($t, 0, $b, 8, 12)
  return $b
}

function Read-StunMapping {
  param([byte[]]$Resp)
  if ($null -eq $Resp -or $Resp.Length -lt 20) { return $null }
  $k = 20
  while ($k + 4 -le $Resp.Length) {
    $ty = ($Resp[$k] -shl 8) -bor $Resp[$k + 1]
    $ln = ($Resp[$k + 2] -shl 8) -bor $Resp[$k + 3]
    if ($ty -eq 0x0020 -and $ln -ge 8 -and $Resp[$k + 5] -eq 1) {
      $p = (($Resp[$k + 6] -bxor 0x21) -shl 8) -bor ($Resp[$k + 7] -bxor 0x12)
      $ip = '{0}.{1}.{2}.{3}' -f ($Resp[$k + 8] -bxor 0x21), ($Resp[$k + 9] -bxor 0x12), ($Resp[$k + 10] -bxor 0xA4), ($Resp[$k + 11] -bxor 0x42)
      return @{ ip = $ip; port = [int]$p }
    }
    $k += 4 + $ln + ((4 - ($ln % 4)) % 4)
  }
  return $null
}

function Resolve-Stun {
  param([string]$Spec)
  $parts = $Spec.Split(':')
  $hostName = $parts[0]
  $p = 3478
  if ($parts.Length -ge 2) { $p = [int]$parts[1] }
  $ip = $hostName
  if ($hostName -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    $r = Resolve-DnsName $hostName -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1
    if ($null -eq $r) { return $null }
    $ip = $r.IPAddress
  }
  return New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ip), $p)
}

function Get-Mapping {
  param([System.Net.Sockets.UdpClient]$Client, [System.Net.IPEndPoint]$Stun, [int]$TimeoutMs = 2000)
  $Client.Client.ReceiveTimeout = $TimeoutMs
  [void]$Client.Send((New-StunRequest), 20, $Stun)
  $rm = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
  $resp = $Client.Receive([ref]$rm)
  return Read-StunMapping $resp
}

# ==================== A. UDP 打洞 ====================

$PNP = [byte[]](0x50, 0x4E, 0x50, 0x31)   # "PNP1"

function Test-PnpMagic {
  param([byte[]]$D)
  if ($D.Length -lt 5) { return $false }
  return ($D[0] -eq 0x50 -and $D[1] -eq 0x4E -and $D[2] -eq 0x50 -and $D[3] -eq 0x31)
}

function New-PnpPacket {
  param([byte]$Type, [byte[]]$Payload)
  $n = 5 + $Payload.Length
  $b = New-Object byte[] $n
  $b[0] = 0x50; $b[1] = 0x4E; $b[2] = 0x50; $b[3] = 0x31
  $b[4] = $Type
  [Array]::Copy($Payload, 0, $b, 5, $Payload.Length)
  return $b
}

function Invoke-HoleRun {
  param([int]$Port, [string]$Peer, [int]$Spray, [string]$StunServer, [string]$StunServer2, [int]$LocalUdp, [int]$PeerUdp)

  Write-P2PLog $HoleLog ('hole-run 启动 本地端口=' + $Port + ' 对端=' + $(if ($Peer) { $Peer } else { '(等待)' }))

  $sock = $null
  try {
    $sock = New-Object System.Net.Sockets.UdpClient($Port)
  } catch {
    Save-State $HoleState @{ state = 'error'; error = ('本地端口 ' + $Port + ' 被占用'); pid = $PID }
    Write-P2PLog $HoleLog ('绑定 ' + $Port + ' 失败：' + $_.Exception.Message)
    return
  }
  $sock.Client.ReceiveTimeout = 200

  # --- STUN 探测：拿自己的公网映射 ---
  $mapping = $null
  $natType = 'unknown'
  try {
    $ep1 = Resolve-Stun $StunServer
    $m1 = Get-Mapping $sock $ep1
    if ($m1) {
      $mapping = ('{0}:{1}' -f $m1.ip, $m1.port)
      $ep2 = Resolve-Stun $StunServer2
      if ($ep2) {
        $m2 = Get-Mapping $sock $ep2
        if ($m2) {
          if ($m2.port -eq $m1.port -and $m2.ip -eq $m1.ip) { $natType = 'cone' }
          else { $natType = 'symmetric' }
        }
      }
    }
  } catch {
    Write-P2PLog $HoleLog ('STUN 失败：' + $_.Exception.Message)
  }

  $invite = ''
  if ($mapping) {
    $raw = ('{0}|{1}' -f $mapping, $Port)
    $invite = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))
  }

  $peerEp = $null
  if ($Peer -and $Peer.Contains(':')) {
    $pp = $Peer.Split(':')
    try { $peerEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($pp[0]), [int]$pp[1]) } catch { }
  }

  $appSock = $null
  if ($LocalUdp -gt 0) {
    try {
      $appSock = New-Object System.Net.Sockets.UdpClient((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, $LocalUdp)))
      Write-P2PLog $HoleLog ('UDP 转发本地口 127.0.0.1:' + $LocalUdp + ' -> 对端口 ' + $PeerUdp)
    } catch {
      Write-P2PLog $HoleLog ('绑定本地 UDP ' + $LocalUdp + ' 失败：' + $_.Exception.Message)
    }
  }

  $state = 'waiting'
  if ($peerEp) { $state = 'punching' }
  $connected = $false
  $peerLive = ''
  $rtt = 0
  $rx = 0
  $tx = 0
  $lastBeat = [DateTime]::MinValue
  $pingSent = [DateTime]::MinValue
  $pingTicks = 0L
  $lastSave = [DateTime]::MinValue
  $started = Get-Date

  while ($true) {
    $now = Get-Date

    # ---------- 发包：打洞 / 心跳 ----------
    if ($peerEp) {
      try {
        if (-not $connected) {
          # 向目标端口附近喷射：对端若是对称 NAT，真实映射会落在 +-Spray 内
          $base = $peerEp.Port
          $lo = [Math]::Max(1, $base - $Spray)
          $hi = [Math]::Min(65535, $base + $Spray)
          for ($p = $lo; $p -le $hi; $p++) {
            $t = New-PnpPacket 1 ([BitConverter]::GetBytes([int64]$now.Ticks))
            $ep = New-Object System.Net.IPEndPoint($peerEp.Address, $p)
            try { $tx += $sock.Send($t, $t.Length, $ep) } catch { }
          }
        } else {
          if (($now - $lastBeat).TotalMilliseconds -ge 200) {
            $t = New-PnpPacket 1 ([BitConverter]::GetBytes([int64]$now.Ticks))
            try { $tx += $sock.Send($t, $t.Length, $peerEp) } catch { }
            $lastBeat = $now
          }
        }
      } catch { }
    }

    # ---------- 收包 ----------
    try {
      while ($sock.Client.Available -gt 0) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $d = $sock.Receive([ref]$remote)
        if (-not (Test-PnpMagic $d)) { continue }   # STUN 等非本协议包，丢弃
        $rx += $d.Length

        if (-not $connected) {
          $connected = $true
          $state = 'connected'
          $peerLive = ('{0}:{1}' -f $remote.Address.ToString(), $remote.Port)
          $peerEp = $remote          # 以真实来源为准（对称 NAT 修正）
          Write-P2PLog $HoleLog ('打洞成功，对端 ' + $peerLive)
        }

        $type = $d[4]
        if ($type -eq 1) {
          # PING -> 原样回 PONG
          $pl = New-Object byte[] ([Math]::Max(0, $d.Length - 5))
          if ($pl.Length -gt 0) { [Array]::Copy($d, 5, $pl, 0, $pl.Length) }
          $pong = New-PnpPacket 2 $pl
          try { $tx += $sock.Send($pong, $pong.Length, $peerEp) } catch { }
        } elseif ($type -eq 2) {
          if ($d.Length -ge 13) {
            $sent = [BitConverter]::ToInt64($d, 5)
            $ms = [int](((Get-Date).Ticks - $sent) / 10000)
            if ($ms -ge 0 -and $ms -lt 60000) { $rtt = $ms }
          }
        } elseif ($type -eq 0) {
          # DATA -> 投给本地应用
          if ($appSock -and $PeerUdp -gt 0 -and $d.Length -gt 5) {
            $pl = New-Object byte[] ($d.Length - 5)
            [Array]::Copy($d, 5, $pl, 0, $pl.Length)
            try {
              $dst = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, $PeerUdp)
              [void]$appSock.Send($pl, $pl.Length, $dst)
            } catch { }
          }
        }
      }
    } catch [System.Net.Sockets.SocketException] {
      # 接收超时，正常
    } catch { }

    # ---------- 本地应用 -> 隧道 ----------
    if ($appSock -and $connected -and $peerEp) {
      try {
        while ($appSock.Available -gt 0) {
          $src = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
          $d = $appSock.Receive([ref]$src)
          if ($d.Length -gt 1400) { $d = $d[0..1399] }
          $pkt = New-PnpPacket 0 $d
          try { $tx += $sock.Send($pkt, $pkt.Length, $peerEp) } catch { }
        }
      } catch { }
    }

    # ---------- 周期落状态 ----------
    if (($now - $lastSave).TotalMilliseconds -ge 800) {
      $lastSave = $now
      Save-State $HoleState @{
        state = $state; pid = $PID; localPort = $Port; mapping = $mapping; natType = $natType
        invite = $invite; peer = $peerLive; rtt = $rtt; rx = $rx; tx = $tx
        localUdp = $LocalUdp; peerUdp = $PeerUdp
        uptimeSec = [int]($now - $started).TotalSeconds
        error = ''
      }
    }

    Start-Sleep -Milliseconds 4
  }
}

function Stop-HoleRun {
  $st = Load-State $HoleState
  $procId = 0
  if ($st.ContainsKey('pid')) { [int]::TryParse([string]$st['pid'], [ref]$procId) | Out-Null }
  if ($procId -gt 0) {
    try { Stop-Tree -ProcessId $procId } catch { }
  }
  Save-State $HoleState @{ state = 'idle' }
  Write-Output ('A 通道已停止（PID ' + $procId + '）')
}

function Start-HoleRun {
  # 先清掉旧进程
  $old = Load-State $HoleState
  if ($old.ContainsKey('pid')) {
    $oid = 0
    if ([int]::TryParse([string]$old['pid'], [ref]$oid) -and $oid -gt 0) {
      try { Stop-Tree -ProcessId $oid } catch { }
    }
  }

  # 用相对文件名 + -WorkingDirectory 传参：Start-Process 的 -ArgumentList 不会自动加引号，
  # 而这个脚本路径含空格（"parallel networking"），直接传会被拆成两个参数。
  $a = '-NoProfile -ExecutionPolicy Bypass -File "p2p-ctl.ps1" -Action hole-run -Port ' + $Port +
       ' -Spray ' + $Spray + ' -StunServer "' + $StunServer + '" -StunServer2 "' + $StunServer2 + '"'
  if ($Peer) { $a += ' -Peer "' + $Peer + '"' }
  if ($LocalUdp -gt 0) { $a += ' -LocalUdp ' + $LocalUdp + ' -PeerUdp ' + $PeerUdp }

  $childPid = Start-Hidden -FilePath 'powershell.exe' -ArgumentString $a -WorkingDirectory $ScriptDir
  Start-Sleep -Milliseconds 1800

  $st = Load-State $HoleState
  Write-Log2 ('A 通道已启动（PID ' + $childPid + '）')
  if (Get-S $st 'mapping') { Write-Log2 ('  本机映射：' + (Get-S $st 'mapping') + '   NAT 类型：' + (Get-S $st 'natType')) }
  if (Get-S $st 'invite') { Write-Log2 ('  邀请码：' + (Get-S $st 'invite')) }
  if (Get-S $st 'peer') { Write-Log2 ('  对端：' + (Get-S $st 'peer')) }
  if (-not (Get-S $st 'mapping')) { Write-Log2 '  注意：STUN 未取到映射，该网络可能封了 UDP 3478。' }
}

function Write-Log2 { param([string]$T) Write-Output $T }

# ==================== B. Cloudflare Workers 中继 ====================

function Invoke-RelayRun {
  param([string]$Worker, [string]$Room)

  Write-P2PLog $RelayLog ('relay-run 启动 worker=' + $Worker + ' room=' + $Room)

  if (-not $Worker) {
    Save-State $RelayState @{ state = 'error'; error = '未提供 Worker 地址'; pid = $PID }
    return
  }
  $base = $Worker.TrimEnd('/')
  if ($base -notmatch '^wss?://') { $base = 'wss://' + $base }
  $url = $base + '/room/' + [Uri]::EscapeDataString($Room)

  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
  $ct = [Threading.CancellationToken]::None

  $connected = $false
  try {
    $ws.ConnectAsync([Uri]$url, $ct).Wait(12000)
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw ('状态 ' + $ws.State) }
    $connected = $true
    Write-P2PLog $RelayLog ('已连接 ' + $url)
  } catch {
    Save-State $RelayState @{ state = 'error'; error = ('连接失败：' + $_.Exception.Message); pid = $PID; worker = $Worker; room = $Room }
    Write-P2PLog $RelayLog ('连接失败：' + $_.Exception.Message)
    return
  }

  $buf = New-Object byte[] 65536
  $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
  $rx = 0; $tx = 0; $peers = 0
  $lastSave = [DateTime]::MinValue
  $lastBeat = Get-Date
  $started = Get-Date
  $task = $ws.ReceiveAsync($seg, $ct)

  while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
    $now = Get-Date
    if ($task.Wait(400)) {
      try {
        $r = $task.Result
      } catch {
        Write-P2PLog $RelayLog ('接收异常：' + $_.Exception.Message)
        break
      }
      if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { break }
      $rx += $r.Count
      if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
        $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
        if ($txt -match '"peers"\s*:\s*(\d+)') { $peers = [int]$Matches[1] }
      }
      $task = $ws.ReceiveAsync($seg, $ct)
    } else {
      if (($now - $lastBeat).TotalSeconds -ge 15) {
        $lastBeat = $now
        $hb = [Text.Encoding]::UTF8.GetBytes('{"t":"ping"}')
        try { $ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(, $hb)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(3000) } catch { }
        $tx += $hb.Length
      }
    }

    if (($now - $lastSave).TotalMilliseconds -ge 800) {
      $lastSave = $now
      Save-State $RelayState @{
        state = 'connected'; pid = $PID; worker = $Worker; room = $Room
        peers = $peers; rx = $rx; tx = $tx
        uptimeSec = [int]($now - $started).TotalSeconds; error = ''
      }
    }
  }

  Save-State $RelayState @{ state = 'closed'; pid = 0; worker = $Worker; room = $Room; peers = 0; rx = $rx; tx = $tx; error = '' }
  try { $ws.Dispose() } catch { }
}

function Start-RelayRun {
  # 先看账号：没连 Cloudflare 就直接把浏览器拉起来，别让用户对着一句「连不上」猜。
  $cf = Get-CfState
  if (-not $cf.login) {
    Write-Output '本机还没连上 Cloudflare 账号。'
    Invoke-CfLogin
    Save-State $RelayState @{
      state = 'error'; pid = 0; worker = $Worker; room = $Room; peers = 0; rx = 0; tx = 0
      error = '还没连上 Cloudflare 账号，已自动打开浏览器；授权完再点一次启动'
    }
    return
  }
  if (-not $Worker) {
    Save-State $RelayState @{
      state = 'error'; pid = 0; worker = ''; room = $Room; peers = 0; rx = 0; tx = 0
      error = '还没填 Worker 地址。点「一键部署」可以直接部署并自动填好'
    }
    Write-Output 'Worker 地址是空的。点「一键部署」会自动建好并填进来。'
    return
  }

  $old = Load-State $RelayState
  if ($old.ContainsKey('pid')) {
    $oid = 0
    if ([int]::TryParse([string]$old['pid'], [ref]$oid) -and $oid -gt 0) {
      try { Stop-Tree -ProcessId $oid } catch { }
    }
  }
  if (-not $Room) { $Room = 'p2p-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
  Write-Output ('房间号：' + $Room)

  $a = '-NoProfile -ExecutionPolicy Bypass -File "p2p-ctl.ps1" -Action relay-run -Worker "' +
       $Worker + '" -Room "' + $Room + '"'
  $childPid = Start-Hidden -FilePath 'powershell.exe' -ArgumentString $a -WorkingDirectory $ScriptDir
  Start-Sleep -Milliseconds 2500

  $st = Load-State $RelayState
  Write-Output ('B 通道已启动（PID ' + $childPid + '）状态=' + (Get-S $st 'state'))
  if (Get-S $st 'error') { Write-Output ('  错误：' + (Get-S $st 'error')) }
}

function Stop-RelayRun {
  $st = Load-State $RelayState
  $procId = 0
  if ($st.ContainsKey('pid')) { [int]::TryParse([string]$st['pid'], [ref]$procId) | Out-Null }
  if ($procId -gt 0) {
    try { Stop-Tree -ProcessId $procId } catch { }
  }
  Save-State $RelayState @{ state = 'idle' }
  Write-Output ('B 通道已停止（PID ' + $procId + '）')
}

# ==================== B. Cloudflare 账号 / 部署 ====================

$CfLoginPage = 'https://dash.cloudflare.com/login'

function Open-Browser {
  param([string]$Url)
  # 不直接用 Start-Process $url：那同样会踩上面说的「环境变量大小写重复」，
  # 走 Start-Hidden 才有 WMI 兜底。
  Start-Hidden -FilePath 'cmd.exe' -ArgumentString ('/c start "" "' + $Url + '"') | Out-Null
  Write-Output ('已打开浏览器：' + $Url)
}

function Get-CfState {
  $wrangler = Find-Exe 'wrangler'
  $npm = Find-Exe 'npm'
  $npx = Find-Exe 'npx'
  # wrangler 的 OAuth 令牌位置随版本和平台变过，这里把几个可能有地方都看一眼；
  # 另外认环境变量里的 API Token（CI 里常用这种）。
  $cands = @(
    (Join-Path $env:USERPROFILE '.wrangler\config\default.toml'),
    (Join-Path $env:APPDATA '.wrangler\config\default.toml'),
    (Join-Path $env:LOCALAPPDATA '.wrangler\config\default.toml'),
    (Join-Path $env:USERPROFILE '.config\.wrangler\config\default.toml')
  )
  $cfg = ''
  foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath $c) -and ((Get-Item -LiteralPath $c).Length -gt 0)) { $cfg = $c; break }
  }
  $hasToken = [bool]$env:CLOUDFLARE_API_TOKEN
  return [pscustomobject]@{
    wrangler = $wrangler
    npm      = $npm
    npx      = $npx
    config   = $cfg
    login    = [bool]($cfg -or $hasToken)
  }
}

function Show-CfStatus {
  $s = Get-CfState
  Write-Output ('CF_WRANGLER=' + $(if ($s.wrangler) { $s.wrangler } else { '' }))
  Write-Output ('CF_NPM=' + $(if ($s.npm) { $s.npm } else { '' }))
  Write-Output ('CF_LOGIN=' + $(if ($s.login) { 'yes' } else { 'no' }))
  Write-Output ('CF_CONFIG=' + $(if ($s.config) { $s.config } else { '未授权' }))
  if (-not $s.login) {
    Write-Output ''
    Write-Output '还没连上 Cloudflare 账号，点「登录 Cloudflare」会自动打开浏览器授权。'
  }
}

function Install-Wrangler {
  $s = Get-CfState
  if ($s.wrangler) { return $s.wrangler }
  if (-not $s.npm) {
    throw '本机没有 npm，装不了 wrangler。先装 Node.js，或者直接去 dash.cloudflare.com 手动建 Worker。'
  }
  Write-Output '正在安装 wrangler（npm 全局包，约 30 MB，首次较慢）…'
  $out = & $s.npm install -g wrangler 2>&1 | Out-String
  Write-Output $out
  $again = Get-CfState
  if (-not $again.wrangler) {
    throw 'wrangler 安装失败，看上面的 npm 输出。'
  }
  Write-Output ('已安装：' + $again.wrangler)
  return $again.wrangler
}

function Invoke-CfLogin {
  $s = Get-CfState
  if ($s.login) {
    Write-Output ('已经连上 Cloudflare 账号了（' + $s.config + '）。')
    return
  }
  if (-not $s.wrangler -and $s.npm) {
    try { Install-Wrangler | Out-Null } catch { Write-Output $_.Exception.Message }
  }
  $s = Get-CfState
  if (-not $s.wrangler) {
    # 没有 wrangler 就没法走 OAuth，只能把人送到登录页
    Open-Browser $CfLoginPage
    Write-Output '浏览器已打开 Cloudflare 登录页。装上 Node.js 后本机才能自动部署，否则要在网页里手动建 Worker。'
    return
  }
  # wrangler login 会自己拉起浏览器完成 OAuth，这里只负责把它放后台
  $log = $CfLog
  if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
  $argStr = 'login'
  Start-Hidden -FilePath $s.wrangler -ArgumentString $argStr -OutLog $log | Out-Null
  Write-Output '已在后台启动 wrangler login，浏览器会自动打开 Cloudflare 授权页。'
  Write-Output '在页面上点 Allow 完成授权，然后回来点「刷新状态」——CF_LOGIN 会变成 yes。'
}

function Invoke-CfDeploy {
  $s = Get-CfState
  if (-not $s.login) {
    Invoke-CfLogin | Out-Null
    Write-Output ''
    Write-Output '还没授权，已先打开登录流程。授权完成后回来再点一次「一键部署」。'
    return
  }
  if (-not $s.wrangler) {
    try { $s.wrangler = Install-Wrangler } catch { Write-Output $_.Exception.Message; return }
  }

  $work = Join-Path $ToolsDir 'relay'
  if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
  $srcJs = Join-Path $ScriptDir 'p2p-worker.js'
  $srcToml = Join-Path $ScriptDir 'wrangler.toml'
  if (-not (Test-Path -LiteralPath $srcJs)) { Write-Output '缺少 p2p-worker.js，无法部署。'; return }
  Copy-Item $srcJs (Join-Path $work 'p2p-worker.js') -Force
  if (Test-Path -LiteralPath $srcToml) { Copy-Item $srcToml (Join-Path $work 'wrangler.toml') -Force }

  Write-Output ('部署目录：' + $work)
  Write-Output '正在执行 wrangler deploy（首次会先装依赖，可能要一两分钟）…'
  Push-Location $work
  try {
    $out = & $s.wrangler deploy 2>&1 | Out-String
  } finally {
    Pop-Location
  }
  Write-Output $out

  $url = ''
  $m = [regex]::Match($out, '(https://[A-Za-z0-9._-]+\.workers\.dev)')
  if ($m.Success) { $url = $m.Groups[1].Value }
  if ($url) {
    $st = Load-State $RelayState
    $new = @{}
    foreach ($k in $st.Keys) { $new[$k] = $st[$k] }
    $new['worker'] = $url
    if (-not $new.ContainsKey('state')) { $new['state'] = 'idle' }
    Save-State $RelayState $new
    Write-Output ''
    Write-Output ('部署成功：' + $url)
    Write-Output '已自动填进 B 通道的 Worker 一栏，点「刷新状态」就能看到。'
  } else {
    Write-Output ''
    Write-Output '没从输出里认出 workers.dev 地址。若上面显示部署成功，把地址手动填进 Worker 一栏。'
  }
}

# ==================== C. 现成免费 TCP 隧道 ====================

function Get-TunnelProviders {
  $list = @(
    @{ id = 'cpolar';    exe = 'cpolar';    args = 'tcp {PORT}';                 note = '国内 65ms，免费版 2 条隧道' },
    @{ id = 'bore';      exe = 'bore';      args = 'local {PORT} --to bore.pub'; note = '公共服务器 292ms，无需注册' },
    @{ id = 'ngrok';     exe = 'ngrok';     args = 'tcp {PORT}';                 note = '153ms，需 authtoken' },
    @{ id = 'cloudflared'; exe = 'cloudflared'; args = 'tunnel --url tcp://localhost:{PORT}'; note = '需登录 Cloudflare，支持 TCP' },
    @{ id = 'frpc';      exe = 'frpc';      args = '-c frpc.ini';                note = '需自备 frps 或公共 frps' }
  )
  $found = @()
  foreach ($p in $list) {
    $path = Find-Exe $p.exe
    $has = [bool]$path
    $found += [pscustomobject]@{ id = $p.id; exe = $p.exe; installed = $has; path = $path; note = $p.note; args = $p.args }
  }
  return $found
}

# bore 是唯一「不用注册、单文件、支持任意 TCP」的，所以只有它值得自动装。
function Install-Tunnel {
  param([string]$Provider)
  if ($Provider -ne 'bore') {
    throw ($Provider + ' 需要注册或登录，没法静默装好。')
  }
  if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }
  $ProgressPreference = 'SilentlyContinue'
  $url = 'https://github.com/ekzhang/bore/releases/download/v0.5.3/bore-v0.5.3-x86_64-pc-windows-msvc.zip'
  $zip = Join-Path $ToolsDir 'bore.zip'
  $ex  = Join-Path $ToolsDir 'bore-extract'
  Write-Output '正在下载 bore（约 660 KB，从 GitHub 直连）…'
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 120
  Write-Output ('下载完成：' + [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB) + ' KB')
  if (Test-Path -LiteralPath $ex) { Remove-Item -LiteralPath $ex -Recurse -Force -ErrorAction SilentlyContinue }
  Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
  $found = Get-ChildItem -LiteralPath $ex -Recurse -Filter 'bore.exe' -File | Select-Object -First 1
  if (-not $found) { throw '压缩包里没找到 bore.exe' }
  $dest = Join-Path $ToolsDir 'bore.exe'
  Copy-Item -LiteralPath $found.FullName -Destination $dest -Force
  Remove-Item -LiteralPath $ex -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  $ver = & $dest --version 2>&1
  Write-Output ('已安装：' + $dest + '   版本 ' + ($ver -join ' ').Trim())
  return $dest
}

function Show-TunnelList {
  Write-Output '可用隧道工具：'
  foreach ($p in (Get-TunnelProviders)) {
    $mark = '缺'
    if ($p.installed) { $mark = '有' }
    $line = '  [{0}] {1,-12} {2}' -f $mark, $p.id, $p.note
    Write-Output $line
    if ($p.installed) { Write-Output ('         ' + $p.path) }
  }
  Write-Output ''
  Write-Output '自动安装：bore 点「启动」就会自己下载配好（无需注册），装到：'
  Write-Output ('  ' + $ToolsDir)
  Write-Output ''
  Write-Output '其余需要手动登记账号：'
  Write-Output '  cpolar     https://www.cpolar.com/download'
  Write-Output '  ngrok      https://ngrok.com/download  （然后 ngrok config add-authtoken <token>）'
  Write-Output '  cloudflared https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/'
  Write-Output '  frpc       自备 frps 或公共 frps'
}

function Start-Tunnel {
  param([string]$Provider, [int]$LocalPort)

  $prov = Get-TunnelProviders | Where-Object { $_.id -eq $Provider } | Select-Object -First 1
  # 这里的失败都写进状态文件再返回，不要把异常抛到上层：
  # 抛出去的话界面只能看到一段 PowerShell 堆栈，状态卡片还停在「未启用」，像是没反应。
  if ($null -eq $prov) {
    $msg = '未知的隧道工具：' + $Provider
    Save-State $TunnelState @{ state = 'error'; pid = 0; provider = $Provider; localPort = $LocalPort; public = ''; error = $msg }
    Write-Output $msg
    return
  }

  # 没装就自己装：bore 一路下载、解压、验版本，用户不用离开界面
  if (-not $prov.installed) {
    if ($Provider -eq 'bore') {
      Write-Output '本机还没有 bore，开始自动安装…'
      try {
        $exePath = Install-Tunnel 'bore'
        $prov = Get-TunnelProviders | Where-Object { $_.id -eq 'bore' } | Select-Object -First 1
        if (-not $prov.installed) { throw '安装后仍然找不到 bore.exe' }
      } catch {
        $msg = '自动安装 bore 失败：' + $_.Exception.Message
        Save-State $TunnelState @{ state = 'error'; pid = 0; provider = $Provider; localPort = $LocalPort; public = ''; error = $msg }
        Write-Output $msg
        return
      }
    } else {
      $msg = $Provider + ' 未安装，而且它需要注册账号，不能自动装。换 bore，或按「检测已装工具」里的地址手动装。'
      Save-State $TunnelState @{ state = 'error'; pid = 0; provider = $Provider; localPort = $LocalPort; public = ''; error = $msg }
      Write-Output $msg
      return
    }
  }

  # 停掉旧的
  Stop-Tunnel | Out-Null
  if (Test-Path -LiteralPath $TunnelLog) { Remove-Item -LiteralPath $TunnelLog -Force -ErrorAction SilentlyContinue }

  $argLine = ''
  if ($Provider -eq 'cpolar') { $argLine = 'tcp ' + $LocalPort }
  elseif ($Provider -eq 'bore') { $argLine = 'local ' + $LocalPort + ' --to bore.pub' }
  elseif ($Provider -eq 'ngrok') { $argLine = 'tcp ' + $LocalPort }
  elseif ($Provider -eq 'cloudflared') { $argLine = 'tunnel --url tcp://localhost:' + $LocalPort }
  else { $argLine = '-c frpc.ini' }

  try {
    $tunPid = Start-Hidden -FilePath $prov.path -ArgumentString $argLine -OutLog $TunnelLog
  } catch {
    $msg = '启动 ' + $Provider + ' 失败：' + $_.Exception.Message
    Save-State $TunnelState @{ state = 'error'; pid = 0; provider = $Provider; localPort = $LocalPort; public = ''; error = $msg }
    Write-Output $msg
    return
  }

  Save-State $TunnelState @{ state = 'starting'; pid = $p.Id; provider = $Provider; localPort = $LocalPort; public = ''; error = '' }

  # 从输出里抓公网地址
  $public = ''
  $exited = $false
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $text = ''
    foreach ($f in @($TunnelLog, ($TunnelLog + '.err'))) {
      if (Test-Path -LiteralPath $f) { $text += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
    }
    if ($text) {
      $m = [regex]::Matches($text, '(?<![\w.-])([a-z0-9][a-z0-9.-]*\.[a-z]{2,})(:(\d{2,5}))')
      foreach ($x in $m) {
        $h = $x.Groups[1].Value
        if ($h -match '^(localhost|127\.|0\.0\.0\.0|schemas\.)') { continue }
        if ($h -match 'cpolar\.(top|cn|io)$' -or $h -match 'ngrok\.io$' -or $h -match 'bore\.pub$' -or $h -match 'trycloudflare\.com$') {
          $public = $h + $x.Groups[2].Value
          break
        }
      }
      if (-not $public) {
        $m2 = [regex]::Match($text, '(?m)^\s*Forwarding\s+(\S+)\s+->')
        if ($m2.Success) { $public = $m2.Groups[1].Value }
      }
    }
    if ($public) { break }
    if (-not (Get-Process -Id $tunPid -ErrorAction SilentlyContinue)) { $exited = $true; break }
  }

  $errText = ''
  foreach ($f in @($TunnelLog, ($TunnelLog + '.err'))) {
    if (Test-Path -LiteralPath $f) { $errText += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
  }

  Save-State $TunnelState @{
    state = $(if ($public) { 'connected' } elseif ($exited) { 'error' } else { 'starting' })
    pid = $tunPid; provider = $Provider; localPort = $LocalPort; public = $public
    error = $(if ($exited -and -not $public) { ($errText -split "`n" | Select-Object -First 6) -join ' | ' } else { '' })
  }

  Write-Output ('C 通道已启动：' + $Provider + ' 本地 ' + $LocalPort)
  if ($public) { Write-Output ('  公网地址：' + $public) }
  else { Write-Output '  还没抓到公网地址，看 p2p-tunnel.log（可能需要先登录/填 token）' }
  if ($errText -and $exited) { Write-Output ('  输出：' + (($errText -split "`n" | Select-Object -First 6) -join ' | ')) }
}

function Stop-Tunnel {
  $st = Load-State $TunnelState
  $procId = 0
  if ($st.ContainsKey('pid')) { [int]::TryParse([string]$st['pid'], [ref]$procId) | Out-Null }
  if ($procId -gt 0) {
    try { Stop-Tree -ProcessId $procId } catch { }
    try { Get-Process -Id $procId -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
  }
  Save-State $TunnelState @{ state = 'idle'; pid = 0 }
  Write-Output ('C 通道已停止（PID ' + $procId + '）')
}

# ==================== 诊断 ====================

function Invoke-Probe {
  Write-Output '=== 网络诊断 ==='

  $localIp = ''
  $gw = ''
  try {
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
    if ($cfg) {
      $localIp = $cfg.IPv4Address.IPAddress
      $gw = $cfg.IPv4DefaultGateway.NextHop
      Write-Output ('本地地址  ' + $localIp + '   网关 ' + $gw)
    }
  } catch { }

  # 同一 socket 依次问两个 STUN，比较映射 -> 判断 NAT 类型
  $sock = New-Object System.Net.Sockets.UdpClient(0)
  $sock.Client.ReceiveTimeout = 2000
  $m1 = $null; $m2 = $null
  try { $e1 = Resolve-Stun $StunServer; if ($e1) { $m1 = Get-Mapping $sock $e1 } } catch { }
  try { $e2 = Resolve-Stun $StunServer2; if ($e2) { $m2 = Get-Mapping $sock $e2 } } catch { }
  $sock.Dispose()

  if ($m1) {
    Write-Output ('STUN #1   ' + $m1.ip + ':' + $m1.port)
  } else {
    Write-Output 'STUN #1   无回应（该网络可能封了 UDP 3478）'
  }
  if ($m2) {
    Write-Output ('STUN #2   ' + $m2.ip + ':' + $m2.port)
  } else {
    Write-Output 'STUN #2   无回应'
  }

  $nat = 'unknown'
  if ($m1 -and $m2) {
    if ($m1.port -eq $m2.port -and $m1.ip -eq $m2.ip) {
      $nat = 'cone'
      Write-Output 'NAT 类型  Cone（同一映射，打洞成功率高）'
    } else {
      $nat = 'symmetric'
      Write-Output ('NAT 类型  Symmetric（每个目的一个端口，出口 IP ' + $m1.ip + ' / ' + $m2.ip + '）')
      Write-Output '          → 被动接收方需要端口预测，主动发起方不受影响'
    }
  }

  # 端口递增性：连续 6 个新 socket
  $seq = @()
  for ($i = 0; $i -lt 6; $i++) {
    $s = New-Object System.Net.Sockets.UdpClient(0)
    $s.Client.ReceiveTimeout = 1500
    try {
      $e = Resolve-Stun $StunServer
      $mm = Get-Mapping $s $e
      if ($mm) { $seq += $mm.port }
    } catch { }
    $s.Dispose()
  }
  if ($seq.Count -ge 2) {
    Write-Output ('端口序列  ' + ($seq -join ' -> '))
    $mono = $true
    for ($i = 1; $i -lt $seq.Count; $i++) { if ($seq[$i] -le $seq[$i - 1]) { $mono = $false } }
    if ($mono) {
      Write-Output '          单调递增 → 端口可预测，对端可盲扫命中'
    } else {
      Write-Output '          非单调 → 端口随机，盲扫成功率低'
    }
  }

  Write-Output ''
  Write-Output '=== 中继与隧道可达性 ==='
  $targets = @(
    @('Cloudflare API', 'api.cloudflare.com', 443),
    @('cpolar', 'dashboard.cpolar.com', 443),
    @('ngrok', 'ngrok.com', 443),
    @('bore', 'bore.pub', 7835),
    @('frp 公共', 'frp.freefrp.net', 7000)
  )
  foreach ($t in $targets) {
    $tc = New-Object System.Net.Sockets.TcpClient
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = $false
    try { $ok = $tc.ConnectAsync($t[1], $t[2]).Wait(2000) } catch { }
    $sw.Stop()
    if ($ok -and $tc.Connected) { Write-Output ('{0,-14} OPEN {1}ms' -f $t[0], $sw.ElapsedMilliseconds) }
    else { Write-Output ('{0,-14} blocked' -f $t[0]) }
    $tc.Dispose()
  }

  Write-Output ''
  Write-Output ('PROBE_NAT=' + $nat)
  if ($m1) { Write-Output ('PROBE_MAPPING=' + $m1.ip + ':' + $m1.port) }
}

# ==================== 状态汇总 ====================

# 状态文件是磁盘上的快照：进程被杀、机器重启、异常退出之后，快照还会说「已连通」。
# 所以读状态时先问一句进程还在不在；不在就把这条通道落回 idle，别让界面骗人。
function Test-ChannelAlive {
  param($State, [string]$StatePath)
  $st = Get-S $State 'state' 'idle'
  if ($st -eq 'idle' -or $st -eq 'error') { return $State }
  $procId = [int](Get-S $State 'pid' '0')
  if ($procId -le 0) { return $State }
  $alive = $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
  if ($alive) { return $State }
  $fixed = @{}
  foreach ($k in $State.Keys) { $fixed[$k] = $State[$k] }
  $fixed['state'] = 'idle'
  $fixed['pid'] = 0
  $fixed['error'] = '通道进程已退出（PID ' + $procId + ' 不在了），状态已复位'
  $fixed['peer'] = ''
  $fixed['rtt'] = 0
  $fixed['rx'] = 0
  $fixed['tx'] = 0
  $fixed['uptimeSec'] = 0
  # 映射和邀请码都绑在死掉的那个进程上，留着只会误导
  $fixed['mapping'] = ''
  $fixed['invite'] = ''
  $fixed['peers'] = 0
  $fixed['public'] = ''
  Save-State $StatePath $fixed
  return $fixed
}

function Show-Status {
  $h = Test-ChannelAlive (Load-State $HoleState) $HoleState
  $r = Test-ChannelAlive (Load-State $RelayState) $RelayState
  $t = Test-ChannelAlive (Load-State $TunnelState) $TunnelState

  Write-Output ('HOLE_STATE=' + (Get-S $h 'state' 'idle'))
  Write-Output ('HOLE_MAPPING=' + (Get-S $h 'mapping'))
  Write-Output ('HOLE_NAT=' + (Get-S $h 'natType'))
  Write-Output ('HOLE_INVITE=' + (Get-S $h 'invite'))
  Write-Output ('HOLE_PEER=' + (Get-S $h 'peer'))
  Write-Output ('HOLE_RTT=' + (Get-S $h 'rtt' '0'))
  Write-Output ('HOLE_RX=' + (Get-S $h 'rx' '0'))
  Write-Output ('HOLE_TX=' + (Get-S $h 'tx' '0'))
  Write-Output ('HOLE_PID=' + (Get-S $h 'pid' '0'))
  Write-Output ('HOLE_PORT=' + (Get-S $h 'localPort' '0'))
  Write-Output ('HOLE_LOCALUDP=' + (Get-S $h 'localUdp' '0'))
  Write-Output ('HOLE_PEERUDP=' + (Get-S $h 'peerUdp' '0'))
  Write-Output ('HOLE_UPTIME=' + (Get-S $h 'uptimeSec' '0'))
  Write-Output ('HOLE_ERROR=' + (Get-S $h 'error'))

  Write-Output ('RELAY_STATE=' + (Get-S $r 'state' 'idle'))
  Write-Output ('RELAY_WORKER=' + (Get-S $r 'worker'))
  Write-Output ('RELAY_ROOM=' + (Get-S $r 'room'))
  Write-Output ('RELAY_PEERS=' + (Get-S $r 'peers' '0'))
  Write-Output ('RELAY_RX=' + (Get-S $r 'rx' '0'))
  Write-Output ('RELAY_TX=' + (Get-S $r 'tx' '0'))
  Write-Output ('RELAY_PID=' + (Get-S $r 'pid' '0'))
  Write-Output ('RELAY_UPTIME=' + (Get-S $r 'uptimeSec' '0'))
  Write-Output ('RELAY_ERROR=' + (Get-S $r 'error'))

  Write-Output ('TUNNEL_STATE=' + (Get-S $t 'state' 'idle'))
  Write-Output ('TUNNEL_PROVIDER=' + (Get-S $t 'provider'))
  Write-Output ('TUNNEL_LOCALPORT=' + (Get-S $t 'localPort' '0'))
  Write-Output ('TUNNEL_PUBLIC=' + (Get-S $t 'public'))
  Write-Output ('TUNNEL_PID=' + (Get-S $t 'pid' '0'))
  Write-Output ('TUNNEL_ERROR=' + (Get-S $t 'error'))

  # 账号状态每次刷新都重算：用户可能在浏览器里刚点完 Allow
  $cf = Get-CfState
  Write-Output ('CF_LOGIN=' + $(if ($cf.login) { 'yes' } else { 'no' }))
  Write-Output ('CF_WRANGLER=' + $(if ($cf.wrangler) { 'yes' } else { 'no' }))
  # 界面上的 Worker 一栏要能显示一键部署的结果
  Write-Output ('CF_WORKER=' + (Get-S $r 'worker'))
}

function Show-WorkerCode {
  $src = Join-Path $ScriptDir 'p2p-worker.js'
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Output '未找到 p2p-worker.js'
    return
  }
  Write-Output ('Worker 源码：' + $src)
  Write-Output '部署四步：'
  Write-Output '  1) npm i -g wrangler && wrangler login'
  Write-Output '  2) 把 p2p-worker.js + wrangler.toml 放进同一个空目录（下面就是这两个文件的内容）'
  Write-Output '  3) wrangler deploy'
  Write-Output '  4) 拿到 https://p2p-relay.<你的子域>.workers.dev，填进 B 通道的 Worker 一栏'
  Write-Output ''
  Write-Output '----- p2p-worker.js -----'
  # 5.1 里 Get-Content 默认按 ANSI(GBK) 解码，UTF-8 文件会变乱码，必须显式指定
  Get-Content -LiteralPath $src -Raw -Encoding UTF8
  $toml = Join-Path $ScriptDir 'wrangler.toml'
  if (Test-Path -LiteralPath $toml) {
    Write-Output ''
    Write-Output '----- wrangler.toml -----'
    Get-Content -LiteralPath $toml -Raw -Encoding UTF8
  }
}

# ==================== 分发 ====================

switch ($Action.ToLower()) {
  'probe'        { Invoke-Probe }
  'status'       { Show-Status }
  'hole-start'   { Start-HoleRun }
  'hole-run'     { Invoke-HoleRun -Port $Port -Peer $Peer -Spray $Spray -StunServer $StunServer -StunServer2 $StunServer2 -LocalUdp $LocalUdp -PeerUdp $PeerUdp }
  'hole-stop'    { Stop-HoleRun }
  'relay-start'  { Start-RelayRun }
  'relay-run'    { Invoke-RelayRun -Worker $Worker -Room $Room }
  'relay-stop'   { Stop-RelayRun }
  'tunnel-list'  { Show-TunnelList }
  'tunnel-install' { Install-Tunnel -Provider $(if ($Provider) { $Provider } else { 'bore' }) }
  'tunnel-start' { Start-Tunnel -Provider $Provider -LocalPort $LocalPort }
  'tunnel-stop'  { Stop-Tunnel }
  'cf-status'    { Show-CfStatus }
  'cf-login'     { Invoke-CfLogin }
  'cf-deploy'    { Invoke-CfDeploy }
  'worker-code'  { Show-WorkerCode }
  default {
    Write-Output ('未知动作：' + $Action)
    Write-Output '可用：probe / status / hole-start / hole-stop / relay-start / relay-stop / tunnel-list / tunnel-install / tunnel-start / tunnel-stop / cf-status / cf-login / cf-deploy / worker-code'
    exit 2
  }
}

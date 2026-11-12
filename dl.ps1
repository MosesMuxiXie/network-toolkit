param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$OutFile = '',
    [int]$Threads = 16,
    [int]$LimitMB = 0,
    [int]$Port = 1080,
    [ValidateSet('split', 'primary', 'secondary')][string]$Mode = 'split',
    [string]$Primary = '',
    [string]$Secondary = ''
)

$ErrorActionPreference = 'Stop'
$splitScript = Join-Path $PSScriptRoot 'split-proxy.ps1'
$fetchScript = Join-Path $PSScriptRoot 'multi-fetch.ps1'
$proxy = "socks5h://127.0.0.1:$Port"

function Test-ProxyAlive {
    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

if (-not (Test-ProxyAlive)) {
    Write-Host "启动分流器（$Mode）于 127.0.0.1:$Port ..."
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $splitScript, '-Port', "$Port", '-Mode', $Mode)
    if ($Primary) { $childArgs += @('-Primary', $Primary) }
    if ($Secondary) { $childArgs += @('-Secondary', $Secondary) }
    Start-Process powershell.exe -ArgumentList $childArgs -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-ProxyAlive) { break }
    }
}

if (-not (Test-ProxyAlive)) { $tail = (Get-Content (Join-Path $env:TEMP 'split-proxy.log') -Tail 3 -ErrorAction SilentlyContinue) -join "`n"; throw ("分流器没起来：" + $tail) }

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $u = [Uri]$Url
    $name = [IO.Path]::GetFileName($u.AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'download.bin' }
    $OutFile = Join-Path (Get-Location).Path $name
}

Write-Host ("下载: {0}" -f $Url)
Write-Host ("目标: {0}" -f $OutFile)
Write-Host ("链路: {0} | 线程: {1} | 代理: {2}" -f $Mode, $Threads, $proxy)

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fetchScript `
    -Url $Url -OutFile $OutFile -Threads $Threads -Proxy $proxy -LimitMB $LimitMB

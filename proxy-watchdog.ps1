# proxy-watchdog.ps1 — keep compact-proxy alive
# Checks if port 18080 is listening; if not, starts the proxy.

$ErrorActionPreference = "SilentlyContinue"

$port = 18080
$proxyScript = Join-Path $PSScriptRoot "compact-proxy.mjs"
$logFile = Join-Path (Split-Path $PSScriptRoot) "local-compaction\watchdog.log"
$lockFile = Join-Path (Split-Path $PSScriptRoot) "local-compaction\watchdog.lock"

function Write-Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts  $msg" | Add-Content -LiteralPath $logFile -Encoding UTF8
    # Keep log under 500 lines
    $lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 500) {
        $lines[-500..-1] | Set-Content -LiteralPath $logFile -Encoding UTF8
    }
}

# Prevent overlapping runs (lock expires after 60s)
if (Test-Path $lockFile) {
    $lockAge = (Get-Date) - (Get-Item $lockFile).LastWriteTime
    if ($lockAge.TotalSeconds -lt 60) {
        exit 0
    }
}
(Get-Date).ToString("o") | Set-Content -LiteralPath $lockFile -Encoding UTF8

try {
    # Check if port is already listening
    $listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue

    if ($listening) {
        # Port is alive, nothing to do
        exit 0
    }

    # Port is down — start the proxy
    Write-Log "Port $port not listening. Starting compact-proxy.mjs ..."

    $nodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodePath) {
        Write-Log "ERROR: node not found in PATH"
        exit 1
    }

    # Start detached — Use Start-Process so it lives independently
    Start-Process -FilePath $nodePath `
        -ArgumentList "`"$proxyScript`"" `
        -WindowStyle Hidden `
        -WorkingDirectory (Split-Path $proxyScript)

    # Give it a moment to bind
    Start-Sleep -Seconds 3

    $check = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($check) {
        Write-Log "OK: proxy restarted, listening on port $port (PID $($check[0].OwningProcess))"
    } else {
        Write-Log "WARN: proxy started but port $port still not listening after 3s"
    }
} finally {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

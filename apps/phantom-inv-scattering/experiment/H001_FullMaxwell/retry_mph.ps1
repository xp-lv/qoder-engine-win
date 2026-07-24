for ($i = 1; $i -le 3; $i++) {
    Write-Host "Retry $i of 3..."
    Start-Sleep -Seconds 5
    $r = Test-NetConnection localhost -Port 2036 -WarningAction SilentlyContinue
    if ($r.TcpTestSucceeded) {
        Write-Host "Retry $i SUCCESS - mphserver reachable"
        exit 0
    } else {
        Write-Host "Retry $i FAILED - mphserver not reachable"
    }
}
Write-Host "All 3 retries exhausted"
exit 1

<#
.SYNOPSIS
    Frontend deploy sequence: assets first (content-hashed by Vite, safe to
    land before anything references them), index.html last, then a health
    check, THEN delete old-release assets - never before the new index.html
    is confirmed live, so a client with the old page still open never 404s
    mid-session. No app_offline.htm at all - static files, no process lock.

    Requires ftps.ps1 + health-check.ps1 dot-sourced first.
#>

function Deploy-Frontend {
    param($Ctx, [string]$OutputRoot, [string[]]$UploadPaths, [string[]]$DeletePaths, [string]$FrontendUrl,
        [int]$HealthCheckTimeoutSeconds = 60, [int]$HealthCheckRetrySeconds = 2)

    if ($UploadPaths.Count -eq 0 -and $DeletePaths.Count -eq 0) {
        Write-DeployLog "Frontend: nothing to do." "OK"
        return
    }

    $indexFiles = @($UploadPaths | Where-Object { (Split-Path $_ -Leaf) -eq "index.html" })
    $jsCssFiles = @($UploadPaths | Where-Object { $_ -notin $indexFiles -and ($_ -like "*.js" -or $_ -like "*.css") })
    $otherFiles = @($UploadPaths | Where-Object { $_ -notin $indexFiles -and $_ -notin $jsCssFiles })

    if ($jsCssFiles.Count -gt 0) {
        Write-DeployLog "Frontend: uploading $($jsCssFiles.Count) JS/CSS asset(s)..."
        $files = $jsCssFiles | ForEach-Object { @{ Bytes = [System.IO.File]::ReadAllBytes((Join-Path $OutputRoot $_)); RelativePath = $_ } }
        Publish-RemoteFilesParallel -Ctx $Ctx -Files $files
    }
    if ($otherFiles.Count -gt 0) {
        Write-DeployLog "Frontend: uploading $($otherFiles.Count) other asset(s)..."
        $files = $otherFiles | ForEach-Object { @{ Bytes = [System.IO.File]::ReadAllBytes((Join-Path $OutputRoot $_)); RelativePath = $_ } }
        Publish-RemoteFilesParallel -Ctx $Ctx -Files $files
    }

    $assetMarker = $null
    $firstJs = $jsCssFiles | Where-Object { $_ -like "*.js" } | Select-Object -First 1
    if ($firstJs) { $assetMarker = Split-Path $firstJs -Leaf }

    foreach ($indexPath in $indexFiles) {
        Write-DeployLog "Frontend: uploading entry point $indexPath (last, references the assets above)..."
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $OutputRoot $indexPath))
        Publish-RemoteFile -Ctx $Ctx -Bytes $bytes -RelativePath $indexPath
    }

    if ($FrontendUrl -and $indexFiles.Count -gt 0) {
        $healthy = Test-FrontendHealth -Url $FrontendUrl -ExpectedAssetMarker $assetMarker -TimeoutSeconds $HealthCheckTimeoutSeconds -RetryIntervalSeconds $HealthCheckRetrySeconds
        if (-not $healthy) { throw "HEALTH_CHECK_FAILED: frontend did not come up healthy after deploying $($indexFiles -join ', ')." }
    }

    # Delete old-release assets only now that the new entry point is
    # confirmed live - a browser tab still open on the old page might
    # otherwise request an asset we just removed.
    foreach ($path in $DeletePaths) {
        Remove-RemoteFile -Ctx $Ctx -Uri (New-FtpUri -Ctx $Ctx -RelativePath $path) -IgnoreMissing | Out-Null
        Write-DeployLog "Frontend: deleted old asset $path"
    }
}

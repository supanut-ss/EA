<#
.SYNOPSIS
    Backend deploy sequence: offline -> wait for runtime files to actually
    unlock -> backup+journal every file this release touches -> safe
    replace -> bring the site back -> health check. Requires ftps.ps1,
    lock.ps1 and health-check.ps1 dot-sourced first.

.DESCRIPTION
    app_offline.htm only goes up when the plan touches a runtime-sensitive
    file (*.dll/*.exe/*.deps.json/*.runtimeconfig.json) - non-runtime
    backend content (e.g. web.config, appsettings.json) can be replaced
    without taking the site offline, since the running process doesn't hold
    a lock on those the way it does its own assemblies.

    Every file this release replaces OR deletes gets backed up first (renamed
    to "<name>.bak.<releaseId>", never destroyed) and recorded in the
    journal - that's what rollback.ps1 walks backward if the health check
    at the end fails.
#>

function New-DeployJournal {
    param([string]$ReleaseId)
    return [pscustomobject]@{
        Release            = $ReleaseId
        Operations         = New-Object System.Collections.Generic.List[object]
        MaintenanceEnabled = $false
    }
}

function Publish-Journal {
    param($Ctx, $Journal, [string]$PreviousManifestJson)
    $obj = [ordered]@{
        release  = $Journal.Release
        savedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        operations = $Journal.Operations
    }
    $json = ($obj | ConvertTo-Json -Depth 10)
    Publish-RemoteFile -Ctx $Ctx -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json)) -RelativePath ".deploy/journal/$($Journal.Release).json"

    if ($PreviousManifestJson) {
        Publish-RemoteFile -Ctx $Ctx -Bytes ([System.Text.Encoding]::UTF8.GetBytes($PreviousManifestJson)) `
            -RelativePath ".deploy/journal/$($Journal.Release)-previous-manifest.json"
    }
}

# app_offline.htm lives at the site's physical root (where web.config is) -
# the ASP.NET Core Module intercepts requests before the app even starts
# when it sees this file there, regardless of the app's own static-files
# root (wwwroot).
function Set-MaintenanceMode {
    param($Ctx, [bool]$Enabled, [string]$TemplatePath)
    if ($Enabled) {
        $bytes = [System.IO.File]::ReadAllBytes($TemplatePath)
        Publish-RemoteFileDirect -Ctx $Ctx -Bytes $bytes -RelativePath "app_offline.htm"
        Write-DeployLog "app_offline.htm is live." "WARN"
    }
    else {
        Remove-RemoteFile -Ctx $Ctx -Uri (New-FtpUri -Ctx $Ctx -RelativePath "app_offline.htm") -IgnoreMissing | Out-Null
        Write-DeployLog "app_offline.htm removed - site is live." "OK"
    }
}

function Deploy-BackendSafely {
    param(
        $Ctx,
        [string]$OutputRoot,
        [string[]]$BackendUpload,
        [string[]]$BackendDelete,
        [string[]]$RuntimeSensitiveUpload,
        [string[]]$RuntimeSensitivePatterns,
        [string]$ReleaseId,
        [string]$TemplatePath,
        [string]$HealthUrl,
        [int]$DllUnlockTimeoutSeconds,
        $LockState,
        $Journal
    )

    $hasRuntimeChanges = $RuntimeSensitiveUpload.Count -gt 0

    if ($hasRuntimeChanges) {
        Set-MaintenanceMode -Ctx $Ctx -Enabled $true -TemplatePath $TemplatePath
        $Journal.MaintenanceEnabled = $true

        Write-DeployLog "Waiting for $($RuntimeSensitiveUpload.Count) runtime file(s) to unlock (timeout ${DllUnlockTimeoutSeconds}s)..."
        $unlocked = Wait-RemoteFilesUnlocked -Ctx $Ctx -RelativePaths $RuntimeSensitiveUpload -TimeoutSeconds $DllUnlockTimeoutSeconds
        if (-not $unlocked) {
            throw "BACKEND_DLL_STILL_LOCKED: one or more runtime files did not unlock within ${DllUnlockTimeoutSeconds}s. Deployment aborted; app_offline.htm is left in place on purpose."
        }
        Write-DeployLog "All runtime files confirmed unlocked." "OK"
    }

    foreach ($path in $BackendUpload) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $OutputRoot $path))
        $isRuntimeFile = Test-RuntimeSensitivePath -RelativePath $path -Patterns $RuntimeSensitivePatterns
        Publish-RemoteFile -Ctx $Ctx -Bytes $bytes -RelativePath $path `
            -BackupBeforeReplace:$isRuntimeFile -BackupSuffix $ReleaseId -Journal $Journal
        if ($LockState) { Update-DeployLockHeartbeat -Ctx $Ctx -LockState $LockState }
    }

    # Delete candidates get backed up (renamed to .bak), never hard-deleted -
    # that backup IS the delete as far as the running app is concerned (the
    # file is gone from its real name), while staying recoverable.
    foreach ($path in $BackendDelete) {
        Backup-RemoteFileIfExists -Ctx $Ctx -RelativePath $path -Suffix $ReleaseId -Journal $Journal | Out-Null
    }

    if ($hasRuntimeChanges) {
        Set-MaintenanceMode -Ctx $Ctx -Enabled $false -TemplatePath $TemplatePath
        $Journal.MaintenanceEnabled = $false

        Write-DeployLog "Backend health check (expecting release '$ReleaseId')..."
        $healthy = Test-BackendHealth -Url $HealthUrl -ExpectedRelease $ReleaseId -TimeoutSeconds 60 -RetryIntervalSeconds 2
        if (-not $healthy) {
            throw "HEALTH_CHECK_FAILED: backend did not report healthy at release '$ReleaseId' after coming back online."
        }
    }
}

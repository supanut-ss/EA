<#
.SYNOPSIS
    Walks a deploy journal backward to undo a failed release, restores the
    previous manifest, and re-verifies health. Used automatically by
    deploy.ps1 on failure, and runnable standalone for manual recovery.

.DESCRIPTION
    Requires ftps.ps1, backend-deploy.ps1 (for Set-MaintenanceMode) and
    health-check.ps1 dot-sourced first when used as a library (Invoke-Rollback).

    STANDALONE USAGE (separate PowerShell process, after the fact):
        .\rollback.ps1 -RollbackEnvironment production -RollbackRelease <releaseId>
    This downloads .deploy/journal/<releaseId>.json and the sibling
    "-previous-manifest.json" that deploy.ps1 publishes alongside it, then
    runs the same Invoke-Rollback logic. Scope note: there is no persisted
    "release history" list, so standalone rollback needs the exact release
    id (visible in .deploy/deploy-info.json or the deploy log of the run
    you're undoing) - "-Release previous" from the design doc's example
    would need a release-history index this project doesn't have yet.

    Deliberately named -RollbackEnvironment/-RollbackRelease, not the more
    obvious -Environment/-Release: a top-level param() block's names get
    rebound in the CALLER's scope when dot-sourced with no arguments (that's
    how deploy.ps1 pulls in Invoke-Rollback) - reusing -Environment here
    silently clobbered deploy.ps1's own $Environment variable back to $null
    every run. Found the hard way; keeping distinct names is the fix.
#>
param(
    [string]$RollbackEnvironment,
    [string]$RollbackRelease
)

# Walks $Journal.Operations backward, restores $PreviousManifestJson, then
# health-checks $PreviousRelease. Throws ROLLBACK_FAILED (with app_offline.htm
# deliberately left up) if any step can't be completed - never brings a
# half-restored site back online.
function Invoke-Rollback {
    param($Ctx, $Journal, [string]$PreviousManifestJson, [string]$PreviousRelease, [string]$HealthUrl, [string]$TemplatePath)

    Write-DeployLog "ROLLING BACK release '$($Journal.Release)' to '$PreviousRelease'..." "ERROR"
    Set-MaintenanceMode -Ctx $Ctx -Enabled $true -TemplatePath $TemplatePath

    $ops = $Journal.Operations
    for ($i = $ops.Count - 1; $i -ge 0; $i--) {
        $op = $ops[$i]
        try {
            switch ($op.type) {
                "create" {
                    Remove-RemoteFile -Ctx $Ctx -Uri (New-FtpUri -Ctx $Ctx -RelativePath $op.path) -IgnoreMissing | Out-Null
                    Write-DeployLog "Rollback: removed newly-created $($op.path)"
                }
                "backup" {
                    if (Test-RemoteFileExists -Ctx $Ctx -RelativePath $op.path) {
                        Remove-RemoteFile -Ctx $Ctx -Uri (New-FtpUri -Ctx $Ctx -RelativePath $op.path) -IgnoreMissing | Out-Null
                    }
                    $targetName = Split-Path $op.path -Leaf
                    Rename-RemoteFile -Ctx $Ctx -FromUri (New-FtpUri -Ctx $Ctx -RelativePath $op.backup) -NewName $targetName
                    Write-DeployLog "Rollback: restored $($op.path) from $($op.backup)"
                }
            }
        }
        catch {
            throw "ROLLBACK_FAILED: could not undo '$($op.type)' on '$($op.path)': $($_.Exception.Message). app_offline.htm is being KEPT UP on purpose - $($i) of $($ops.Count) operations still un-rolled-back. Manual recovery required, do not remove the offline page until this is resolved."
        }
    }

    if ($PreviousManifestJson) {
        Publish-RemoteFile -Ctx $Ctx -Bytes ([System.Text.Encoding]::UTF8.GetBytes($PreviousManifestJson)) -RelativePath ".deploy/manifest.json"
        Write-DeployLog "Rollback: previous manifest restored."
    }
    else {
        Write-DeployLog "No previous manifest available to restore (this may have been the first deploy) - manifest left as-is." "WARN"
    }

    Set-MaintenanceMode -Ctx $Ctx -Enabled $false -TemplatePath $TemplatePath

    $healthy = Test-BackendHealth -Url $HealthUrl -ExpectedRelease $PreviousRelease -TimeoutSeconds 60 -RetryIntervalSeconds 2
    if (-not $healthy) {
        throw "ROLLBACK_FAILED: files were restored but the previous release did NOT come back healthy. app_offline.htm is being KEPT UP on purpose - this needs manual investigation."
    }
    Write-DeployLog "ROLLBACK SUCCESS - site restored to release '$PreviousRelease'." "OK"
}

# ---------------------------------------------------------------------------
# Standalone entry point - only runs when both -Environment and -Release
# were actually supplied (i.e. this file was invoked directly with them),
# never when deploy.ps1 dot-sources this file just to get Invoke-Rollback.
# ---------------------------------------------------------------------------
if ($RollbackEnvironment -and $RollbackRelease) {
    $ErrorActionPreference = "Stop"
    . "$PSScriptRoot\ftps.ps1"
    . "$PSScriptRoot\lock.ps1"
    . "$PSScriptRoot\create-manifest.ps1"
    . "$PSScriptRoot\backend-deploy.ps1"
    . "$PSScriptRoot\health-check.ps1"

    $configPath = "$PSScriptRoot\config\$RollbackEnvironment.json"
    if (-not (Test-Path $configPath)) { throw "CONFIG_ERROR: no config found at $configPath" }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    $server = $env:DEPLOY_FTP_SERVER
    $username = $env:DEPLOY_FTP_USERNAME
    $password = $env:DEPLOY_FTP_PASSWORD
    if (-not $server -or -not $username -or -not $password) {
        throw "CONFIG_ERROR: DEPLOY_FTP_SERVER/USERNAME/PASSWORD must be set for standalone rollback."
    }

    $ctx = New-FtpsContext -Server $server -Username $username -Password $password `
        -Protocol $config.protocol -RemotePath $config.remoteRoot `
        -CertificateThumbprint $env:DEPLOY_FTPS_THUMBPRINT
    Test-FtpsConnection -Ctx $ctx

    $journalBytes = Get-RemoteFileBytes -Ctx $ctx -Uri (New-FtpUri -Ctx $ctx -RelativePath ".deploy/journal/$RollbackRelease.json")
    if (-not $journalBytes) { throw "No journal found at .deploy/journal/$RollbackRelease.json - cannot roll back automatically. Check backups by hand (*.bak.$RollbackRelease)." }
    $journalObj = ([System.Text.Encoding]::UTF8.GetString($journalBytes) | ConvertFrom-Json)
    $journal = [pscustomobject]@{ Release = $journalObj.release; Operations = $journalObj.operations }

    $prevManifestBytes = Get-RemoteFileBytes -Ctx $ctx -Uri (New-FtpUri -Ctx $ctx -RelativePath ".deploy/journal/$RollbackRelease-previous-manifest.json")
    $prevManifestJson = if ($prevManifestBytes) { [System.Text.Encoding]::UTF8.GetString($prevManifestBytes) } else { $null }
    $previousRelease = if ($prevManifestJson) { ($prevManifestJson | ConvertFrom-Json).release } else { "unknown" }

    $templatePath = "$PSScriptRoot\templates\app_offline.htm"
    try {
        Invoke-Rollback -Ctx $ctx -Journal $journal -PreviousManifestJson $prevManifestJson -PreviousRelease $previousRelease -HealthUrl $config.healthUrl -TemplatePath $templatePath
        exit 0
    }
    catch {
        Write-DeployLog "$($_.Exception.Message)" "ERROR"
        exit 60
    }
    finally {
        Clear-FtpsContext -Ctx $ctx
    }
}

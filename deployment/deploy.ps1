<#
.SYNOPSIS
    Deploy EA Console (Frontend + Backend) to shared hosting over FTPS.
    New system per frontend-backend-ftps-deployment-design.md: SHA256
    remote manifest, remote lock, preflight test, temp-upload+rename,
    app_offline.htm only when a runtime file actually changed, real DLL-
    unlock detection, backup+journal before every replace/delete, health
    check, and automatic rollback on failure.

.DESCRIPTION
    Secrets come ONLY from environment variables (never this file or the
    config/*.json files, which are safe to commit):
        DEPLOY_FTP_SERVER, DEPLOY_FTP_USERNAME, DEPLOY_FTP_PASSWORD
        DEPLOY_FTP_PROTOCOL      ("FTPS" default, or "FTP")
        DEPLOY_FTPS_THUMBPRINT   pinned cert thumbprint (first run without
                                  it set prints the observed thumbprint)
        DEPLOY_DB_CONNECTION_STRING, DEPLOY_INGEST_API_KEY
        DEPLOY_CORS_ORIGIN       optional, defaults to https://<remoteRoot>

.PARAMETER Target
    frontend | backend | all (default). Controls what gets BUILT and
    ACTUALLY UPLOADED - the plan/diff is always computed for the whole
    release tree so the printed summary stays honest about what's pending
    in the area you didn't target this run.

.EXAMPLE
    .\deployment\deploy.ps1 -Environment production -Target all -DryRun
.EXAMPLE
    .\deployment\deploy.ps1 -Environment production -Target frontend
.EXAMPLE
    .\deployment\deploy.ps1 -Environment production -ForceClearStaleLock
#>
[CmdletBinding()]
param(
    [string]$Environment = "production",
    [ValidateSet("frontend", "backend", "all")]
    [string]$Target = "all",
    [switch]$DryRun,
    [switch]$ForceClearStaleLock,
    [switch]$ApproveLargeDelete
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
$releaseOutputRoot = Join-Path $repoRoot ".deploy\output\release"

. "$PSScriptRoot\ftps.ps1"
. "$PSScriptRoot\lock.ps1"
. "$PSScriptRoot\create-manifest.ps1"
. "$PSScriptRoot\compare-manifest.ps1"
. "$PSScriptRoot\build.ps1"
. "$PSScriptRoot\health-check.ps1"
. "$PSScriptRoot\frontend-deploy.ps1"
. "$PSScriptRoot\backend-deploy.ps1"
. "$PSScriptRoot\rollback.ps1"

# ---------------------------------------------------------------------------
# Exit codes per the design doc's table.
# ---------------------------------------------------------------------------
function Exit-WithError {
    param([string]$Message)
    Write-DeployLog $Message "ERROR"
    $code = switch -Regex ($Message) {
        "^CONFIG_ERROR"              { 10 }
        "^PREFLIGHT_"                { 20 }
        "^DEPLOY_LOCKED"             { 30 }
        "^BACKEND_DLL_STILL_LOCKED"  { 41 }
        "^HEALTH_CHECK_FAILED"       { 50 }
        "^ROLLBACK_FAILED"           { 60 }
        default                      { 40 }
    }
    exit $code
}

try {
    # -----------------------------------------------------------------
    # 1. Config + secrets
    # -----------------------------------------------------------------
    $configPath = "$PSScriptRoot\config\$Environment.json"
    if (-not (Test-Path $configPath)) { throw "CONFIG_ERROR: no config found at $configPath" }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    $server   = $env:DEPLOY_FTP_SERVER
    $username = $env:DEPLOY_FTP_USERNAME
    $password = $env:DEPLOY_FTP_PASSWORD
    $protocol = if ($env:DEPLOY_FTP_PROTOCOL) { $env:DEPLOY_FTP_PROTOCOL } else { $config.protocol }
    $thumbprint = $env:DEPLOY_FTPS_THUMBPRINT
    $dbConnStr = $env:DEPLOY_DB_CONNECTION_STRING
    $ingestApiKey = $env:DEPLOY_INGEST_API_KEY
    $corsOrigin = if ($env:DEPLOY_CORS_ORIGIN) { $env:DEPLOY_CORS_ORIGIN } else { "https://$($config.remoteRoot)" }

    if (-not $server -or -not $username -or -not $password) {
        throw "CONFIG_ERROR: DEPLOY_FTP_SERVER, DEPLOY_FTP_USERNAME, DEPLOY_FTP_PASSWORD must be set as environment variables."
    }
    if (-not $thumbprint) {
        Write-DeployLog "DEPLOY_FTPS_THUMBPRINT not set - app_offline.htm toggling and cert pinning will report the observed thumbprint on first connect; pin it afterward." "WARN"
    }
    if (-not $dbConnStr) { Write-DeployLog "DEPLOY_DB_CONNECTION_STRING not set - web.config's ConnectionStrings__EaConsole will be left unchanged." "WARN" }
    if (-not $ingestApiKey) { Write-DeployLog "DEPLOY_INGEST_API_KEY not set - web.config's Ingest__ApiKey will be left unchanged." "WARN" }

    $machine = $env:COMPUTERNAME
    $operator = $env:USERNAME
    $releaseId = Get-ReleaseId -RepoRoot $repoRoot
    $gitCommit = Get-GitCommit -RepoRoot $repoRoot
    Write-DeployLog "Release id: $releaseId (commit $gitCommit, target=$Target, environment=$Environment)" "OK"

    # -----------------------------------------------------------------
    # 2. Build - always publishes the full combined tree (frontend dist
    #    lands in the backend's own wwwroot before `dotnet publish`,
    #    that's the only thing that produces .deploy/output/release), but
    #    only refreshes the frontend source dir when it's in scope so a
    #    -Target backend run doesn't need Node installed.
    # -----------------------------------------------------------------
    if ($Target -in @("frontend", "all")) {
        Invoke-BuildFrontend -RepoRoot $repoRoot
    }
    Invoke-BuildBackend -RepoRoot $repoRoot -OutputRoot $releaseOutputRoot -ReleaseId $releaseId `
        -DbConnStr $dbConnStr -IngestApiKey $ingestApiKey -CorsOrigin $corsOrigin

    # -----------------------------------------------------------------
    # 3. Manifest + plan (always computed for the WHOLE tree, so the
    #    printed plan stays honest about the area you didn't target)
    # -----------------------------------------------------------------
    $localManifest = New-Sha256Manifest -Root $releaseOutputRoot -ProtectedPaths $config.protectedPaths

    $ctx = New-FtpsContext -Server $server -Username $username -Password $password `
        -Protocol $protocol -RemotePath $config.remoteRoot -CertificateThumbprint $thumbprint `
        -MaxParallelUploads $config.maxParallelUploads -OperationTimeoutSeconds $config.operationTimeoutSeconds
    Test-FtpsConnection -Ctx $ctx

    $remoteManifestBytes = Get-RemoteFileBytes -Ctx $ctx -Uri (New-FtpUri -Ctx $ctx -RelativePath $script:ManifestRelativePath)
    $previousManifestJson = if ($remoteManifestBytes) { [System.Text.Encoding]::UTF8.GetString($remoteManifestBytes) } else { $null }
    $remoteManifest = if ($previousManifestJson) { try { $previousManifestJson | ConvertFrom-Json } catch { $null } } else { $null }
    $remoteFiles = @{}
    if ($remoteManifest -and $remoteManifest.files) {
        $remoteManifest.files.PSObject.Properties | ForEach-Object { $remoteFiles[$_.Name] = $_.Value }
    }

    $plan = Compare-DeployManifest -LocalManifest $localManifest -RemoteManifest $remoteManifest `
        -ProtectedPaths $config.protectedPaths -RuntimeSensitivePatterns $config.runtimeSensitivePatterns `
        -DeleteSafetyLimitCount $config.deleteSafetyLimitCount -DeleteSafetyLimitPct $config.deleteSafetyLimitPct `
        -ApproveLargeDelete:$ApproveLargeDelete
    $areas = Split-DeployPlanByArea -Plan $plan -WwwrootRelativePath $config.wwwrootRelativePath

    Show-DeploymentPlan -Plan $plan -Areas $areas -Environment $Environment -ReleaseId $releaseId -GitCommit $gitCommit -Machine $machine
    Write-DeployLog "Target scope this run: $Target (only this area's Upload/Delete above will actually be applied)" "WARN"

    if ($DryRun) {
        Write-DeployLog "DRY RUN complete. No remote changes were made." "OK"
        Clear-FtpsContext -Ctx $ctx
        exit 0
    }
    if (-not $plan.DeleteSafetyOk) {
        throw "PREFLIGHT_DELETE_SAFETY: plan would delete $($plan.Delete.Count) files ($($plan.DeletePct)% of managed files), over the configured limit. Re-run with -ApproveLargeDelete after reviewing the list above."
    }

    $deployFrontend = $Target -in @("frontend", "all")
    $deployBackend  = $Target -in @("backend", "all")
    $frontendHasWork = $deployFrontend -and ($areas.FrontendUpload.Count -gt 0 -or $areas.FrontendDelete.Count -gt 0)
    $backendHasWork  = $deployBackend -and ($areas.BackendUpload.Count -gt 0 -or $areas.BackendDelete.Count -gt 0)

    if (-not $frontendHasWork -and -not $backendHasWork) {
        Write-DeployLog "Nothing to do for target '$Target' - remote already matches local build." "OK"
        Clear-FtpsContext -Ctx $ctx
        exit 0
    }

    # -----------------------------------------------------------------
    # 4. Preflight permission test (upload/rename/delete a scratch file)
    # -----------------------------------------------------------------
    $probeId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $probeRelative = ".deploy/preflight/probe-$probeId.tmp"
    try {
        Publish-RemoteFile -Ctx $ctx -Bytes ([System.Text.Encoding]::UTF8.GetBytes("preflight")) -RelativePath $probeRelative
        Rename-RemoteFile -Ctx $ctx -FromUri (New-FtpUri -Ctx $ctx -RelativePath $probeRelative) -NewName "probe-$probeId.renamed"
        Remove-RemoteFile -Ctx $ctx -Uri (New-FtpUri -Ctx $ctx -RelativePath ".deploy/preflight/probe-$probeId.renamed") -IgnoreMissing | Out-Null
    }
    catch {
        throw "PREFLIGHT_UPLOAD_DENIED: could not upload/rename/delete a test file under .deploy/preflight/ - $($_.Exception.Message)"
    }
    Write-DeployLog "Preflight permission test passed." "OK"

    # -----------------------------------------------------------------
    # 5. Lock
    # -----------------------------------------------------------------
    $lockState = Acquire-DeployLock -Ctx $ctx -ReleaseId $releaseId -Machine $machine -Operator $operator `
        -StaleMinutes $config.lockStaleMinutes -ForceClearStaleLock:$ForceClearStaleLock

    $journal = New-DeployJournal -ReleaseId $releaseId
    $rolledBack = $false

    try {
        # ---------------------------------------------------------
        # 6. Deploy
        # ---------------------------------------------------------
        if ($frontendHasWork) {
            Deploy-Frontend -Ctx $ctx -OutputRoot $releaseOutputRoot `
                -UploadPaths $areas.FrontendUpload -DeletePaths $areas.FrontendDelete -FrontendUrl $config.frontendUrl `
                -HealthCheckTimeoutSeconds $config.healthCheckTimeoutSeconds -HealthCheckRetrySeconds $config.healthCheckRetrySeconds
            Update-DeployLockHeartbeat -Ctx $ctx -LockState $lockState
        }
        if ($backendHasWork) {
            Deploy-BackendSafely -Ctx $ctx -OutputRoot $releaseOutputRoot `
                -BackendUpload $areas.BackendUpload -BackendDelete $areas.BackendDelete `
                -RuntimeSensitiveUpload $plan.RuntimeSensitiveUpload -RuntimeSensitivePatterns $config.runtimeSensitivePatterns `
                -ReleaseId $releaseId -TemplatePath "$PSScriptRoot\templates\app_offline.htm" -HealthUrl $config.healthUrl `
                -DllUnlockTimeoutSeconds $config.dllUnlockTimeoutSeconds `
                -HealthCheckTimeoutSeconds $config.healthCheckTimeoutSeconds -HealthCheckRetrySeconds $config.healthCheckRetrySeconds `
                -LockState $lockState -Journal $journal
        }

        # ---------------------------------------------------------
        # 7. Manifest = old remote entries, overwritten only for the
        #    area(s) actually deployed this run - a partial-target run
        #    must never claim the untouched area is now "in sync".
        # ---------------------------------------------------------
        $finalFiles = [ordered]@{}
        foreach ($k in $remoteFiles.Keys) { $finalFiles[$k] = $remoteFiles[$k] }
        if ($frontendHasWork) {
            foreach ($p in $areas.FrontendUpload) { $finalFiles[$p] = $localManifest[$p] }
            foreach ($p in $areas.FrontendDelete) { $finalFiles.Remove($p) }
        }
        if ($backendHasWork) {
            foreach ($p in $areas.BackendUpload) { $finalFiles[$p] = $localManifest[$p] }
            foreach ($p in $areas.BackendDelete) { $finalFiles.Remove($p) }
        }
        # First-ever deploy (no remote manifest existed): fall back to
        # whatever this run actually touched, area by area, same rule.
        if (-not $remoteManifest -and $Target -eq "all") {
            $finalFiles = $localManifest
        }

        Publish-Manifest -Ctx $ctx -Files $finalFiles -ReleaseId $releaseId -GitCommit $gitCommit -Machine $machine
        Publish-DeployInfo -Ctx $ctx -ReleaseId $releaseId -GitCommit $gitCommit -Machine $machine -Operator $operator -Target $Target
        Publish-Journal -Ctx $ctx -Journal $journal -PreviousManifestJson $previousManifestJson

        Release-DeployLock -Ctx $ctx -LockState $lockState
        Write-DeployLog "--- DEPLOY SUCCESS (release $releaseId, target $Target) ---" "OK"
        Clear-FtpsContext -Ctx $ctx
        exit 0
    }
    catch {
        $failureMessage = $_.Exception.Message
        Write-DeployLog "Deploy step failed: $failureMessage" "ERROR"
        Clear-PendingTempFiles -Ctx $ctx

        if ($journal.Operations.Count -gt 0 -or $journal.MaintenanceEnabled) {
            Write-DeployLog "Production was modified this run - attempting automatic rollback..." "WARN"
            Publish-Journal -Ctx $ctx -Journal $journal -PreviousManifestJson $previousManifestJson
            try {
                $previousRelease = if ($remoteManifest) { $remoteManifest.release } else { "none (first deploy)" }
                Invoke-Rollback -Ctx $ctx -Journal $journal -PreviousManifestJson $previousManifestJson `
                    -PreviousRelease $previousRelease -HealthUrl $config.healthUrl -TemplatePath "$PSScriptRoot\templates\app_offline.htm"
                $rolledBack = $true
                Release-DeployLock -Ctx $ctx -LockState $lockState
            }
            catch {
                Write-DeployLog "ROLLBACK ALSO FAILED: $($_.Exception.Message)" "ERROR"
                Write-DeployLog "Lock is being LEFT HELD on purpose - system state is not known-safe. Resolve manually, then release with a fresh deploy run's -ForceClearStaleLock once confirmed dead." "ERROR"
                Clear-FtpsContext -Ctx $ctx
                Exit-WithError "ROLLBACK_FAILED: $($_.Exception.Message)"
            }
        }
        else {
            # Failed before touching anything remote (build/preflight/lock
            # itself) - nothing to roll back, safe to release if we got a lock.
            if ($lockState) { Release-DeployLock -Ctx $ctx -LockState $lockState }
        }

        Clear-FtpsContext -Ctx $ctx
        Exit-WithError $failureMessage
    }
}
catch {
    # Failures before a lock was ever taken (config/build/preflight/manifest
    # compare) - nothing remote was touched.
    if ($ctx) { Clear-FtpsContext -Ctx $ctx }
    Exit-WithError $_.Exception.Message
}

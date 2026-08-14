<#
.SYNOPSIS
    Remote deploy lock - extracted from Deploy-FtpSync.ps1 and extended with
    heartbeat refresh so a long backend deploy (offline -> wait-unlock ->
    backup -> replace -> health check) doesn't look abandoned mid-run.

.DESCRIPTION
    File-based, not the design doc's directory-based suggestion - the
    existing token + read-after-write ownership check already narrows the
    race adequately for this project's actual usage (one operator deploying
    at a time, occasionally from a second machine), and the doc itself flags
    the directory approach as needing real-server testing first. Requires
    dot-sourcing ftps.ps1 first (uses New-FtpUri/Get-RemoteFileBytes/
    Publish-RemoteFile/Remove-RemoteFile/Write-DeployLog).
#>

$script:LockRelativePath = ".deploy/locks/deploy.lock.json"

function Get-RemoteLock {
    param($Ctx)
    $bytes = Get-RemoteFileBytes -Ctx $Ctx -Uri (New-FtpUri -Ctx $Ctx -RelativePath $script:LockRelativePath)
    if (-not $bytes) { return $null }
    try { return ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json) } catch { return $null }
}

# Returns a lock-state object to pass into Update-DeployLockHeartbeat /
# Release-DeployLock. Throws DEPLOY_LOCKED on an active lock, or on a stale
# one unless -ForceClearStaleLock is passed.
function Acquire-DeployLock {
    param(
        $Ctx,
        [string]$ReleaseId,
        [string]$Machine = $env:COMPUTERNAME,
        [string]$Operator = $env:USERNAME,
        [int]$StaleMinutes = 15,
        [switch]$ForceClearStaleLock
    )

    $existing = Get-RemoteLock -Ctx $Ctx
    if ($existing) {
        $age = (Get-Date).ToUniversalTime() - [DateTime]::Parse($existing.lastHeartbeatAtUtc).ToUniversalTime()
        if ($age.TotalMinutes -lt $StaleMinutes) {
            throw "DEPLOY_LOCKED: deployment already in progress - machine='$($existing.machine)' operator='$($existing.operator)' release='$($existing.release)' lastHeartbeatAtUtc='$($existing.lastHeartbeatAtUtc)' (age $([int]$age.TotalMinutes) min). Refusing to proceed."
        }
        if (-not $ForceClearStaleLock) {
            throw "DEPLOY_LOCKED (stale): age $([int]$age.TotalMinutes) min >= $StaleMinutes min threshold - machine='$($existing.machine)' operator='$($existing.operator)' release='$($existing.release)' lastHeartbeatAtUtc='$($existing.lastHeartbeatAtUtc)'. NOT removed automatically. Confirm the deploy really died, then re-run with -ForceClearStaleLock."
        }
        Write-DeployLog "Overriding stale lock per -ForceClearStaleLock (previous holder: $($existing.machine)/$($existing.operator), release $($existing.release), last heartbeat $($existing.lastHeartbeatAtUtc))." "WARN"
    }

    $lockState = [ordered]@{
        Token   = [Guid]::NewGuid().ToString()
        Machine = $Machine
        Operator = $Operator
        Release = $ReleaseId
    }
    Write-RemoteLockFile -Ctx $Ctx -LockState $lockState -StartedAtUtc (Get-Date).ToUniversalTime().ToString("o")

    # Read-after-write ownership check - narrows (does not eliminate) the
    # race window inherent to FTP's lack of an atomic create-if-absent.
    Start-Sleep -Milliseconds 300
    $verify = Get-RemoteLock -Ctx $Ctx
    if (-not $verify -or $verify.token -ne $lockState.Token) {
        throw "DEPLOY_LOCKED: lock ownership could not be confirmed after write (another machine may have raced us). Aborting without making further changes."
    }
    Write-DeployLog "Deployment lock acquired (token $($lockState.Token.Substring(0,8))..., release '$ReleaseId')." "OK"
    return $lockState
}

function Write-RemoteLockFile {
    param($Ctx, $LockState, [string]$StartedAtUtc)
    $obj = [ordered]@{
        schemaVersion       = 1
        token               = $LockState.Token
        machine             = $LockState.Machine
        operator            = $LockState.Operator
        release             = $LockState.Release
        startedAtUtc        = if ($StartedAtUtc) { $StartedAtUtc } else { (Get-Date).ToUniversalTime().ToString("o") }
        lastHeartbeatAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
    }
    $json = ($obj | ConvertTo-Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Publish-RemoteFile -Ctx $Ctx -Bytes $bytes -RelativePath $script:LockRelativePath
}

# Call periodically during long-running steps (large upload batches, the
# DLL-unlock wait loop) so the lock's age keeps resetting and a second
# machine doesn't see a false "stale" reading mid-deploy.
function Update-DeployLockHeartbeat {
    param($Ctx, $LockState)
    try {
        $current = Get-RemoteLock -Ctx $Ctx
        if (-not $current -or $current.token -ne $LockState.Token) {
            Write-DeployLog "Lock heartbeat skipped - lock is no longer owned by this run (token mismatch)." "WARN"
            return
        }
        Write-RemoteLockFile -Ctx $Ctx -LockState $LockState -StartedAtUtc $current.startedAtUtc
    }
    catch {
        Write-DeployLog "Lock heartbeat failed (non-fatal, will retry next call): $($_.Exception.Message)" "WARN"
    }
}

function Release-DeployLock {
    param($Ctx, $LockState)
    if (-not $LockState) { return }
    try {
        $current = Get-RemoteLock -Ctx $Ctx
        if ($current -and $current.token -eq $LockState.Token) {
            Remove-RemoteFile -Ctx $Ctx -Uri (New-FtpUri -Ctx $Ctx -RelativePath $script:LockRelativePath) -IgnoreMissing | Out-Null
            Write-DeployLog "Deployment lock released." "OK"
        }
        else {
            Write-DeployLog "Lock no longer matches this run's token - NOT deleting (owned by someone else now). Manual check recommended." "WARN"
        }
    }
    catch {
        Write-DeployLog "Could not release lock: $($_.Exception.Message)" "WARN"
    }
}

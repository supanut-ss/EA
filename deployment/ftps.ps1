<#
.SYNOPSIS
    Low-level FTPS/FTP transport primitives, shared by every other script
    under deployment/. Dot-source this file, call New-FtpsContext once, then
    pass the returned $Ctx into every other function here.

.DESCRIPTION
    Every function takes -Ctx explicitly instead of relying on script-scope
    globals, so behavior doesn't depend on dot-sourcing order/scope quirks -
    the same reason Deploy-FtpSync.ps1's single-file version was fine on its
    own but wouldn't split cleanly across multiple files.

    Extracted and extended from the repo's existing Deploy-FtpSync.ps1:
      - Certificate pinning (trust-on-first-use, same as before)
      - Temp-upload-then-rename with post-upload size verification + retry
      - NEW: Publish-RemoteFile can back up the file it's about to replace
        instead of deleting it - Deploy-FtpSync.ps1's Rename-RemoteFile used
        to delete the old target on a failed rename-over, which destroys the
        one thing a rollback would need to restore.
      - NEW: Test-RemoteFileUnlocked / Wait-RemoteFilesUnlocked - a rename
        probe (rename the live file to itself+suffix and immediately back)
        to actually verify a DLL is free instead of a blind Start-Sleep.
      - NEW: Publish-RemoteFilesParallel - runspace-pool based (this repo's
        PowerShell is 5.1, no `ForEach-Object -Parallel`).
#>

# Own path, captured at dot-source time (NOT $PSCommandPath read later from
# inside a function - by then the caller's dot-source has merged scope and
# $PSCommandPath would resolve to the CALLER's script instead). Needed so
# Publish-RemoteFilesParallel's runspaces can dot-source this same file to
# get these function definitions in their own isolated runspace.
$FtpsModulePath = $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Logging - shared by every deployment/*.ps1 file. Never print
# $Ctx.Password or any secret - every call site below only ever
# interpolates paths, sizes, hashes, and status text.
# ---------------------------------------------------------------------------
function Write-DeployLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("HH:mm:ss")
    $color = switch ($Level) {
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "OK"    { "Green" }
        default { "Gray" }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Context - one of these gets built once per run and threaded through every
# function below instead of relying on ambient script-scope state.
# ---------------------------------------------------------------------------
function New-FtpsContext {
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [ValidateSet("FTPS", "FTP")][string]$Protocol = "FTPS",
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [string]$CertificateThumbprint,
        [int]$MaxParallelUploads = 4,
        [int]$OperationTimeoutSeconds = 60
    )

    $useSsl = ($Protocol -eq "FTPS")
    if ($useSsl -and -not $CertificateThumbprint) {
        Write-DeployLog "No certificate thumbprint pinned yet - first connection will report the observed thumbprint." "WARN"
    }

    $ctx = [ordered]@{
        Server                = $Server
        Username              = $Username
        Password              = $Password
        UseSsl                = $useSsl
        RemotePath             = $RemotePath.Trim('/')
        CertificateThumbprint = $CertificateThumbprint
        MaxParallelUploads    = [Math]::Max(1, $MaxParallelUploads)
        TimeoutMs             = $OperationTimeoutSeconds * 1000
        PendingTempFiles      = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
        EnsuredDirs           = [System.Collections.Hashtable]::Synchronized(@{})
        ObservedThumbprint    = $null
    }

    if ($useSsl) {
        # Trust-on-first-use, same contract as Deploy-FtpSync.ps1: with a pin
        # configured, anything else is rejected outright; with none configured
        # yet, the very first connection is let through only so the operator
        # can read the thumbprint back and consciously pin it afterward.
        $thumbHolder = $ctx
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($sender, $certificate, $chain, $sslErrors)
            $thumb = $certificate.GetCertHashString()
            $thumbHolder.ObservedThumbprint = $thumb
            if ($thumbHolder.CertificateThumbprint) {
                return ($thumb -eq $thumbHolder.CertificateThumbprint)
            }
            return $true
        }.GetNewClosure()
    }

    return $ctx
}

function Clear-FtpsContext {
    param($Ctx)
    if ($Ctx.UseSsl) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null }
}

function Test-FtpsConnection {
    param($Ctx)
    if (-not $Ctx.UseSsl) { return }
    try {
        $probe = New-FtpRequest -Ctx $Ctx -Uri "ftp://$($Ctx.Server)/" -Method ([System.Net.WebRequestMethods+Ftp]::ListDirectory)
        $resp = $probe.GetResponse(); $resp.Close()
    }
    catch {
        if ($Ctx.CertificateThumbprint) {
            throw "FTPS_CERTIFICATE_INVALID: server certificate did NOT match the pinned thumbprint ($($Ctx.CertificateThumbprint)). Refusing to connect - verify out of band before re-pinning. Underlying error: $($_.Exception.Message)"
        }
        throw "Could not establish FTPS connection: $($_.Exception.Message)"
    }
    if ($Ctx.CertificateThumbprint) {
        Write-DeployLog "FTPS certificate verified against pinned thumbprint." "OK"
    }
    else {
        Write-DeployLog "Connected over FTPS. No thumbprint pinned yet - observed: $($Ctx.ObservedThumbprint)" "WARN"
        Write-DeployLog "Verify this out of band (hosting control panel), then pin it in DEPLOY_FTPS_THUMBPRINT." "WARN"
    }
}

# ---------------------------------------------------------------------------
# Low-level request/URI helpers
# ---------------------------------------------------------------------------
function New-FtpRequest {
    param($Ctx, [string]$Uri, [string]$Method)
    $request = [System.Net.FtpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Credentials = New-Object System.Net.NetworkCredential($Ctx.Username, $Ctx.Password)
    $request.UsePassive = $true
    $request.UseBinary = $true
    $request.KeepAlive = $true
    $request.EnableSsl = $Ctx.UseSsl
    $request.Timeout = $Ctx.TimeoutMs
    $request.ReadWriteTimeout = [Math]::Max($Ctx.TimeoutMs, 120000)
    return $request
}

# Escapes each path segment individually so spaces/unicode survive without
# mangling the "/" separators.
function New-FtpUri {
    param($Ctx, [string]$RelativePath)
    $clean = $RelativePath.Replace('\', '/').Trim('/')
    $segments = $clean.Split('/') | Where-Object { $_ -ne "" } | ForEach-Object { [Uri]::EscapeDataString($_) }
    $joined = [string]::Join('/', $segments)
    return "ftp://$($Ctx.Server)/$($Ctx.RemotePath)/$joined"
}

function Get-RemoteFileBytes {
    param($Ctx, [string]$Uri)
    try {
        $req = New-FtpRequest -Ctx $Ctx -Uri $Uri -Method ([System.Net.WebRequestMethods+Ftp]::DownloadFile)
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $ms = New-Object System.IO.MemoryStream
        $stream.CopyTo($ms)
        $resp.Close()
        return $ms.ToArray()
    }
    catch [System.Net.WebException] {
        $ftpResponse = $_.Exception.Response
        if ($ftpResponse) {
            $code = [int]$ftpResponse.StatusCode
            $ftpResponse.Close()
            if ($code -eq [int][System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable) { return $null }
        }
        throw
    }
}

function Get-RemoteFileSize {
    param($Ctx, [string]$Uri)
    try {
        $req = New-FtpRequest -Ctx $Ctx -Uri $Uri -Method ([System.Net.WebRequestMethods+Ftp]::GetFileSize)
        $resp = $req.GetResponse()
        $size = $resp.ContentLength
        $resp.Close()
        return $size
    }
    catch { return -1 }
}

function Test-RemoteFileExists {
    param($Ctx, [string]$RelativePath)
    return (Get-RemoteFileSize -Ctx $Ctx -Uri (New-FtpUri -Ctx $Ctx -RelativePath $RelativePath)) -ge 0
}

# Direct in-place upload - NO temp-name-then-rename. Reserved for
# app_offline.htm specifically: the moment any file matching "app_offline*"
# exists at the site root, the ASP.NET Core Module can intercept/lock it
# immediately - including a temp-named variant like
# "app_offline.htm.uploading-xxxx", which then can't be renamed (confirmed
# against the real host: every attempt 550'd). The original, previously-
# working deploy.ps1 always uploaded this file directly for the same
# reason. Every other file keeps the safer temp+rename+verify path - this
# is a deliberate, narrow exception for one specific filename pattern.
function Publish-RemoteFileDirect {
    param($Ctx, [byte[]]$Bytes, [string]$RelativePath)
    $dir = Split-Path $RelativePath -Parent
    if ($dir) { Ensure-RemoteDirectory -Ctx $Ctx -RelativeDir $dir }
    $uri = New-FtpUri -Ctx $Ctx -RelativePath $RelativePath

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $req = New-FtpRequest -Ctx $Ctx -Uri $uri -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile)
            $req.ContentLength = $Bytes.Length
            $stream = $req.GetRequestStream()
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Close()
            $resp = $req.GetResponse(); $resp.Close()
            Write-DeployLog "Uploaded (direct): $RelativePath"
            return
        }
        catch [System.Net.WebException] {
            if ($attempt -lt $maxAttempts) {
                $delay = 1.5 * $attempt
                Write-DeployLog "Transient upload error for '$RelativePath' (attempt $attempt/$maxAttempts): $($_.Exception.Message) - retrying in ${delay}s" "WARN"
                Start-Sleep -Seconds $delay
                continue
            }
            throw "Upload failed for '$RelativePath' after $maxAttempts attempts: $($_.Exception.Message)"
        }
    }
}

function Remove-RemoteFile {
    param($Ctx, [string]$Uri, [switch]$IgnoreMissing)
    try {
        $req = New-FtpRequest -Ctx $Ctx -Uri $Uri -Method ([System.Net.WebRequestMethods+Ftp]::DeleteFile)
        $resp = $req.GetResponse(); $resp.Close()
        return $true
    }
    catch [System.Net.WebException] {
        if ($IgnoreMissing) { return $false }
        $ftpResponse = $_.Exception.Response
        if ($ftpResponse) {
            $code = [int]$ftpResponse.StatusCode
            $ftpResponse.Close()
            if ($code -eq [int][System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable) { return $false }
        }
        throw
    }
}

# Rename with a bounded retry. This FTP server's RNTO returns 550 when the
# destination already exists (confirmed against the real host - every
# redeploy of an unchanged filename like index.html failed 5/5 attempts
# before this) rather than replacing it, so plain "replace this file with
# that one" needs a way to clear the target first.
#
# -ReplaceExisting: if the destination exists, delete it and retry the
# rename. Safe for disposable/no-backup-needed callers (frontend assets:
# content-hashed JS/CSS are immutable anyway, and index.html is trivially
# regenerable from source - nothing here is ever the last copy of anything).
#
# Callers that need the previous file recoverable (backend runtime files)
# do NOT pass this - they call Backup-RemoteFileIfExists first instead,
# which moves the target out of the way under a `.bak.<release>` name
# before Publish-RemoteFile ever calls Rename-RemoteFile, so this function
# hits an empty target and never needs to fall back to deleting anything.
function Rename-RemoteFile {
    param($Ctx, [string]$FromUri, [string]$NewName, [switch]$ReplaceExisting)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $req = New-FtpRequest -Ctx $Ctx -Uri $FromUri -Method ([System.Net.WebRequestMethods+Ftp]::Rename)
            $req.RenameTo = $NewName
            $resp = $req.GetResponse(); $resp.Close()
            return
        }
        catch [System.Net.WebException] {
            if ($ReplaceExisting -and $attempt -lt 3) {
                $targetUri = (Split-Path $FromUri -Parent).Replace('\', '/') + "/" + $NewName
                Remove-RemoteFile -Ctx $Ctx -Uri $targetUri -IgnoreMissing | Out-Null
                Start-Sleep -Milliseconds (300 * $attempt)
                continue
            }
            if (-not $ReplaceExisting -and $attempt -lt 3) {
                Start-Sleep -Milliseconds (300 * $attempt)
                continue
            }
            throw
        }
    }
}

# Renames an existing remote file to "<name>.bak.<suffix>" if it exists, so
# a subsequent Publish-RemoteFile with -BackupBeforeReplace can rename the
# new temp file straight over a now-empty target instead of needing the old
# delete-and-retry fallback. Returns the backup's relative path, or $null if
# there was nothing to back up. Appends an entry to $Journal when supplied.
function Backup-RemoteFileIfExists {
    param($Ctx, [string]$RelativePath, [string]$Suffix, $Journal)
    $uri = New-FtpUri -Ctx $Ctx -RelativePath $RelativePath
    if ((Get-RemoteFileSize -Ctx $Ctx -Uri $uri) -lt 0) { return $null }

    $dir = Split-Path $RelativePath -Parent
    $fileName = Split-Path $RelativePath -Leaf
    $backupName = "$fileName.bak.$Suffix"
    $backupRelative = if ($dir) { "$dir/$backupName" } else { $backupName }

    # Clear out a stale backup from a previous failed run under the exact
    # same release id before reusing the name.
    Remove-RemoteFile -Uri (New-FtpUri -Ctx $Ctx -RelativePath $backupRelative) -Ctx $Ctx -IgnoreMissing | Out-Null
    Rename-RemoteFile -Ctx $Ctx -FromUri $uri -NewName $backupName

    if ($Journal) {
        $Journal.Operations.Add([ordered]@{
            type    = "backup"
            path    = $RelativePath
            backup  = $backupRelative
        }) | Out-Null
    }
    Write-DeployLog "Backed up: $RelativePath -> $backupRelative"
    return $backupRelative
}

$script:__ensureDirLock = [object]::new()
function Ensure-RemoteDirectory {
    param($Ctx, [string]$RelativeDir)
    if ([string]::IsNullOrWhiteSpace($RelativeDir) -or $RelativeDir -eq ".") { return }

    $parts = $RelativeDir.Replace('\', '/').Trim('/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    $current = ""
    foreach ($part in $parts) {
        $current = if ($current) { "$current/$part" } else { $part }
        [System.Threading.Monitor]::Enter($script:__ensureDirLock)
        try {
            if ($Ctx.EnsuredDirs.ContainsKey($current)) { continue }
            $Ctx.EnsuredDirs[$current] = $true
        }
        finally { [System.Threading.Monitor]::Exit($script:__ensureDirLock) }

        $uri = New-FtpUri -Ctx $Ctx -RelativePath $current
        try {
            $req = New-FtpRequest -Ctx $Ctx -Uri $uri -Method ([System.Net.WebRequestMethods+Ftp]::MakeDirectory)
            $resp = $req.GetResponse(); $resp.Close()
        }
        catch [System.Net.WebException] {
            $ftpResponse = $_.Exception.Response
            if ($ftpResponse) { $ftpResponse.Close() }
            # 550 here almost always means "already exists" - fine.
        }
    }
}

# ---------------------------------------------------------------------------
# Temp-name-then-rename upload, with post-upload size verification and
# retry. When -BackupBeforeReplace is set, an existing target is backed up
# (see above) before the rename-over instead of being clobbered.
# ---------------------------------------------------------------------------
function Publish-RemoteFile {
    param(
        $Ctx,
        [byte[]]$Bytes,
        [string]$RelativePath,
        [switch]$BackupBeforeReplace,
        [string]$BackupSuffix,
        $Journal
    )

    $dir = Split-Path $RelativePath -Parent
    if ($dir) { Ensure-RemoteDirectory -Ctx $Ctx -RelativeDir $dir }

    $fileName = Split-Path $RelativePath -Leaf
    $tempName = "$fileName.uploading-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $tempRelative = if ($dir) { "$dir/$tempName" } else { $tempName }
    $tempUri = New-FtpUri -Ctx $Ctx -RelativePath $tempRelative
    $finalUri = New-FtpUri -Ctx $Ctx -RelativePath $RelativePath

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $req = New-FtpRequest -Ctx $Ctx -Uri $tempUri -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile)
            $req.ContentLength = $Bytes.Length
            $stream = $req.GetRequestStream()
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Close()
            $resp = $req.GetResponse(); $resp.Close()
            $Ctx.PendingTempFiles.Add($tempUri)

            Start-Sleep -Milliseconds 150
            $remoteSize = Get-RemoteFileSize -Ctx $Ctx -Uri $tempUri
            if ($remoteSize -ne $Bytes.Length) {
                Write-DeployLog "Post-upload verification failed for '$RelativePath' - retrying" "WARN"
                Remove-RemoteFile -Ctx $Ctx -Uri $tempUri -IgnoreMissing | Out-Null
                if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (2 * $attempt); continue }
                throw "Upload never verified correctly for '$RelativePath' after $maxAttempts attempts (ghost-success pattern)."
            }

            $isNewFile = -not (Test-RemoteFileExists -Ctx $Ctx -RelativePath $RelativePath)
            if ($BackupBeforeReplace) {
                # Target gets moved out of the way here, so the rename below
                # should hit an empty spot - -ReplaceExisting stays off on
                # purpose, so a bug that skipped the backup surfaces as a
                # thrown error instead of silently deleting an un-backed-up
                # backend file.
                Backup-RemoteFileIfExists -Ctx $Ctx -RelativePath $RelativePath -Suffix $BackupSuffix -Journal $Journal | Out-Null
                Rename-RemoteFile -Ctx $Ctx -FromUri $tempUri -NewName $fileName
            }
            else {
                # Disposable path (frontend assets, or any backend content
                # file nobody asked to back up) - this FTP server 550s an
                # RNTO onto an existing name, so let it clear the old one.
                Rename-RemoteFile -Ctx $Ctx -FromUri $tempUri -NewName $fileName -ReplaceExisting
            }

            if ($Journal -and $isNewFile) {
                $Journal.Operations.Add([ordered]@{ type = "create"; path = $RelativePath }) | Out-Null
            }

            Write-DeployLog "Uploaded: $RelativePath"
            return
        }
        catch [System.Net.WebException] {
            if ($attempt -lt $maxAttempts) {
                $delay = 1.5 * $attempt
                Write-DeployLog "Transient upload error for '$RelativePath' (attempt $attempt/$maxAttempts): $($_.Exception.Message) - retrying in ${delay}s" "WARN"
                Start-Sleep -Seconds $delay
                continue
            }
            throw "Upload failed for '$RelativePath' after $maxAttempts attempts: $($_.Exception.Message)"
        }
    }
}

# Runspace-pool parallel upload for the common case (no backup/journal
# needed - frontend assets, which are disposable/content-hashed). Each
# runspace gets its own copy of $Ctx (safe: FtpWebRequest instances are
# independent; the shared ConcurrentBag/synchronized hashtable inside $Ctx
# are thread-safe) and calls the same Publish-RemoteFile above.
function Publish-RemoteFilesParallel {
    param($Ctx, [array]$Files) # each: @{ Bytes = [byte[]]; RelativePath = "..." }

    if ($Files.Count -eq 0) { return }
    $maxParallel = [Math]::Min($Ctx.MaxParallelUploads, $Files.Count)

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $maxParallel, $iss, $Host)
    $pool.Open()

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($file in $Files) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript({
            param($Ctx, $Bytes, $RelativePath, $FtpsScriptPath)
            . $FtpsScriptPath
            Publish-RemoteFile -Ctx $Ctx -Bytes $Bytes -RelativePath $RelativePath
        }).AddArgument($Ctx).AddArgument($file.Bytes).AddArgument($file.RelativePath).AddArgument($FtpsModulePath)
        $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); RelativePath = $file.RelativePath })
    }

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($job in $jobs) {
        try { $job.PS.EndInvoke($job.Handle) | Out-Null }
        catch { $failures.Add("$($job.RelativePath): $($_.Exception.Message)") }
        if ($job.PS.HadErrors) {
            foreach ($e in $job.PS.Streams.Error) { $failures.Add("$($job.RelativePath): $($e.ToString())") }
        }
        $job.PS.Dispose()
    }
    $pool.Close()
    $pool.Dispose()

    if ($failures.Count -gt 0) {
        throw "Parallel upload failed for $($failures.Count) file(s):`n$([string]::Join("`n", $failures))"
    }
}

function Clear-PendingTempFiles {
    param($Ctx)
    foreach ($uri in @($Ctx.PendingTempFiles.ToArray())) {
        try { Remove-RemoteFile -Ctx $Ctx -Uri $uri -IgnoreMissing | Out-Null } catch {}
    }
}

# ---------------------------------------------------------------------------
# DLL/runtime-file unlock detection - a rename probe. Windows file locks
# block rename the same as write, so a clean round-trip rename proves the
# file is actually free, unlike a blind Start-Sleep.
# ---------------------------------------------------------------------------
function Test-RemoteFileUnlocked {
    param($Ctx, [string]$RelativePath)
    if (-not (Test-RemoteFileExists -Ctx $Ctx -RelativePath $RelativePath)) { return $true } # nothing there yet = nothing to be locked

    $uri = New-FtpUri -Ctx $Ctx -RelativePath $RelativePath
    $fileName = Split-Path $RelativePath -Leaf
    $probeName = "$fileName.unlocktest-$([Guid]::NewGuid().ToString('N').Substring(0,6))"
    try {
        Rename-RemoteFile -Ctx $Ctx -FromUri $uri -NewName $probeName
    }
    catch {
        return $false
    }
    $dir = Split-Path $RelativePath -Parent
    $probeRelative = if ($dir) { "$dir/$probeName" } else { $probeName }
    Rename-RemoteFile -Ctx $Ctx -FromUri (New-FtpUri -Ctx $Ctx -RelativePath $probeRelative) -NewName $fileName
    return $true
}

function Wait-RemoteFilesUnlocked {
    param($Ctx, [string[]]$RelativePaths, [int]$TimeoutSeconds = 45)
    if ($RelativePaths.Count -eq 0) { return $true }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $delaySeconds = 0.5
    while ((Get-Date) -lt $deadline) {
        $stillLocked = $RelativePaths | Where-Object { -not (Test-RemoteFileUnlocked -Ctx $Ctx -RelativePath $_) }
        if ($stillLocked.Count -eq 0) { return $true }
        Write-DeployLog "Waiting for $($stillLocked.Count) file(s) to unlock: $([string]::Join(', ', $stillLocked))" "WARN"
        Start-Sleep -Seconds $delaySeconds
        $delaySeconds = [Math]::Min($delaySeconds * 1.6, 5)
    }
    return $false
}

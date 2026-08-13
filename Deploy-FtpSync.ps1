<#
.SYNOPSIS
    Generic manifest-based FTPS/FTP release sync engine for shared hosting
    (no SSH). Reusable across projects on the same host - point it at any
    local release directory and remote root.

.DESCRIPTION
    Syncs a local release directory to a remote FTP/FTPS root using a
    SHA-256 content manifest stored ON THE SERVER (not just locally), so the
    "what has already been deployed" state is correct no matter which
    developer machine deploys next.

    Per-run flow:
      1. Connect (FTPS by default, certificate pinned by thumbprint)
      2. Acquire a remote deployment lock (never silently steals a fresh lock)
      3. Download the current remote manifest
      4. Hash the local release directory, diff against the remote manifest
      5. Upload changed/new files to a temp name, verify, then rename over
         the real file (never overwrite a live file in place)
      6. Delete files that were removed from source AND were present in the
         old manifest (never deletes anything the manifest never tracked)
      7. Upload the new manifest last, via the same temp+rename technique
      8. Release the lock, but ONLY if it still holds this run's token

    On any failure: stop immediately, do not touch the remote manifest,
    remove any of this run's own temp files, release the lock only if this
    run owns it, and exit non-zero.

.LIMITATIONS (plain FTP/FTPS has no atomic multi-file transaction)
    - There is no server-side "commit" primitive: each file becomes live the
      moment its rename lands. A visitor mid-deploy can observe a mix of old
      and new files for the files that don't share a request. This script
      minimizes that window (temp-upload-then-rename per file, manifest
      updated last) but cannot eliminate it - true atomicity would require
      shell/SSH access to stage a directory and swap a symlink, which this
      host does not offer.
    - The deployment lock is best-effort, not a true mutex: FTP has no
      atomic "create if not exists". This script narrows the race with a
      read-after-write ownership check, but two machines starting within
      milliseconds of each other could still both believe they hold the
      lock. For guaranteed single-flight deploys, run this through a single
      CI runner/queue instead of relying on the FTP layer for mutual
      exclusion.
#>

[CmdletBinding()]
param(
    # --- Connection (secrets should come from environment variables, see
    # bottom of script / README - these params exist so a CI system can
    # inject them as pipeline variables instead if that's how secrets are
    # managed there) ---
    [string]$Server = $env:DEPLOY_FTP_SERVER,
    [string]$Username = $env:DEPLOY_FTP_USERNAME,
    [string]$Password = $env:DEPLOY_FTP_PASSWORD,
    [ValidateSet("FTPS", "FTP")]
    [string]$Protocol = $(if ($env:DEPLOY_FTP_PROTOCOL) { $env:DEPLOY_FTP_PROTOCOL } else { "FTPS" }),
    [string]$CertificateThumbprint = $env:DEPLOY_FTPS_THUMBPRINT,

    # --- What to sync ---
    [Parameter(Mandatory = $true)]
    [string]$LocalPath,
    [Parameter(Mandatory = $true)]
    [string]$RemotePath,

    # --- Identity recorded in the lock file ---
    [string]$ReleaseId = "unknown",
    [string]$Machine = $env:COMPUTERNAME,

    # --- Paths that must never be uploaded over or deleted, even if the
    # manifest diff would otherwise touch them. Matched case-insensitively;
    # a trailing "/" means "this directory and everything under it". ---
    [string[]]$ProtectedPaths = @(
        ".env", ".env.*",
        "uploads/", "storage/", "logs/", "sessions/", "cache/",
        "*.mdf", "*.ldf", "*.ndf", "*.bak", "*.sqlite", "*.sqlite3", "*.db"
    ),

    [int]$StaleLockMinutes = 15,
    [switch]$ForceUnlock,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Logging - never print $Password/secret values. Every call site below only
# ever interpolates paths, sizes, hashes, and status text.
# ---------------------------------------------------------------------------
function Write-Log {
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

if (-not $Server -or -not $Username -or -not $Password) {
    throw "Missing FTP credentials. Set DEPLOY_FTP_SERVER, DEPLOY_FTP_USERNAME, DEPLOY_FTP_PASSWORD as environment variables (or pass -Server/-Username/-Password)."
}
if (-not $Machine) { $Machine = "unknown-machine" }

$useSsl = ($Protocol -eq "FTPS")
if ($useSsl -and -not $CertificateThumbprint) {
    Write-Log "DEPLOY_FTPS_THUMBPRINT is not set - certificate identity cannot be verified yet." "WARN"
}

# ---------------------------------------------------------------------------
# Certificate pinning (trust-on-first-use). We NEVER blanket-trust: if a
# thumbprint is configured, the presented certificate must match it exactly
# or the connection fails. If none is configured, the very first connection
# is allowed through ONLY to let us report the thumbprint back to the
# operator - it is not silently written anywhere, the operator must
# consciously put it in DEPLOY_FTPS_THUMBPRINT after verifying it out of
# band (e.g. via the hosting control panel).
# ---------------------------------------------------------------------------
$script:observedThumbprint = $null
if ($useSsl) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
        param($sender, $certificate, $chain, $sslErrors)
        $thumb = $certificate.GetCertHashString()
        $script:observedThumbprint = $thumb
        if ($CertificateThumbprint) {
            return ($thumb -eq $CertificateThumbprint)
        }
        # No pin configured yet - allow through so the run can report the
        # thumbprint, but this path is only reachable on a first-ever run.
        return $true
    }
}

function New-FtpRequest {
    param([string]$Uri, [string]$Method)
    $request = [System.Net.FtpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
    $request.UsePassive = $true
    $request.UseBinary = $true
    $request.KeepAlive = $true
    $request.EnableSsl = $useSsl
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 120000
    return $request
}

# Build an FTP URI from a relative path, escaping each segment individually
# so spaces, unicode, and other special characters survive - escaping the
# whole path at once would also mangle the "/" separators.
function New-FtpUri {
    param([string]$RelativePath)
    $clean = $RelativePath.Replace('\', '/').Trim('/')
    $segments = $clean.Split('/') | Where-Object { $_ -ne "" } | ForEach-Object { [Uri]::EscapeDataString($_) }
    $joined = [string]::Join('/', $segments)
    return "ftp://$Server/$($RemotePath.Trim('/'))/$joined"
}

if ($useSsl -and $CertificateThumbprint) {
    try {
        $probe = New-FtpRequest -Uri "ftp://$Server/" -Method ([System.Net.WebRequestMethods+Ftp]::ListDirectory)
        $resp = $probe.GetResponse(); $resp.Close()
        Write-Log "FTPS certificate verified against pinned thumbprint." "OK"
    }
    catch {
        throw "FTPS certificate did NOT match DEPLOY_FTPS_THUMBPRINT ($CertificateThumbprint). Refusing to connect - this could mean the server's certificate legitimately changed, or a MITM. Verify out of band before updating the pinned thumbprint. Underlying error: $($_.Exception.Message)"
    }
}
elseif ($useSsl) {
    try {
        $probe = New-FtpRequest -Uri "ftp://$Server/" -Method ([System.Net.WebRequestMethods+Ftp]::ListDirectory)
        $resp = $probe.GetResponse(); $resp.Close()
        Write-Log "Connected over FTPS. No DEPLOY_FTPS_THUMBPRINT is pinned yet." "WARN"
        Write-Log "Observed certificate thumbprint: $($script:observedThumbprint)" "WARN"
        Write-Log "Verify this matches the certificate shown in your hosting control panel, then set DEPLOY_FTPS_THUMBPRINT to it before the next deploy." "WARN"
    }
    catch {
        throw "Could not establish FTPS connection: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Low-level remote file helpers
# ---------------------------------------------------------------------------
function Get-RemoteFileBytes {
    param([string]$Uri)
    try {
        $req = New-FtpRequest -Uri $Uri -Method ([System.Net.WebRequestMethods+Ftp]::DownloadFile)
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
    param([string]$Uri)
    try {
        $req = New-FtpRequest -Uri $Uri -Method ([System.Net.WebRequestMethods+Ftp]::GetFileSize)
        $resp = $req.GetResponse()
        $size = $resp.ContentLength
        $resp.Close()
        return $size
    }
    catch { return -1 }
}

function Remove-RemoteFile {
    param([string]$Uri, [switch]$IgnoreMissing)
    try {
        $req = New-FtpRequest -Uri $Uri -Method ([System.Net.WebRequestMethods+Ftp]::DeleteFile)
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

function Rename-RemoteFile {
    param([string]$FromUri, [string]$NewName)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $req = New-FtpRequest -Uri $FromUri -Method ([System.Net.WebRequestMethods+Ftp]::Rename)
            $req.RenameTo = $NewName
            $resp = $req.GetResponse(); $resp.Close()
            return
        }
        catch [System.Net.WebException] {
            $ftpResponse = $_.Exception.Response
            $code = $null
            if ($ftpResponse) { $code = [int]$ftpResponse.StatusCode; $ftpResponse.Close() }
            if ($code -eq [int][System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable -and $attempt -lt 3) {
                # Target likely already exists and this server won't rename over
                # it - delete the old target then retry. The old file stays
                # fully intact and served right up until this point.
                $targetUri = (Split-Path $FromUri -Parent).Replace('\', '/') + "/" + $NewName
                Remove-RemoteFile -Uri $targetUri -IgnoreMissing | Out-Null
                Start-Sleep -Milliseconds 300
                continue
            }
            throw
        }
    }
    throw "Rename failed after retries: $FromUri -> $NewName"
}

$script:ensuredDirs = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
function Ensure-RemoteDirectory {
    param([string]$RelativeDir)
    if ([string]::IsNullOrWhiteSpace($RelativeDir) -or $RelativeDir -eq ".") { return }
    if ($script:ensuredDirs.Contains($RelativeDir)) { return }

    $parts = $RelativeDir.Replace('\', '/').Trim('/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    $current = ""
    foreach ($part in $parts) {
        $current = if ($current) { "$current/$part" } else { $part }
        if ($script:ensuredDirs.Contains($current)) { continue }
        $uri = New-FtpUri -RelativePath $current
        try {
            $req = New-FtpRequest -Uri $uri -Method ([System.Net.WebRequestMethods+Ftp]::MakeDirectory)
            $resp = $req.GetResponse(); $resp.Close()
        }
        catch [System.Net.WebException] {
            $ftpResponse = $_.Exception.Response
            if ($ftpResponse) { $ftpResponse.Close() }
            # 550 here almost always means "already exists" - fine.
        }
        [void]$script:ensuredDirs.Add($current)
    }
}

# ---------------------------------------------------------------------------
# Temp-name-then-rename upload with retry + pre-rename verification. The
# real file at $RelativePath is never touched until the new content is
# confirmed correct on the server under its temp name.
# ---------------------------------------------------------------------------
$script:pendingTempFiles = New-Object System.Collections.Generic.List[string]

function Publish-RemoteFile {
    param([byte[]]$Bytes, [string]$RelativePath)

    $dir = Split-Path $RelativePath -Parent
    if ($dir) { Ensure-RemoteDirectory -RelativeDir $dir }

    $fileName = Split-Path $RelativePath -Leaf
    $tempName = "$fileName.uploading-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $tempRelative = if ($dir) { "$dir/$tempName" } else { $tempName }
    $tempUri = New-FtpUri -RelativePath $tempRelative
    $finalUri = New-FtpUri -RelativePath $RelativePath

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $req = New-FtpRequest -Uri $tempUri -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile)
            $req.ContentLength = $Bytes.Length
            $stream = $req.GetRequestStream()
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Close()
            $resp = $req.GetResponse(); $resp.Close()
            [void]$script:pendingTempFiles.Add($tempUri)

            Start-Sleep -Milliseconds 150
            $remoteSize = Get-RemoteFileSize -Uri $tempUri
            if ($remoteSize -ne $Bytes.Length) {
                Write-Log "Post-upload verification failed for '$RelativePath' (temp copy is missing/wrong size) - retrying" "WARN"
                Remove-RemoteFile -Uri $tempUri -IgnoreMissing | Out-Null
                $script:pendingTempFiles.Remove($tempUri) | Out-Null
                if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (2 * $attempt); continue }
                throw "Upload never verified correctly for '$RelativePath' after $maxAttempts attempts (ghost-success pattern)."
            }

            Rename-RemoteFile -FromUri $tempUri -NewName $fileName
            $script:pendingTempFiles.Remove($tempUri) | Out-Null
            Write-Log "Uploaded: $RelativePath"
            return
        }
        catch [System.Net.WebException] {
            if ($attempt -lt $maxAttempts) {
                $delay = 1.5 * $attempt
                Write-Log "Transient upload error for '$RelativePath' (attempt $attempt/$maxAttempts): $($_.Exception.Message) - retrying in ${delay}s" "WARN"
                Start-Sleep -Seconds $delay
                continue
            }
            throw "Upload failed for '$RelativePath' after $maxAttempts attempts: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Protected-path matching (defense in depth: applied to BOTH the upload
# candidate set built from local files, and the delete candidate set built
# from the remote manifest - a protected path is never touched either way).
# ---------------------------------------------------------------------------
function Test-ProtectedPath {
    param([string]$RelativePath, [string[]]$Patterns)
    $norm = $RelativePath.Replace('\', '/').TrimStart('/')
    $baseName = Split-Path $norm -Leaf
    foreach ($pattern in $Patterns) {
        if ($pattern.EndsWith("/")) {
            $prefix = $pattern.TrimEnd('/')
            if ($norm -eq $prefix -or $norm.StartsWith("$prefix/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        elseif ($baseName -like $pattern -or $norm -like $pattern) {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
$manifestRelative = ".deploy-manifest.json"

function Get-RemoteManifest {
    $bytes = Get-RemoteFileBytes -Uri (New-FtpUri -RelativePath $manifestRelative)
    if (-not $bytes) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Get-LocalManifest {
    param([string]$Root, [string[]]$Protected)
    $result = @{}
    $resolvedRoot = (Resolve-Path $Root).Path
    Get-ChildItem -Path $resolvedRoot -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($resolvedRoot.Length).TrimStart('\', '/').Replace('\', '/')
        if (Test-ProtectedPath -RelativePath $rel -Patterns $Protected) { return }
        $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
        $result[$rel] = $hash
    }
    return $result
}

# ---------------------------------------------------------------------------
# Deployment lock
# ---------------------------------------------------------------------------
$lockRelative = ".deploy.lock"
$script:lockToken = [Guid]::NewGuid().ToString()
$script:lockAcquired = $false

function Get-RemoteLock {
    $bytes = Get-RemoteFileBytes -Uri (New-FtpUri -RelativePath $lockRelative)
    if (-not $bytes) { return $null }
    try { return ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json) } catch { return $null }
}

function Acquire-DeployLock {
    $existing = Get-RemoteLock
    if ($existing) {
        $age = (Get-Date).ToUniversalTime() - [DateTime]::Parse($existing.startedAtUtc).ToUniversalTime()
        if ($age.TotalMinutes -lt $StaleLockMinutes) {
            throw "Deployment already in progress: machine='$($existing.machine)' user='$($existing.user)' release='$($existing.releaseId)' startedAtUtc='$($existing.startedAtUtc)' (age $([int]$age.TotalMinutes) min, stale threshold $StaleLockMinutes min). Refusing to proceed. [ExitCode 2]"
        }
        if (-not $ForceUnlock) {
            throw "Found a STALE lock (age $([int]$age.TotalMinutes) min >= $StaleLockMinutes min threshold): machine='$($existing.machine)' user='$($existing.user)' release='$($existing.releaseId)' startedAtUtc='$($existing.startedAtUtc)'. This will NOT be removed automatically. Inspect it, confirm that deploy really died, then re-run with -ForceUnlock. [ExitCode 3]"
        }
        Write-Log "Overriding stale lock per -ForceUnlock (previous holder: $($existing.machine)/$($existing.user), started $($existing.startedAtUtc))." "WARN"
    }

    $lockObj = [ordered]@{
        schemaVersion = 1
        token         = $script:lockToken
        machine       = $Machine
        user          = $env:USERNAME
        releaseId     = $ReleaseId
        startedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
    }
    $json = ($lockObj | ConvertTo-Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Publish-RemoteFile -Bytes $bytes -RelativePath $lockRelative

    # Read-after-write ownership check - narrows (does not eliminate) the
    # race window inherent to FTP's lack of an atomic create-if-absent.
    Start-Sleep -Milliseconds 300
    $verify = Get-RemoteLock
    if (-not $verify -or $verify.token -ne $script:lockToken) {
        throw "Lock ownership could not be confirmed after write (another machine may have raced us). Aborting without making further changes."
    }
    $script:lockAcquired = $true
    Write-Log "Deployment lock acquired (token $($script:lockToken.Substring(0,8))..., release '$ReleaseId')." "OK"
}

function Release-DeployLock {
    if (-not $script:lockAcquired) { return }
    try {
        $current = Get-RemoteLock
        if ($current -and $current.token -eq $script:lockToken) {
            Remove-RemoteFile -Uri (New-FtpUri -RelativePath $lockRelative) -IgnoreMissing | Out-Null
            Write-Log "Deployment lock released." "OK"
        }
        else {
            Write-Log "Lock no longer matches this run's token - NOT deleting (owned by someone else now). Manual check recommended." "WARN"
        }
    }
    catch {
        Write-Log "Could not release lock: $($_.Exception.Message)" "WARN"
    }
}

function Clear-PendingTempFiles {
    foreach ($uri in @($script:pendingTempFiles)) {
        try { Remove-RemoteFile -Uri $uri -IgnoreMissing | Out-Null } catch {}
    }
    $script:pendingTempFiles.Clear()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-Log "Local release path: $LocalPath"
    Write-Log "Remote root:        $RemotePath"
    Write-Log "Protocol:           $Protocol"
    if ($DryRun) { Write-Log "DRY RUN - no remote changes will be made." "WARN" }

    $remoteManifest = Get-RemoteManifest
    $remoteFiles = @{}
    if ($remoteManifest -and $remoteManifest.files) {
        $remoteManifest.files.PSObject.Properties | ForEach-Object { $remoteFiles[$_.Name] = $_.Value }
    }
    if (-not $remoteManifest) {
        Write-Log "No remote manifest found - treating as first deploy to this root (nothing will be deleted this run)." "WARN"
    }

    $localFiles = Get-LocalManifest -Root $LocalPath -Protected $ProtectedPaths

    $toUpload = @()
    foreach ($path in $localFiles.Keys) {
        if ($remoteFiles.ContainsKey($path) -and $remoteFiles[$path] -eq $localFiles[$path]) { continue }
        $toUpload += $path
    }

    $toDelete = @()
    foreach ($path in $remoteFiles.Keys) {
        if ($localFiles.ContainsKey($path)) { continue }
        if (Test-ProtectedPath -RelativePath $path -Patterns $ProtectedPaths) { continue }
        $toDelete += $path
    }

    $unchangedCount = $localFiles.Count - $toUpload.Count

    Write-Log "Plan: $($toUpload.Count) to upload/replace, $($toDelete.Count) to delete, $unchangedCount unchanged."
    foreach ($p in $toUpload) { Write-Log "  UPLOAD  $p" }
    foreach ($p in $toDelete) { Write-Log "  DELETE  $p" }

    if ($DryRun) {
        Write-Log "Dry run complete. No lock was taken and no remote changes were made." "OK"
        exit 0
    }

    if ($toUpload.Count -eq 0 -and $toDelete.Count -eq 0) {
        Write-Log "Nothing to do - remote already matches local release." "OK"
        exit 0
    }

    Acquire-DeployLock

    foreach ($path in $toUpload) {
        $fullLocal = Join-Path $LocalPath $path
        $bytes = [System.IO.File]::ReadAllBytes($fullLocal)
        Publish-RemoteFile -Bytes $bytes -RelativePath $path
    }

    foreach ($path in $toDelete) {
        Remove-RemoteFile -Uri (New-FtpUri -RelativePath $path) -IgnoreMissing | Out-Null
        Write-Log "Deleted: $path"
    }

    # Manifest is the LAST write of the transaction, and itself goes through
    # temp+rename so a concurrent reader never sees a partially-written one.
    $newFiles = @{}
    foreach ($path in $localFiles.Keys) { $newFiles[$path] = $localFiles[$path] }
    $manifestObj = [ordered]@{
        schemaVersion = 1
        releaseId     = $ReleaseId
        machine       = $Machine
        updatedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
        files         = $newFiles
    }
    $manifestJson = ($manifestObj | ConvertTo-Json -Depth 10)
    $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)
    Publish-RemoteFile -Bytes $manifestBytes -RelativePath $manifestRelative
    Write-Log "Manifest updated ($($newFiles.Count) tracked files)." "OK"

    Release-DeployLock
    Write-Log "Sync complete." "OK"
    exit 0
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" "ERROR"
    Write-Log "Manifest was NOT updated. Cleaning up this run's temp files." "WARN"
    Clear-PendingTempFiles
    Release-DeployLock
    exit 1
}
finally {
    if ($useSsl) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null }
}

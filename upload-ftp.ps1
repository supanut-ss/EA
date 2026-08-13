param(
    [Parameter(Mandatory = $true)]
    [string]$Server,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    [Parameter(Mandatory = $false)]
    [string]$RemotePath = "",

    [string[]]$ExcludePaths = @(),

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function New-FtpRequest {
    param(
        [string]$Uri,
        [string]$Method
    )

    $request = [System.Net.FtpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
    $request.UsePassive = $true
    $request.UseBinary = $true
    $request.KeepAlive = $false
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 120000
    return $request
}

function Test-RemoteDirectoryExists {
    param([string]$DirectoryPath)

    if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
        return $true
    }

    $uri = "ftp://$Server/$($DirectoryPath.Trim('/'))/"

    try {
        $request = New-FtpRequest -Uri $uri -Method ([System.Net.WebRequestMethods+Ftp]::ListDirectory)
        $response = $request.GetResponse()
        $response.Close()
        return $true
    }
    catch {
        return $false
    }
}

$script:ensuredDirs = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

function Ensure-RemoteDirectory {
    param([string]$DirectoryPath)

    if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
        return
    }

    # Almost every file in a typical deploy shares the same 1-2 directories -
    # once a directory is confirmed to exist this run, skip re-verifying it on
    # every single subsequent file. Cuts connection churn drastically (this
    # host has shown it doesn't tolerate hundreds of rapid sequential FTP
    # connections well), which was itself the cause of transient failures.
    if ($script:ensuredDirs.Contains($DirectoryPath)) {
        return
    }

    $parts = $DirectoryPath.Trim('/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    $current = ""

    foreach ($part in $parts) {
        if ($current) {
            $current = "$current/$part"
        }
        else {
            $current = $part
        }

        if ($script:ensuredDirs.Contains($current)) {
            continue
        }

        $uri = "ftp://$Server/$current"
        if ($DryRun) {
            continue
        }

        $dirAttempts = 3
        for ($dirAttempt = 1; $dirAttempt -le $dirAttempts; $dirAttempt++) {
            try {
                $request = New-FtpRequest -Uri $uri -Method ([System.Net.WebRequestMethods+Ftp]::MakeDirectory)
                $response = $request.GetResponse()
                $response.Close()
                Write-Host "Created Directory: $current" -ForegroundColor Gray
                [void]$script:ensuredDirs.Add($current)
                break
            }
            catch [System.Net.WebException] {
                $ftpResponse = $_.Exception.Response
                $statusCode = $null
                if ($ftpResponse) {
                    $statusCode = [int]$ftpResponse.StatusCode
                    $ftpResponse.Close()
                }

                if ($statusCode -eq [int][System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable) {
                    [void]$script:ensuredDirs.Add($current)
                    break
                }
                if (Test-RemoteDirectoryExists -DirectoryPath $current) {
                    [void]$script:ensuredDirs.Add($current)
                    break
                }
                if ($dirAttempt -lt $dirAttempts) {
                    Write-Warning "Transient error ensuring directory '$current' (attempt $dirAttempt/$dirAttempts): $($_.Exception.Message) - retrying"
                    Start-Sleep -Seconds (3 * $dirAttempt)
                    continue
                }
                throw "Failed to create remote directory '$current': $($_.Exception.Message)"
            }
        }
    }
    [void]$script:ensuredDirs.Add($DirectoryPath)
}

function Upload-File {
    param(
        [string]$SourceFile,
        [string]$RelativePath
    )

    $remoteFilePath = "$RemotePath/$RelativePath".Replace('\', '/')
    while ($remoteFilePath.Contains("//")) { $remoteFilePath = $remoteFilePath.Replace("//", "/") }
    $remoteFilePath = $remoteFilePath.TrimStart('/')

    $remoteDirectory = (Split-Path $remoteFilePath -Parent).Replace('\', '/')
    $remoteUri = "ftp://$Server/$remoteFilePath"

    try {
        # Check size of remote file to skip if unchanged
        $request = New-FtpRequest -Uri $remoteUri -Method ([System.Net.WebRequestMethods+Ftp]::GetFileSize)
        $response = $request.GetResponse()
        $remoteSize = $response.ContentLength
        $response.Close()

        $localSize = (Get-Item $SourceFile).Length
        $shouldAlwaysUpload = $RelativePath.EndsWith(".html", [System.StringComparison]::OrdinalIgnoreCase) -or
                              $RelativePath.EndsWith(".htm", [System.StringComparison]::OrdinalIgnoreCase) -or
                              $RelativePath.EndsWith(".dll", [System.StringComparison]::OrdinalIgnoreCase) -or
                              $RelativePath.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase) -or
                              $RelativePath.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)

        if (-not $shouldAlwaysUpload -and $remoteSize -eq $localSize) {
            Write-Host "Skipped (Size Match): $RelativePath" -ForegroundColor Gray
            return
        }
    }
    catch {
        # File doesn't exist, proceed with upload
    }

    Ensure-RemoteDirectory -DirectoryPath $remoteDirectory

    if ($DryRun) {
        Write-Host "[DryRun] Upload: $RelativePath"
        return
    }

    if (-not (Test-Path $SourceFile)) {
        return
    }

    $fileBytes = [System.IO.File]::ReadAllBytes($SourceFile)
    $maxAttempts = 5

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $request = New-FtpRequest -Uri $remoteUri -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile)
            $request.ContentLength = $fileBytes.Length

            $stream = $request.GetRequestStream()
            $stream.Write($fileBytes, 0, $fileBytes.Length)
            $stream.Close()

            $response = $request.GetResponse()
            $response.Close()

            # This server has shown a "ghost success" pattern: the STOR command
            # returns a clean success response but the file is later missing or
            # truncated (seen twice - a core .exe and a managed .dll both vanished
            # after being reported "Uploaded" with no error). Never trust the FTP
            # response alone for files that matter - verify the byte count landed.
            Start-Sleep -Milliseconds 300
            $verifyOk = $false
            try {
                $verifyRequest = New-FtpRequest -Uri $remoteUri -Method ([System.Net.WebRequestMethods+Ftp]::GetFileSize)
                $verifyResponse = $verifyRequest.GetResponse()
                $remoteSize = $verifyResponse.ContentLength
                $verifyResponse.Close()
                $verifyOk = ($remoteSize -eq $fileBytes.Length)
            }
            catch {
                $verifyOk = $false
            }

            if ($verifyOk) {
                Write-Host "Uploaded: $RelativePath"
                return
            }

            if ($attempt -lt $maxAttempts) {
                Write-Warning "Post-upload verification failed for '$RelativePath' (server accepted the write but the file is missing/wrong size afterward) - retrying"
                Start-Sleep -Seconds (2 * $attempt)
                continue
            }
            throw "Upload failed for '$RelativePath' -> '$remoteUri': server accepted the write $maxAttempts times but the file never verified correctly afterward (ghost-success pattern). This file is NOT reliably on the server - do not treat this run as successful."
        }
        catch [System.Net.WebException] {
            $statusCode = $null
            $ftpResponse = $_.Exception.Response
            if ($ftpResponse) {
                $statusCode = [int]$ftpResponse.StatusCode
                $ftpResponse.Close()
            }

            # 550 File Unavailable - try deleting the (likely half-written from a
            # prior dropped attempt) remote file and retrying, on EVERY attempt,
            # not just the first. Silently giving up on a 550 is NOT safe here:
            # this exact path once silently "skipped" a core runtime DLL, the
            # script exited 0, and the deployed app crashed on startup with a
            # missing-assembly error. Never skip essential files quietly -
            # exhaust retries, and if it still won't go, fail loudly instead.
            if ($statusCode -eq [int][System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable) {
                try {
                    $deleteRequest = New-FtpRequest -Uri $remoteUri -Method ([System.Net.WebRequestMethods+Ftp]::DeleteFile)
                    $deleteResponse = $deleteRequest.GetResponse()
                    $deleteResponse.Close()
                    Write-Host "Retrying after delete: $RelativePath"
                }
                catch {
                }
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds (3 * $attempt)
                    continue
                }
                throw "Upload failed for '$RelativePath' -> '$remoteUri': repeated 550 File Unavailable after $maxAttempts attempts (delete-and-retry did not resolve it). This file was NOT uploaded - do not treat this run as successful."
            }

            # Transient connection drop/timeout (no FTP status code, e.g. "connection
            # closed" / "operation timed out") - retry with backoff instead of failing
            # the whole run, since this link drops FTP data connections occasionally
            # under sustained sequential transfers.
            if ($attempt -lt $maxAttempts) {
                $delaySeconds = 3 * $attempt
                Write-Warning "Transient upload error for '$RelativePath' (attempt $attempt/$maxAttempts): $($_.Exception.Message) - retrying in ${delaySeconds}s"
                Start-Sleep -Seconds $delaySeconds
                continue
            }

            throw "Upload failed for '$RelativePath' -> '$remoteUri' after $maxAttempts attempts: $($_.Exception.Message)"
        }
        catch {
            if ($attempt -lt $maxAttempts) {
                $delaySeconds = 3 * $attempt
                Write-Warning "Transient upload error for '$RelativePath' (attempt $attempt/$maxAttempts): $($_.Exception.Message) - retrying in ${delaySeconds}s"
                Start-Sleep -Seconds $delaySeconds
                continue
            }
            throw "Upload failed for '$RelativePath' -> '$remoteUri' after $maxAttempts attempts: $($_.Exception.Message)"
        }
    }
}

$resolvedLocal = (Resolve-Path $LocalPath).Path
if (-not (Test-Path $resolvedLocal)) {
    throw "LocalPath not found: $LocalPath"
}

$files = Get-ChildItem -Path $resolvedLocal -Recurse -File | Sort-Object FullName

if (-not $files) {
    throw "No files found in LocalPath: $resolvedLocal"
}

$excluded = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $ExcludePaths) {
    if (-not [string]::IsNullOrWhiteSpace($entry)) {
        $normalized = $entry.Trim().TrimStart('.') -replace '^[\\/]+', ''
        [void]$excluded.Add($normalized.Replace('\', '/'))
    }
}

Write-Host "Local Base Path: $resolvedLocal"
Write-Host "Uploading $($files.Count) files from '$resolvedLocal' to 'ftp://$Server/$RemotePath'"
if ($DryRun) {
    Write-Host "DryRun is enabled. No remote changes will be made."
}

$uploaded = 0
$skipped = 0

foreach ($file in $files) {
    $relative = $file.FullName
    if ($relative.StartsWith($resolvedLocal, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring($resolvedLocal.Length).TrimStart('\').TrimStart('/')
    }
    $relative = $relative.Replace('\', '/')

    $shouldSkip = $false
    foreach ($ex in $excluded) {
        if ($relative.Equals($ex, [System.StringComparison]::OrdinalIgnoreCase) -or
            $relative.StartsWith("$ex/", [System.StringComparison]::OrdinalIgnoreCase)) {
            $shouldSkip = $true
            break
        }
    }

    if ($shouldSkip) {
        $skipped++
        Write-Host "Excluded: $relative"
        continue
    }

    Upload-File -SourceFile $file.FullName -RelativePath $relative
    $uploaded++
}

Write-Host "Upload complete. Uploaded/Checked: $uploaded, Excluded: $skipped"

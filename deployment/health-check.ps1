<#
.SYNOPSIS
    Post-deploy health checks with bounded retry - the app may still be
    starting up (cold ASP.NET Core start after app_offline.htm is removed,
    or the IIS process recycling), so a single immediate check is not
    trustworthy. Requires ftps.ps1 dot-sourced first (for Write-DeployLog).
#>

# Windows PowerShell 5.1 does not default to TLS 1.2 for Invoke-WebRequest
# (unlike PowerShell 7+) - against a host that only accepts modern TLS this
# surfaces as "The underlying connection was closed: An unexpected error
# occurred on a send", not a clear TLS error. Confirmed against the real
# host. -bor (not =) so this never downgrades whatever the process already
# supports.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Polls GET $Url expecting HTTP 200 + {status:"ok", release: $ExpectedRelease}.
# Checking the release, not just HTTP 200, matters: the OLD process can keep
# answering 200 for a few seconds while IIS is still recycling to the new
# one - a bare status check would report healthy before the new release is
# actually the one being served.
function Test-BackendHealth {
    param(
        [string]$Url,
        [string]$ExpectedRelease,
        [int]$TimeoutSeconds = 60,
        [int]$RetryIntervalSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 10 -UseBasicParsing
            if ($resp.StatusCode -eq 200) {
                $body = $resp.Content | ConvertFrom-Json
                if ($body.status -eq "ok") {
                    if (-not $ExpectedRelease -or $body.release -eq $ExpectedRelease) {
                        Write-DeployLog "Backend health check passed (release '$($body.release)')." "OK"
                        return $true
                    }
                    Write-DeployLog "Backend responding but still serving release '$($body.release)', waiting for '$ExpectedRelease'..." "WARN"
                }
                else {
                    Write-DeployLog "Backend health check returned unexpected status '$($body.status)'" "WARN"
                }
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    Write-DeployLog "Backend health check FAILED after ${TimeoutSeconds}s. Last error: $lastError" "ERROR"
    return $false
}

# Polls GET $Url expecting HTTP 200, non-offline-page content, and (when
# provided) that the HTML actually references the freshly-uploaded JS asset
# - proves the new index.html is live, not just that *some* page loads.
function Test-FrontendHealth {
    param(
        [string]$Url,
        [string]$ExpectedAssetMarker,
        [int]$TimeoutSeconds = 60,
        [int]$RetryIntervalSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 10 -UseBasicParsing
            if ($resp.StatusCode -eq 200) {
                # Matches the ASCII title in deployment/templates/app_offline.htm -
                # avoiding non-ASCII text here since Windows PowerShell 5.1 can
                # misdecode a .ps1 file that isn't saved with a UTF-8 BOM.
                $isOfflinePage = $resp.Content -match "EA Console Maintenance|app_offline"
                if (-not $isOfflinePage) {
                    if (-not $ExpectedAssetMarker -or $resp.Content -match [regex]::Escape($ExpectedAssetMarker)) {
                        Write-DeployLog "Frontend health check passed." "OK"
                        return $true
                    }
                    Write-DeployLog "Frontend loaded but doesn't reference the new asset yet, retrying..." "WARN"
                }
                else {
                    Write-DeployLog "Frontend still showing the maintenance page, retrying..." "WARN"
                }
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    Write-DeployLog "Frontend health check FAILED after ${TimeoutSeconds}s. Last error: $lastError" "ERROR"
    return $false
}

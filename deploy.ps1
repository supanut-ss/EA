<#
.SYNOPSIS
    Build + deploy EA Console (Frontend + Backend) as a single release, via
    Deploy-FtpSync.ps1 (manifest-based FTPS sync with locking).

.DESCRIPTION
    Frontend and Backend are built into ONE combined local release tree
    (frontend assets land in the backend's wwwroot) before anything is
    uploaded, and that whole tree is synced to the server as a single
    Deploy-FtpSync.ps1 transaction - so a failure partway through can never
    leave the site running an old Frontend against a new Backend or vice
    versa: either the sync commits (manifest updated) with both together,
    or it doesn't commit at all and the site keeps serving whatever it was
    already serving.

    Secrets (FTP + database + API key) are read from environment variables
    only - see the bottom of this file for the full list and an example of
    setting them for a single run.

.PARAMETER DryRun
    Builds normally (a real diff needs real build output) but passes
    -DryRun through to Deploy-FtpSync.ps1, so nothing on the server is
    touched - not even the maintenance page or the lock.
#>

[CmdletBinding()]
param(
    [string]$RemotePath = "ea.thaipesleague.com",
    [switch]$DryRun,
    [switch]$ForceUnlock
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot

function Write-Step { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 0. Secrets from environment (never hardcoded here - see README block below)
# ---------------------------------------------------------------------------
$Server        = $env:DEPLOY_FTP_SERVER
$Username      = $env:DEPLOY_FTP_USERNAME
$Password      = $env:DEPLOY_FTP_PASSWORD
$CertThumbprint = $env:DEPLOY_FTPS_THUMBPRINT
$DbConnStr     = $env:DEPLOY_DB_CONNECTION_STRING
$IngestApiKey  = $env:DEPLOY_INGEST_API_KEY
$CorsOrigin    = if ($env:DEPLOY_CORS_ORIGIN) { $env:DEPLOY_CORS_ORIGIN } else { "https://$RemotePath" }

if (-not $Server -or -not $Username -or -not $Password) {
    throw "Missing FTP credentials. Set DEPLOY_FTP_SERVER, DEPLOY_FTP_USERNAME, DEPLOY_FTP_PASSWORD as environment variables before running this script (see the comment block at the bottom of deploy.ps1)."
}

# The maintenance-page toggle below talks FTPS directly (outside
# Deploy-FtpSync.ps1, which pins its own certificate internally in its own
# process) - it needs the same pinning here or .NET's default strict
# validation rejects this host's self-signed Plesk certificate.
if (-not $CertThumbprint) {
    Write-Warning "DEPLOY_FTPS_THUMBPRINT not set - the maintenance-page FTPS calls will fail certificate validation against this host's self-signed certificate. See Deploy-FtpSync.ps1's header comment."
}
else {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
        param($sender, $certificate, $chain, $sslErrors)
        return ($certificate.GetCertHashString() -eq $CertThumbprint)
    }
}
if (-not $DbConnStr) {
    Write-Warning "DEPLOY_DB_CONNECTION_STRING not set - web.config's ConnectionStrings__EaConsole will be left unchanged. Fine if it's already correct on the server; the app will crash on startup otherwise."
}
if (-not $IngestApiKey) {
    Write-Warning "DEPLOY_INGEST_API_KEY not set - web.config's Ingest__ApiKey will be left unchanged."
}

# ---------------------------------------------------------------------------
# Release identity - used in the deployment lock so a stuck/competing deploy
# is identifiable at a glance.
# ---------------------------------------------------------------------------
$releaseId = "unknown"
try {
    $gitSha = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gitSha) {
        $dirty = (& git -C $repoRoot status --porcelain 2>$null)
        $releaseId = if ($dirty) { "$gitSha-dirty" } else { $gitSha }
    }
}
catch {
    Write-Warning "Could not resolve a git commit for this release - falling back to a timestamp id."
}
if ($releaseId -eq "unknown") {
    $releaseId = "local-" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
}
Write-Host "Release id: $releaseId" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Prepare local staging
# ---------------------------------------------------------------------------
if (Test-Path "$repoRoot\deploy") { Remove-Item -Path "$repoRoot\deploy" -Recurse -Force }
New-Item -Path "$repoRoot\deploy" -ItemType Directory | Out-Null

if (Test-Path "$repoRoot\Backend\EaConsole.Api\wwwroot") { Remove-Item -Path "$repoRoot\Backend\EaConsole.Api\wwwroot" -Recurse -Force }
New-Item -Path "$repoRoot\Backend\EaConsole.Api\wwwroot" -ItemType Directory | Out-Null

# ---------------------------------------------------------------------------
# 2. Build Frontend
# ---------------------------------------------------------------------------
Write-Step "1. Building Frontend..."
Set-Location "$repoRoot\Frontend"
if (-not (Test-Path "$repoRoot\Frontend\node_modules")) {
    Write-Host "node_modules missing - running npm install first..." -ForegroundColor Yellow
    npm install
    if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
}
npm run build
if ($LASTEXITCODE -ne 0) { throw "Frontend build failed" }

Write-Host "Copying built frontend into Backend/EaConsole.Api/wwwroot..." -ForegroundColor Yellow
Copy-Item -Path "$repoRoot\Frontend\dist\*" -Destination "$repoRoot\Backend\EaConsole.Api\wwwroot" -Recurse -Force

# ---------------------------------------------------------------------------
# 3. Build Backend (win-x86 self-contained - required by this host's 32-bit
#    IIS app pool; do not "fix" this to win-x64, it has been verified wrong)
# ---------------------------------------------------------------------------
Write-Step "2. Publishing Backend (win-x86)..."
Set-Location "$repoRoot\Backend\EaConsole.Api"
dotnet publish -c Release -r win-x86 --self-contained true -o "$repoRoot\deploy\backend"
if ($LASTEXITCODE -ne 0) { throw "Backend publish failed" }

# ---------------------------------------------------------------------------
# 3b. Patch web.config with runtime secrets (never committed - deploy\ is
#     gitignored and regenerated fresh every run)
# ---------------------------------------------------------------------------
Write-Step "2b. Patching web.config environment variables..."
$webConfigPath = "$repoRoot\deploy\backend\web.config"
if (-not (Test-Path $webConfigPath)) { throw "web.config not found at $webConfigPath - did the publish step change output shape?" }

[xml]$webConfig = Get-Content $webConfigPath
$aspNetCoreNode = $webConfig.configuration.location.'system.webServer'.aspNetCore

function Set-WebConfigEnvVar {
    param($XmlDoc, $AspNetCoreNode, [string]$Name, [string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        Write-Warning "  -> $Name not provided, leaving web.config unchanged for this variable"
        return
    }
    $envVarsNode = $AspNetCoreNode.environmentVariables
    if (-not $envVarsNode) {
        $envVarsNode = $XmlDoc.CreateElement("environmentVariables")
        [void]$AspNetCoreNode.AppendChild($envVarsNode)
    }
    $existing = $envVarsNode.environmentVariable | Where-Object { $_.name -eq $Name }
    if ($existing) { $existing.value = $Value }
    else {
        $newVar = $XmlDoc.CreateElement("environmentVariable")
        $newVar.SetAttribute("name", $Name)
        $newVar.SetAttribute("value", $Value)
        [void]$envVarsNode.AppendChild($newVar)
    }
    Write-Host "  -> Set $Name" -ForegroundColor Gray
}

Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "ASPNETCORE_ENVIRONMENT" -Value "Production"
Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "ConnectionStrings__EaConsole" -Value $DbConnStr
Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "Cors__AllowedOrigins__0" -Value $CorsOrigin
Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "Ingest__ApiKey" -Value $IngestApiKey
$webConfig.Save($webConfigPath)

# ---------------------------------------------------------------------------
# 4. Maintenance page content (uploaded directly, outside the manifest - it
#    is a transient control file, not a versioned release artifact)
# ---------------------------------------------------------------------------
$appOfflineContent = @"
<!DOCTYPE html>
<html lang="th-TH">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>EA Console Maintenance</title>
    <style>
        body { font-family: 'Segoe UI', Roboto, sans-serif; background: #0b0f19; color: white; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; text-align: center; }
        .card { background: rgba(255,255,255,0.03); padding: 3rem; border-radius: 32px; border: 1px solid rgba(255,255,255,0.08); backdrop-filter: blur(20px); max-width: 450px; }
        h1 { margin: 0; font-size: 1.75rem; font-weight: 800; color: #f3f4f6; }
        p { opacity: 0.7; margin-top: 1rem; font-size: 1rem; line-height: 1.6; }
        .accent { color: #6366f1; font-weight: 800; }
    </style>
</head>
<body>
    <div class="card">
        <h1><span class="accent">EA Console</span> กำลังอัปเดตระบบ</h1>
        <p>เรากำลังอัปเกรดระบบ backend/dashboard<br>กรุณารอสักครู่ (ประมาณ 3-5 นาที)</p>
    </div>
</body>
</html>
"@
$tempAppOfflinePath = "$repoRoot\deploy\app_offline.htm"
Set-Content -Path $tempAppOfflinePath -Value $appOfflineContent -Force -Encoding utf8

function New-MaintFtpRequest {
    param([string]$Uri, [string]$Method)
    $req = [System.Net.FtpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
    $req.UsePassive = $true
    $req.EnableSsl = $true
    return $req
}

function Set-MaintenanceMode {
    param([bool]$Enabled)
    $uri = "ftp://$Server/$RemotePath/app_offline.htm"
    if ($Enabled) {
        $bytes = [System.IO.File]::ReadAllBytes($tempAppOfflinePath)
        $req = New-MaintFtpRequest -Uri $uri -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        $resp = $req.GetResponse(); $resp.Close()
        Write-Host "Maintenance page is live." -ForegroundColor Yellow
    }
    else {
        try {
            $req = New-MaintFtpRequest -Uri $uri -Method ([System.Net.WebRequestMethods+Ftp]::DeleteFile)
            $resp = $req.GetResponse(); $resp.Close()
            Write-Host "app_offline.htm removed. Website is live!" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not remove app_offline.htm automatically ($($_.Exception.Message)). Please delete it via FTP."
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Deploy
# ---------------------------------------------------------------------------
$pwsh = if (Get-Command powershell -ErrorAction SilentlyContinue) { "powershell" } else { "pwsh" }
$maintenanceOn = $false

try {
    if (-not $DryRun) {
        Write-Step "3. Taking app offline..."
        Set-MaintenanceMode -Enabled $true
        $maintenanceOn = $true
        Write-Host "Waiting 15 seconds for app pool to release files..."
        Start-Sleep -Seconds 15
    }
    else {
        Write-Step "3. [DryRun] Skipping maintenance page toggle."
    }

    Write-Step "4. Syncing release (Frontend + Backend as one transaction)..."
    $syncArgs = @(
        "-ExecutionPolicy", "Bypass", "-File", "$repoRoot\Deploy-FtpSync.ps1",
        "-Server", $Server, "-Username", $Username, "-Password", $Password,
        "-LocalPath", "$repoRoot\deploy\backend",
        "-RemotePath", $RemotePath,
        "-ReleaseId", $releaseId
    )
    if ($DryRun) { $syncArgs += "-DryRun" }
    if ($ForceUnlock) { $syncArgs += "-ForceUnlock" }

    & $pwsh @syncArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Deploy-FtpSync.ps1 failed or refused to proceed (exit $LASTEXITCODE). Site is LEFT IN MAINTENANCE MODE on purpose - do not treat this as a successful deploy. Investigate, then re-run."
    }

    if (-not $DryRun) {
        Write-Step "5. Bringing app back online..."
        Set-MaintenanceMode -Enabled $false
        $maintenanceOn = $false
    }

    Remove-Item $tempAppOfflinePath -Force -ErrorAction SilentlyContinue
    Set-Location $repoRoot
    Write-Host "--- Deployment Complete! (release $releaseId) ---" -ForegroundColor Cyan
}
catch {
    Set-Location $repoRoot
    Write-Host "--- Deployment FAILED: $($_.Exception.Message) ---" -ForegroundColor Red
    if ($maintenanceOn) {
        Write-Warning "Site remains in maintenance mode. Fix the issue and re-run deploy.ps1 (already-uploaded files will be skipped by the manifest), or bring it back online manually once you've verified the server state."
    }
    exit 1
}

<#
Environment variables this script reads (set them in your shell before
running - never commit real values):

  DEPLOY_FTP_SERVER               e.g. 94.237.76.153
  DEPLOY_FTP_USERNAME             FTP account username
  DEPLOY_FTP_PASSWORD             FTP account password
  DEPLOY_FTP_PROTOCOL             "FTPS" (default) or "FTP"
  DEPLOY_FTPS_THUMBPRINT          pinned server certificate thumbprint (see
                                   Deploy-FtpSync.ps1 header comment - first
                                   run without this set will print the
                                   observed thumbprint for you to verify and
                                   pin)
  DEPLOY_DB_CONNECTION_STRING     backend MySQL connection string
  DEPLOY_INGEST_API_KEY           backend Ingest:ApiKey value
  DEPLOY_CORS_ORIGIN              optional, defaults to https://<RemotePath>

Example (current PowerShell session only, not persisted):

  $env:DEPLOY_FTP_SERVER = "94.237.76.153"
  $env:DEPLOY_FTP_USERNAME = "thaipes"
  $env:DEPLOY_FTP_PASSWORD = "********"
  $env:DEPLOY_FTPS_THUMBPRINT = "68426C5007B17E76BCBDA1F644A68D7A9B9B80C8"
  $env:DEPLOY_DB_CONNECTION_STRING = "Server=localhost;Port=3306;Database=thaipes_ea;User=thaipes_sa;Password=********;"
  $env:DEPLOY_INGEST_API_KEY = "********"

  .\deploy.ps1 -DryRun          # preview only, touches nothing remote
  .\deploy.ps1                  # real deploy
  .\deploy.ps1 -ForceUnlock     # real deploy, override a confirmed-stale lock
#>

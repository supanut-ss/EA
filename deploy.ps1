param(
    [string]$Server = "94.237.76.153",
    [string]$Username = "thaipes",
    [string]$Password = "Ws7#3es2",
    [string]$RemotePath = "ea.thaipesleague.com",

    # Backend runtime secrets - NOT stored in git (appsettings.json only has
    # placeholders). Pass these explicitly every deploy, e.g.:
    #   .\deploy.ps1 -DbConnectionString "Server=...;Password=REAL;" -IngestApiKey "..."
    # Left blank, the corresponding web.config env var is left untouched -
    # the script warns loudly instead of silently deploying with bad config.
    [string]$DbConnectionString = "",
    [string]$CorsOrigin = "https://$RemotePath",
    [string]$IngestApiKey = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot

# 0. Preparation
if (Test-Path "$repoRoot\deploy") { Remove-Item -Path "$repoRoot\deploy" -Recurse -Force }
New-Item -Path "$repoRoot\deploy" -ItemType Directory | Out-Null

if (Test-Path "$repoRoot\Backend\EaConsole.Api\wwwroot") { Remove-Item -Path "$repoRoot\Backend\EaConsole.Api\wwwroot" -Recurse -Force }
New-Item -Path "$repoRoot\Backend\EaConsole.Api\wwwroot" -ItemType Directory | Out-Null

# 1. Build Frontend
Write-Host "1. Building Frontend..." -ForegroundColor Yellow
Set-Location "$repoRoot\Frontend"
if (-not (Test-Path "$repoRoot\Frontend\node_modules")) {
    Write-Host "node_modules missing - running npm install first..." -ForegroundColor Yellow
    npm install
    if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
}
npm run build
if ($LASTEXITCODE -ne 0) { throw "Frontend build failed" }

# Copy built frontend assets to wwwroot of backend (served via
# app.UseDefaultFiles()/UseStaticFiles() added in Program.cs)
Write-Host "Copying built frontend into Backend/EaConsole.Api/wwwroot..." -ForegroundColor Yellow
Copy-Item -Path "$repoRoot\Frontend\dist\*" -Destination "$repoRoot\Backend\EaConsole.Api\wwwroot" -Recurse -Force

# 2. Publish Backend (win-x86 self-contained for shared IIS hosting compatibility)
Write-Host "2. Publishing Backend (win-x86)..." -ForegroundColor Yellow
Set-Location "$repoRoot\Backend\EaConsole.Api"
dotnet publish -c Release -r win-x86 --self-contained true -o "$repoRoot\deploy\backend"
if ($LASTEXITCODE -ne 0) { throw "Backend publish failed" }

# 2b. Patch web.config with runtime secrets (never committed to git - this
# file only exists inside the untracked deploy/ output, generated fresh
# every run from the -DbConnectionString/-CorsOrigin/-IngestApiKey params)
Write-Host "2b. Patching web.config environment variables..." -ForegroundColor Yellow
$webConfigPath = "$repoRoot\deploy\backend\web.config"
if (-not (Test-Path $webConfigPath)) {
    throw "web.config not found at $webConfigPath - did the publish step change output shape?"
}

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
    if ($existing) {
        $existing.value = $Value
    }
    else {
        $newVar = $XmlDoc.CreateElement("environmentVariable")
        $newVar.SetAttribute("name", $Name)
        $newVar.SetAttribute("value", $Value)
        [void]$envVarsNode.AppendChild($newVar)
    }
    Write-Host "  -> Set $Name" -ForegroundColor Gray
}

Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "ASPNETCORE_ENVIRONMENT" -Value "Production"
Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "ConnectionStrings__EaConsole" -Value $DbConnectionString
Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "Cors__AllowedOrigins__0" -Value $CorsOrigin
Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "Ingest__ApiKey" -Value $IngestApiKey

$webConfig.Save($webConfigPath)

if ([string]::IsNullOrEmpty($DbConnectionString)) {
    Write-Warning "DbConnectionString was not provided - the deployed backend will crash on startup until web.config (or IIS) has a real ConnectionStrings__EaConsole value. Re-run with -DbConnectionString to fix, or edit web.config on the server directly."
}
if ([string]::IsNullOrEmpty($IngestApiKey)) {
    Write-Warning "IngestApiKey was not provided - /api/ingest/* will stay open with no authentication once live. Fine for an initial smoke test, but set -IngestApiKey before pointing a real EA at this before going live."
}

# 3. Create maintenance page
Write-Host "3. Creating maintenance page..." -ForegroundColor Yellow
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
Set-Content -Path $tempAppOfflinePath -Value $appOfflineContent -Force

# 4. Uploading...
$pwsh = if (Get-Command powershell -ErrorAction SilentlyContinue) { "powershell" } else { "pwsh" }

Write-Host "4. Taking app offline (Uploading app_offline.htm)..." -ForegroundColor Yellow
& $pwsh -ExecutionPolicy Bypass -File "$repoRoot\upload-ftp.ps1" `
    -Server $Server -Username $Username -Password $Password `
    -LocalPath "$repoRoot\deploy" -RemotePath $RemotePath -ExcludePaths @("backend")
if ($LASTEXITCODE -ne 0) { throw "Uploading app_offline.htm failed (exit $LASTEXITCODE) - site state on server is unknown, check manually before retrying." }

Write-Host "App is offline. Waiting 15 seconds for app pool to release files..."
Start-Sleep -Seconds 15

Write-Host "5. Uploading application files (Integrated Frontend + Backend)..." -ForegroundColor Yellow
& $pwsh -ExecutionPolicy Bypass -File "$repoRoot\upload-ftp.ps1" `
    -Server $Server -Username $Username -Password $Password `
    -LocalPath "$repoRoot\deploy\backend" -RemotePath $RemotePath
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Uploading application files failed (exit $LASTEXITCODE). Site is LEFT IN MAINTENANCE MODE on purpose - do not bring it online with a partial deploy. Fix the issue and re-run deploy.ps1 (already-uploaded files will just be re-sent) or upload the rest manually, then bring the site back online yourself."
    exit 1
}

# 6. Bring App Online
Write-Host "6. Bringing app back online..." -ForegroundColor Yellow
$delReq = [System.Net.FtpWebRequest]::Create("ftp://$Server/$RemotePath/app_offline.htm")
$delReq.Method = [System.Net.WebRequestMethods+Ftp]::DeleteFile
$delReq.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
$delReq.UsePassive = $true
try {
    $delResp = $delReq.GetResponse()
    $delResp.Close()
    Write-Host "app_offline.htm removed. Website is live!" -ForegroundColor Green
} catch {
    Write-Warning "Could not remove app_offline.htm automatically. Please delete it via FTP."
}

Remove-Item $tempAppOfflinePath -Force -ErrorAction SilentlyContinue
Set-Location $repoRoot
Write-Host "--- Deployment Complete! ---" -ForegroundColor Cyan

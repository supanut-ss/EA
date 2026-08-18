<#
    Shared single-host deployment workflow for EA Console.

    This file is tracked and must never contain credentials. Create the local,
    Git-ignored deploy-single-host.ps1 from deploy-single-host.example.ps1 and
    pass all machine-specific values into this script as parameters.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Password,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RemotePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DbConnStr,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$IngestApiKey,

    [string]$CorsOrigin = "",
    [ValidateRange(0, 600)]
    [int]$OfflineDrainSeconds = 45,
    [ValidateRange(1, 100)]
    [int]$HealthCheckAttempts = 12,
    [ValidateRange(1, 300)]
    [int]$HealthCheckDelaySeconds = 5
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($CorsOrigin)) {
    $CorsOrigin = "https://$RemotePath"
}

# 0. Preparation
if (Test-Path "$repoRoot\deploy") { Remove-Item -Path "$repoRoot\deploy" -Recurse -Force }
New-Item -Path "$repoRoot\deploy" -ItemType Directory | Out-Null

if (Test-Path "$repoRoot\Backend\EaConsole.Api\wwwroot") { Remove-Item -Path "$repoRoot\Backend\EaConsole.Api\wwwroot" -Recurse -Force }
New-Item -Path "$repoRoot\Backend\EaConsole.Api\wwwroot" -ItemType Directory | Out-Null

# 1. Build Frontend (vite outputs to Frontend/dist, then copied into
#    Backend/EaConsole.Api/wwwroot so it's served as static files)
Write-Host "1. Building Frontend..." -ForegroundColor Yellow
Set-Location "$repoRoot\Frontend"
npm run build
if ($LASTEXITCODE -ne 0) { throw "Frontend build failed" }
Copy-Item -Path "$repoRoot\Frontend\dist\*" -Destination "$repoRoot\Backend\EaConsole.Api\wwwroot" -Recurse -Force

# 2. Publish Backend (win-x86 - required by this host's 32-bit IIS app pool)
Write-Host "2. Publishing Backend (win-x86)..." -ForegroundColor Yellow
Set-Location "$repoRoot\Backend\EaConsole.Api"
dotnet publish -c Release -r win-x86 --self-contained true -o "$repoRoot\deploy\backend"
if ($LASTEXITCODE -ne 0) { throw "Backend publish failed" }

# 2b. Patch web.config with runtime secrets (backend crashes on start without
#     a real DB connection string - see Backend/DEPLOYMENT.md)
Write-Host "2b. Patching web.config environment variables..." -ForegroundColor Yellow
$webConfigPath = "$repoRoot\deploy\backend\web.config"
if (-not (Test-Path $webConfigPath)) { throw "web.config not found at $webConfigPath - did the publish step change output shape?" }

[xml]$webConfig = Get-Content $webConfigPath
$aspNetCoreNode = $webConfig.configuration.location.'system.webServer'.aspNetCore
$envVarsNode = $aspNetCoreNode.environmentVariables
if (-not $envVarsNode) {
    $envVarsNode = $webConfig.CreateElement("environmentVariables")
    [void]$aspNetCoreNode.AppendChild($envVarsNode)
}
function Set-WebConfigEnvVar {
    param([string]$Name, [string]$Value)
    $existing = $envVarsNode.environmentVariable | Where-Object { $_.name -eq $Name }
    if ($existing) { $existing.value = $Value }
    else {
        $newVar = $webConfig.CreateElement("environmentVariable")
        $newVar.SetAttribute("name", $Name)
        $newVar.SetAttribute("value", $Value)
        [void]$envVarsNode.AppendChild($newVar)
    }
}
Set-WebConfigEnvVar -Name "ASPNETCORE_ENVIRONMENT" -Value "Production"
Set-WebConfigEnvVar -Name "ConnectionStrings__EaConsole" -Value $DbConnStr
Set-WebConfigEnvVar -Name "Cors__AllowedOrigins__0" -Value $CorsOrigin
Set-WebConfigEnvVar -Name "Ingest__ApiKey" -Value $IngestApiKey

# Preserve startup failures in deploy/backend/logs/ instead of returning a
# context-free HTTP 500 from IIS.
$aspNetCoreNode.SetAttribute("stdoutLogEnabled", "true")
$aspNetCoreNode.SetAttribute("hostingModel", "outofprocess")
$webConfig.Save($webConfigPath)

# Out-of-process hosting ensures the application child process exits while the
# maintenance file is present, which releases managed runtime files more
# reliably than keeping them loaded inside w3wp. The self-contained app still
# resolves Microsoft.AspNetCore.Server.IIS.dll during WebApplication startup;
# upload-ftp.ps1 retains it and uses its verified fallback when required.

# ANCM only writes into logs/ if the directory already exists on the server.
New-Item -Path "$repoRoot\deploy\backend\logs" -ItemType Directory -Force | Out-Null
Set-Content -Path "$repoRoot\deploy\backend\logs\.keep" -Value "placeholder so FTP sync creates this directory" -Force

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

# 4. Uploading
$pwsh = if (Get-Command powershell -ErrorAction SilentlyContinue) { "powershell" } else { "pwsh" }
$manifestPath = "$repoRoot\.deploy-cache\single-host-manifest.json"

function Assert-UploadSucceeded {
    param([string]$Stage, [int]$ExitCode)

    if ($ExitCode -ne 0) {
        throw "$Stage failed because upload-ftp.ps1 exited with code $ExitCode. The site is being kept in maintenance mode; fix the upload error and rerun this script."
    }
}

$deploymentSucceeded = $false

try {
    Write-Host "4. Taking app offline (Uploading app_offline.htm)..." -ForegroundColor Yellow
    & $pwsh -ExecutionPolicy Bypass -File "$repoRoot\upload-ftp.ps1" `
        -Server $Server -Username $Username -Password $Password `
        -LocalPath "$repoRoot\deploy" -RemotePath $RemotePath -ExcludePaths @("backend")
    Assert-UploadSucceeded -Stage "Taking the application offline" -ExitCode $LASTEXITCODE

    Write-Host "App is offline. Waiting $OfflineDrainSeconds seconds for the IIS worker to release deployed files..."
    Start-Sleep -Seconds $OfflineDrainSeconds

    Write-Host "5. Uploading application files (Integrated Frontend + Backend)..." -ForegroundColor Yellow
    & $pwsh -ExecutionPolicy Bypass -File "$repoRoot\upload-ftp.ps1" `
        -Server $Server -Username $Username -Password $Password `
        -LocalPath "$repoRoot\deploy\backend" -RemotePath $RemotePath `
        -ManifestPath $manifestPath -PruneRemoteRootFiles
    Assert-UploadSucceeded -Stage "Uploading application files" -ExitCode $LASTEXITCODE

    # 6. Bring App Online only after every application file was confirmed.
    Write-Host "6. Bringing app back online..." -ForegroundColor Yellow
    $delReq = [System.Net.FtpWebRequest]::Create("ftp://$Server/$RemotePath/app_offline.htm")
    $delReq.Method = [System.Net.WebRequestMethods+Ftp]::DeleteFile
    $delReq.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
    $delReq.UsePassive = $true
    $delResp = $delReq.GetResponse()
    $delResp.Close()
    Write-Host "app_offline.htm removed. Waiting for the application health check..." -ForegroundColor Gray

    $healthUrl = "https://$RemotePath/health"
    $healthOk = $false
    $lastHealthResult = "no response"
    for ($healthAttempt = 1; $healthAttempt -le $HealthCheckAttempts; $healthAttempt++) {
        try {
            $healthResponse = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 20
            $lastHealthResult = "HTTP $([int]$healthResponse.StatusCode)"
            if ([int]$healthResponse.StatusCode -eq 200) {
                $healthOk = $true
                break
            }
        }
        catch {
            if ($_.Exception.Response) {
                $lastHealthResult = "HTTP $([int]$_.Exception.Response.StatusCode)"
            }
            else {
                $lastHealthResult = $_.Exception.Message
            }
        }

        if ($healthAttempt -lt $HealthCheckAttempts) {
            Write-Host "Health check not ready ($lastHealthResult), attempt $healthAttempt/$HealthCheckAttempts..." -ForegroundColor Gray
            Start-Sleep -Seconds $HealthCheckDelaySeconds
        }
    }

    if (-not $healthOk) {
        Write-Warning "Application failed its post-deploy health check ($lastHealthResult). Restoring maintenance mode before failing the deployment."
        & $pwsh -ExecutionPolicy Bypass -File "$repoRoot\upload-ftp.ps1" `
            -Server $Server -Username $Username -Password $Password `
            -LocalPath "$repoRoot\deploy" -RemotePath $RemotePath -ExcludePaths @("backend")
        Assert-UploadSucceeded -Stage "Restoring maintenance mode after a failed health check" -ExitCode $LASTEXITCODE
        throw "Application upload completed, but $healthUrl did not return HTTP 200 after $HealthCheckAttempts attempts (last result: $lastHealthResult). Maintenance mode was restored; this deployment is not successful."
    }

    $deploymentSucceeded = $true
    Write-Host "Health check passed. Website is live!" -ForegroundColor Green
}
catch {
    Write-Host "Deployment stopped: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    Remove-Item $tempAppOfflinePath -Force -ErrorAction SilentlyContinue
    Set-Location $repoRoot
}

if ($deploymentSucceeded) {
    Write-Host "--- Deployment Complete! ---" -ForegroundColor Cyan
}

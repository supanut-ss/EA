<#
.SYNOPSIS
    Build Frontend + Backend into ONE combined local release tree, the same
    "single release tree" approach the original deploy.ps1 used (frontend
    dist copied into the backend's own wwwroot, which `dotnet publish` then
    picks up automatically as part of its own output) - because that's how
    this app is actually hosted: Program.cs serves the frontend straight out
    of the backend's wwwroot via UseStaticFiles(), there's no separate
    frontend web root on the server.
#>

function Invoke-BuildFrontend {
    param([string]$RepoRoot)
    $frontendDir = Join-Path $RepoRoot "Frontend"
    $wwwrootDir  = Join-Path $RepoRoot "Backend\EaConsole.Api\wwwroot"

    Write-DeployLog "Building Frontend..."
    Push-Location $frontendDir
    try {
        if (-not (Test-Path (Join-Path $frontendDir "node_modules"))) {
            Write-DeployLog "node_modules missing - running npm install first..." "WARN"
            npm install
            if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
        }
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "Frontend build failed" }
    }
    finally { Pop-Location }

    if (Test-Path $wwwrootDir) { Remove-Item -Path $wwwrootDir -Recurse -Force }
    New-Item -Path $wwwrootDir -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $frontendDir "dist\*") -Destination $wwwrootDir -Recurse -Force
    Write-DeployLog "Frontend build copied into Backend/EaConsole.Api/wwwroot." "OK"
}

# Publishes the backend (which now includes the freshly-copied wwwroot as
# part of its own publish output) to $OutputRoot, then patches web.config
# with runtime secrets - same env vars/behavior as the original deploy.ps1,
# plus Release__Id so the new /health endpoint can report it.
function Invoke-BuildBackend {
    param(
        [string]$RepoRoot,
        [string]$OutputRoot,
        [string]$ReleaseId,
        [string]$DbConnStr,
        [string]$IngestApiKey,
        [string]$CorsOrigin
    )

    if (Test-Path $OutputRoot) { Remove-Item -Path $OutputRoot -Recurse -Force }
    New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null

    Write-DeployLog "Publishing Backend (win-x86, self-contained)..."
    Push-Location (Join-Path $RepoRoot "Backend\EaConsole.Api")
    try {
        # win-x86 is required by this host's 32-bit IIS app pool - do not
        # "fix" this to win-x64, it has been verified wrong (see original
        # deploy.ps1's comment history).
        dotnet publish -c Release -r win-x86 --self-contained true -o "$OutputRoot"
        if ($LASTEXITCODE -ne 0) { throw "Backend publish failed" }
    }
    finally { Pop-Location }

    Set-WebConfigSecrets -WebConfigPath (Join-Path $OutputRoot "web.config") `
        -ReleaseId $ReleaseId -DbConnStr $DbConnStr -IngestApiKey $IngestApiKey -CorsOrigin $CorsOrigin
}

function Set-WebConfigEnvVar {
    param($XmlDoc, $AspNetCoreNode, [string]$Name, [string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        Write-DeployLog "  -> $Name not provided, leaving web.config unchanged for this variable" "WARN"
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
    Write-DeployLog "  -> Set $Name"
}

function Set-WebConfigSecrets {
    param([string]$WebConfigPath, [string]$ReleaseId, [string]$DbConnStr, [string]$IngestApiKey, [string]$CorsOrigin)

    if (-not (Test-Path $WebConfigPath)) { throw "web.config not found at $WebConfigPath - did the publish step change output shape?" }

    Write-DeployLog "Patching web.config environment variables..."
    [xml]$webConfig = Get-Content $WebConfigPath
    $aspNetCoreNode = $webConfig.configuration.location.'system.webServer'.aspNetCore

    Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "ASPNETCORE_ENVIRONMENT" -Value "Production"
    Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "Release__Id" -Value $ReleaseId
    Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "ConnectionStrings__EaConsole" -Value $DbConnStr
    Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "Cors__AllowedOrigins__0" -Value $CorsOrigin
    Set-WebConfigEnvVar -XmlDoc $webConfig -AspNetCoreNode $aspNetCoreNode -Name "Ingest__ApiKey" -Value $IngestApiKey
    $webConfig.Save($WebConfigPath)
}

function Get-ReleaseId {
    param([string]$RepoRoot)
    $releaseId = "unknown"
    try {
        $gitSha = (& git -C $RepoRoot rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitSha) {
            $dirty = (& git -C $RepoRoot status --porcelain 2>$null)
            $releaseId = if ($dirty) { "$gitSha-dirty" } else { $gitSha }
        }
    }
    catch {
        Write-DeployLog "Could not resolve a git commit for this release - falling back to a timestamp id." "WARN"
    }
    if ($releaseId -eq "unknown") {
        $releaseId = "local-" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    }
    return $releaseId
}

function Get-GitCommit {
    param([string]$RepoRoot)
    try {
        $sha = (& git -C $RepoRoot rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $sha) { return $sha }
    }
    catch {}
    return "unknown"
}

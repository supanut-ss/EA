<#
    Copy this file to deploy-single-host.ps1, then provide the six required
    EA_DEPLOY_* environment variables on that machine. deploy-single-host.ps1
    is Git-ignored; never put real credentials in this example file.
#>

$ErrorActionPreference = "Stop"

$requiredEnvironmentVariables = @(
    "EA_DEPLOY_FTP_SERVER",
    "EA_DEPLOY_FTP_USERNAME",
    "EA_DEPLOY_FTP_PASSWORD",
    "EA_DEPLOY_REMOTE_PATH",
    "EA_DEPLOY_DB_CONNECTION_STRING",
    "EA_DEPLOY_INGEST_API_KEY"
)

$missingVariables = @(
    foreach ($name in $requiredEnvironmentVariables) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            $name
        }
    }
)

if ($missingVariables.Count -gt 0) {
    throw "Missing required deployment environment variables: $($missingVariables -join ', ')"
}

$deployParameters = @{
    Server       = $env:EA_DEPLOY_FTP_SERVER
    Username     = $env:EA_DEPLOY_FTP_USERNAME
    Password     = $env:EA_DEPLOY_FTP_PASSWORD
    RemotePath   = $env:EA_DEPLOY_REMOTE_PATH
    DbConnStr    = $env:EA_DEPLOY_DB_CONNECTION_STRING
    IngestApiKey = $env:EA_DEPLOY_INGEST_API_KEY
}

if (-not [string]::IsNullOrWhiteSpace($env:EA_DEPLOY_CORS_ORIGIN)) {
    $deployParameters.CorsOrigin = $env:EA_DEPLOY_CORS_ORIGIN
}

& "$PSScriptRoot\deploy-single-host.core.ps1" @deployParameters

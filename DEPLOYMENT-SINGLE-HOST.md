# Single-host deployment

The repository keeps deployment behavior and machine credentials separate:

- `deploy-single-host.core.ps1` is the shared, tracked deployment workflow.
- `deploy-single-host.example.ps1` is the tracked, secret-free local wrapper example.
- `deploy-single-host.ps1` is the Git-ignored wrapper used on each deployment machine.
- `upload-ftp.ps1` is the shared FTP uploader called by the core workflow.

## Set up a new machine

1. Install Node.js/npm and the .NET 8 SDK.
2. Copy the example wrapper:

   ```powershell
   Copy-Item .\deploy-single-host.example.ps1 .\deploy-single-host.ps1
   ```

3. Set the required environment variables for the current PowerShell session:

   ```powershell
   $env:EA_DEPLOY_FTP_SERVER = "ftp.example.com"
   $env:EA_DEPLOY_FTP_USERNAME = "your-ftp-user"
   $env:EA_DEPLOY_FTP_PASSWORD = "your-ftp-password"
   $env:EA_DEPLOY_REMOTE_PATH = "site.example.com"
   $env:EA_DEPLOY_DB_CONNECTION_STRING = "Server=...;Database=...;User=...;Password=...;"
   $env:EA_DEPLOY_INGEST_API_KEY = "your-ingest-api-key"
   ```

   `EA_DEPLOY_CORS_ORIGIN` is optional. When omitted, the core script uses
   `https://<EA_DEPLOY_REMOTE_PATH>`.

4. Run the local wrapper:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-single-host.ps1
   ```

Do not add real values to `deploy-single-host.example.ps1`, the core script, or
any other tracked file. The generated `deploy/` directory contains a patched
`web.config` with runtime secrets and is also Git-ignored.

## Success criteria

A deployment is successful only when the frontend and backend builds pass,
every required upload verifies, `app_offline.htm` is removed, and `/health`
returns HTTP 200. When upload or health verification fails, the script exits
non-zero and keeps or restores maintenance mode.

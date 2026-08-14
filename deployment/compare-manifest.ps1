<#
.SYNOPSIS
    Diffs a local SHA256 manifest against the remote one and builds a
    deployment plan. Requires create-manifest.ps1 dot-sourced first (for
    Test-ProtectedPath/Test-RuntimeSensitivePath).
#>

function Compare-DeployManifest {
    param(
        [System.Collections.Specialized.OrderedDictionary]$LocalManifest,
        $RemoteManifest,
        [string[]]$ProtectedPaths = @(),
        [string[]]$RuntimeSensitivePatterns = @(),
        [int]$DeleteSafetyLimitCount = 50,
        [double]$DeleteSafetyLimitPct = 20,
        [switch]$ApproveLargeDelete
    )

    $remoteFiles = @{}
    if ($RemoteManifest -and $RemoteManifest.files) {
        $RemoteManifest.files.PSObject.Properties | ForEach-Object { $remoteFiles[$_.Name] = $_.Value }
    }

    $upload = New-Object System.Collections.Generic.List[string]
    $skip = New-Object System.Collections.Generic.List[string]
    foreach ($path in $LocalManifest.Keys) {
        $localHash = $LocalManifest[$path].sha256
        if ($remoteFiles.ContainsKey($path) -and $remoteFiles[$path].sha256 -eq $localHash) {
            $skip.Add($path) | Out-Null
        }
        else {
            $upload.Add($path) | Out-Null
        }
    }

    # Delete candidates: must have existed in the OLD manifest (never touch
    # something the manifest never tracked), not be present locally anymore,
    # and not match a protected path.
    $delete = New-Object System.Collections.Generic.List[string]
    foreach ($path in $remoteFiles.Keys) {
        if ($LocalManifest.Contains($path)) { continue }
        if (Test-ProtectedPath -RelativePath $path -Patterns $ProtectedPaths) { continue }
        $delete.Add($path) | Out-Null
    }

    $totalManaged = [Math]::Max($LocalManifest.Count, 1)
    $deletePct = [Math]::Round(($delete.Count / $totalManaged) * 100, 1)
    $deleteSafetyOk = $true
    if (-not $ApproveLargeDelete -and $RemoteManifest -and ($delete.Count -gt $DeleteSafetyLimitCount -or $deletePct -gt $DeleteSafetyLimitPct)) {
        $deleteSafetyOk = $false
    }

    $runtimeSensitiveUpload = @($upload | Where-Object { Test-RuntimeSensitivePath -RelativePath $_ -Patterns $RuntimeSensitivePatterns })

    $totalUploadBytes = 0
    foreach ($p in $upload) { $totalUploadBytes += [int64]$LocalManifest[$p].size }

    return [pscustomobject]@{
        Upload                 = @($upload)
        Delete                 = @($delete)
        Skip                   = @($skip)
        RuntimeSensitiveUpload = $runtimeSensitiveUpload
        HasRuntimeChanges      = ($runtimeSensitiveUpload.Count -gt 0)
        TotalUploadBytes       = $totalUploadBytes
        DeleteSafetyOk         = $deleteSafetyOk
        DeletePct              = $deletePct
        HasNoChanges           = ($upload.Count -eq 0 -and $delete.Count -eq 0)
        IsFirstDeploy          = ($null -eq $RemoteManifest)
    }
}

# Splits a plan's Upload/Delete lists into "under wwwroot" (frontend static
# assets, served straight out of the backend's own wwwroot per Program.cs)
# vs everything else (backend runtime/content files) - this project has one
# combined release tree, not physically separate frontend/backend roots.
function Split-DeployPlanByArea {
    param($Plan, [string]$WwwrootRelativePath)
    $prefix = $WwwrootRelativePath.Trim('/') + "/"
    return [pscustomobject]@{
        FrontendUpload = @($Plan.Upload | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        BackendUpload  = @($Plan.Upload | Where-Object { -not $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        FrontendDelete = @($Plan.Delete | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        BackendDelete  = @($Plan.Delete | Where-Object { -not $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    }
}

function Show-DeploymentPlan {
    param($Plan, $Areas, [string]$Environment, [string]$ReleaseId, [string]$GitCommit, [string]$Machine)

    $sizeMb = [Math]::Round($Plan.TotalUploadBytes / 1MB, 2)
    Write-Host "========================================"
    Write-Host " DEPLOYMENT PLAN"
    Write-Host "========================================"
    Write-Host "Environment : $Environment"
    Write-Host "Release     : $ReleaseId"
    Write-Host "Commit      : $GitCommit"
    Write-Host "Machine     : $Machine"
    Write-Host ""
    Write-Host "Frontend"
    Write-Host "  Upload : $($Areas.FrontendUpload.Count)"
    Write-Host "  Delete : $($Areas.FrontendDelete.Count)"
    Write-Host ""
    Write-Host "Backend"
    Write-Host "  Upload : $($Areas.BackendUpload.Count)"
    Write-Host "  Delete : $($Areas.BackendDelete.Count)"
    Write-Host "  Runtime-sensitive changes : $(if ($Plan.HasRuntimeChanges) { 'YES' } else { 'NO' })"
    Write-Host "  Requires app_offline.htm  : $(if ($Plan.HasRuntimeChanges) { 'YES' } else { 'NO' })"
    Write-Host ""
    Write-Host "Skip (unchanged) : $($Plan.Skip.Count)"
    Write-Host "Upload size      : $sizeMb MB"
    Write-Host "Delete total     : $($Plan.Delete.Count) ($($Plan.DeletePct)% of managed files)"
    if ($Plan.IsFirstDeploy) {
        Write-Host "No remote manifest found - first deploy to this root (nothing will be deleted)." -ForegroundColor Yellow
    }
    if (-not $Plan.DeleteSafetyOk) {
        Write-Host "DELETE SAFETY LIMIT EXCEEDED - re-run with -ApproveLargeDelete after reviewing the list below." -ForegroundColor Red
        foreach ($p in $Plan.Delete) { Write-Host "  DELETE  $p" -ForegroundColor Red }
    }
    Write-Host "========================================"
}

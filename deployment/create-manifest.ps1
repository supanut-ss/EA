<#
.SYNOPSIS
    SHA256 manifest building (local tree) and remote manifest read/publish.
    Requires ftps.ps1 dot-sourced first.
#>

# Generic glob matcher shared by protected-path and runtime-sensitive-path
# checks: a trailing "/" in a pattern means "this directory and everything
# under it"; anything else matches against either the file's base name or
# its full relative path.
function Test-PathPattern {
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

function Test-ProtectedPath {
    param([string]$RelativePath, [string[]]$Patterns)
    return Test-PathPattern -RelativePath $RelativePath -Patterns $Patterns
}

function Test-RuntimeSensitivePath {
    param([string]$RelativePath, [string[]]$Patterns)
    return Test-PathPattern -RelativePath $RelativePath -Patterns $Patterns
}

function Test-ExcludedPath {
    param([string]$RelativePath, [string[]]$Patterns)
    return Test-PathPattern -RelativePath $RelativePath -Patterns $Patterns
}

# Hashes every file under $Root (excluding protected/excluded paths) and
# returns @{ "relative/path" = @{ sha256 = "..."; size = 1234 } }.
function New-Sha256Manifest {
    param([string]$Root, [string[]]$ProtectedPaths = @(), [string[]]$ExcludePatterns = @())

    $result = [ordered]@{}
    $resolvedRoot = (Resolve-Path $Root).Path
    Get-ChildItem -Path $resolvedRoot -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($resolvedRoot.Length).TrimStart('\', '/').Replace('\', '/')
        if (Test-ProtectedPath -RelativePath $rel -Patterns $ProtectedPaths) { return }
        if ($ExcludePatterns.Count -gt 0 -and (Test-ExcludedPath -RelativePath $rel -Patterns $ExcludePatterns)) { return }
        $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
        $result[$rel] = [ordered]@{ sha256 = $hash; size = $_.Length }
    }
    return $result
}

$script:ManifestRelativePath = ".deploy/manifest.json"
$script:DeployInfoRelativePath = ".deploy/deploy-info.json"

function Get-RemoteManifest {
    param($Ctx)
    $bytes = Get-RemoteFileBytes -Ctx $Ctx -Uri (New-FtpUri -Ctx $Ctx -RelativePath $script:ManifestRelativePath)
    if (-not $bytes) { return $null }
    try { return ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json) } catch { return $null }
}

# Manifest is always the LAST write of a successful run, via the same
# temp+rename path as everything else, so a reader never observes a
# partially-updated one.
function Publish-Manifest {
    param($Ctx, [System.Collections.Specialized.OrderedDictionary]$Files, [string]$ReleaseId, [string]$GitCommit, [string]$Machine)

    $obj = [ordered]@{
        schemaVersion = 1
        release       = $ReleaseId
        gitCommit     = $GitCommit
        machine       = $Machine
        updatedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
        files         = $Files
    }
    $json = ($obj | ConvertTo-Json -Depth 10)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Publish-RemoteFile -Ctx $Ctx -Bytes $bytes -RelativePath $script:ManifestRelativePath
    Write-DeployLog "Manifest updated ($($Files.Count) tracked files)." "OK"
}

function Publish-DeployInfo {
    param($Ctx, [string]$ReleaseId, [string]$GitCommit, [string]$Machine, [string]$Operator, [string]$Target)

    $obj = [ordered]@{
        release     = $ReleaseId
        gitCommit   = $GitCommit
        deployedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        machine     = $Machine
        operator    = $Operator
        target      = $Target
    }
    $json = ($obj | ConvertTo-Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Publish-RemoteFile -Ctx $Ctx -Bytes $bytes -RelativePath $script:DeployInfoRelativePath
}

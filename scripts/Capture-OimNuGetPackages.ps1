[CmdletBinding()]
param(
    [string]$OimPath = "D:\Program Files\OneIdentity\One Identity Manager v10",
    [string]$CachePath = "C:\Users\rt.OneIMTools.DEV\.nuget\packages",
    [string]$AssemblyCache = "$env:USERPROFILE\AppData\Local\One Identity\One Identity Manager\AssemblyCache",
    [string]$OutputDir = "$env:TEMP\oim-nuget-capture",
    [string]$RepoNuGetRoot,
    [switch]$Prepare,
    [switch]$Generate,
    [switch]$CopyPackages,
    [switch]$ClearAssemblyCache,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function New-PackageKey {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$Version
    )

    return "$($PackageId.ToLowerInvariant())|$Version"
}

function Get-GlobalPackagesManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "NuGet global-packages path not found: $Path"
    }

    Get-ChildItem $Path -Directory | ForEach-Object {
        $packageId = $_.Name
        Get-ChildItem $_.FullName -Directory | ForEach-Object {
            [PSCustomObject]@{
                PackageId      = $packageId
                Version        = $_.Name
                Classification = "compile-package"
                Source         = "global-packages after clean compile"
            }
        }
    } | Sort-Object PackageId, Version
}

function Get-OimBaselineManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $nugetPath = Join-Path $Path "NuGet"
    if (-not (Test-Path $nugetPath)) {
        throw "OIM installation NuGet folder not found: $nugetPath"
    }

    Get-ChildItem $nugetPath -Filter *.nupkg | ForEach-Object {
        if ($_.BaseName -match "^(?<id>.+)\.(?<version>\d+\.\d+\.\d+-\d+)$") {
            [PSCustomObject]@{
                PackageId      = $matches.id
                Version        = $matches.version
                Classification = "oim-baseline"
                Source         = "OIM installation NuGet folder"
            }
        }
    } | Sort-Object PackageId, Version
}

function Compare-PackageManifest {
    param(
        [Parameter(Mandatory = $true)]$NewManifest,
        [Parameter(Mandatory = $true)]$RepoManifest
    )

    $newKeys = $NewManifest | ForEach-Object { New-PackageKey -PackageId $_.PackageId -Version $_.Version }
    $repoKeys = $RepoManifest | ForEach-Object { New-PackageKey -PackageId $_.PackageId -Version $_.Version }

    [PSCustomObject]@{
        Added   = @($newKeys | Where-Object { $_ -notin $repoKeys })
        Removed = @($repoKeys | Where-Object { $_ -notin $newKeys })
    }
}

if (-not $Prepare -and -not $Generate) {
    Write-Host "No phase selected. Use -Prepare before compile, then -Generate after compile."
    Write-Host "Example:"
    Write-Host "  .\scripts\Capture-OimNuGetPackages.ps1 -Prepare"
    Write-Host "  # run OIM compile"
    Write-Host "  .\scripts\Capture-OimNuGetPackages.ps1 -Generate -RepoNuGetRoot .\nuget -CopyPackages"
    Write-Host ""
    Write-Host "Without -CopyPackages, -Generate only writes manifest CSVs to -OutputDir."
    Write-Host "Commit generated manifests/package folder to the backend repository in a later step."
    exit 1
}

if ($Prepare) {
    Write-Host "Clearing NuGet local caches..."
    dotnet nuget locals all --clear

    if ($ClearAssemblyCache) {
        if (-not $Force) {
            Write-Warning "AssemblyCache cleanup skipped. Re-run with -ClearAssemblyCache -Force only on a dedicated build account/agent with all OIM tools closed."
        }
        elseif (Test-Path $AssemblyCache) {
            Write-Host "Removing OIM AssemblyCache: $AssemblyCache"
            Remove-Item $AssemblyCache -Recurse -Force
        }
        else {
            Write-Host "AssemblyCache not found: $AssemblyCache"
        }
    }

    Write-Host "Prepare phase complete. Run OIM compile now, then run this script with -Generate."
}

if ($Generate) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    Write-Host "Generating full manifest from: $CachePath"
    $fullManifest = @(Get-GlobalPackagesManifest -Path $CachePath)
    $fullManifestPath = Join-Path $OutputDir "nuget-packages-manifest.csv"
    $fullManifest | Export-Csv $fullManifestPath -NoTypeInformation

    Write-Host "Generating OIM baseline manifest from: $OimPath\NuGet"
    $baselineManifest = @(Get-OimBaselineManifest -Path $OimPath)
    $baselineManifestPath = Join-Path $OutputDir "oim-v10-baseline-packages.csv"
    $baselineManifest | Export-Csv $baselineManifestPath -NoTypeInformation

    $baselineKeys = $baselineManifest | ForEach-Object { New-PackageKey -PackageId $_.PackageId -Version $_.Version }
    $deltaManifest = @(
        $fullManifest | Where-Object {
            (New-PackageKey -PackageId $_.PackageId -Version $_.Version) -notin $baselineKeys
        } | ForEach-Object {
            [PSCustomObject]@{
                PackageId      = $_.PackageId
                Version        = $_.Version
                Classification = "external-delta"
                Source         = "global-packages after clean compile"
            }
        } | Sort-Object PackageId, Version
    )
    $deltaManifestPath = Join-Path $OutputDir "nuget-delta-manifest.csv"
    $deltaManifest | Export-Csv $deltaManifestPath -NoTypeInformation

    Write-Host "Full manifest:     $fullManifestPath ($($fullManifest.Count) entries)"
    Write-Host "OIM baseline:      $baselineManifestPath ($($baselineManifest.Count) entries)"
    Write-Host "External delta:    $deltaManifestPath ($($deltaManifest.Count) entries)"

    if ($RepoNuGetRoot) {
        $repoManifestPath = Join-Path $RepoNuGetRoot "manifest\nuget-packages-manifest.csv"
        if (Test-Path $repoManifestPath) {
            $repoManifest = @(Import-Csv $repoManifestPath)
            $diff = Compare-PackageManifest -NewManifest $fullManifest -RepoManifest $repoManifest
            $addedPath = Join-Path $OutputDir "nuget-manifest-added.txt"
            $removedPath = Join-Path $OutputDir "nuget-manifest-removed.txt"
            $diff.Added | Sort-Object | Set-Content $addedPath
            $diff.Removed | Sort-Object | Set-Content $removedPath
            Write-Host "Repo manifest diff:"
            Write-Host "  Added:   $($diff.Added.Count) ($addedPath)"
            Write-Host "  Removed: $($diff.Removed.Count) ($removedPath)"
        }
        else {
            Write-Host "Repo manifest not found yet: $repoManifestPath"
            Write-Host "This looks like an initial run."
        }

        if ($CopyPackages) {
            $repoPackagePath = Join-Path $RepoNuGetRoot "packages"
            $repoManifestDir = Join-Path $RepoNuGetRoot "manifest"
            New-Item -ItemType Directory -Force -Path $repoPackagePath, $repoManifestDir | Out-Null

            Write-Host "Copying global-packages content to: $repoPackagePath"
            robocopy $CachePath $repoPackagePath /E
            if ($LASTEXITCODE -gt 7) {
                throw "robocopy failed with exit code $LASTEXITCODE"
            }

            Copy-Item $fullManifestPath (Join-Path $repoManifestDir "nuget-packages-manifest.csv") -Force
            Copy-Item $baselineManifestPath (Join-Path $repoManifestDir "oim-v10-baseline-packages.csv") -Force
            Copy-Item $deltaManifestPath (Join-Path $repoManifestDir "nuget-delta-manifest.csv") -Force
            Write-Host "Copied manifests to: $repoManifestDir"
        }
        else {
            Write-Host "Package copy skipped because -CopyPackages was not provided."
            Write-Host "Review the manifests, then commit/update the package folder in the backend repository as a separate step."
        }
    }
    else {
        Write-Host "No -RepoNuGetRoot provided. Manifests were generated only in: $OutputDir"
        Write-Host "Commit these manifests and the promoted package folder to the backend repository in a later step."
    }
}

# OIM v10 NuGet Package Capture Plan

This note describes how to detect the NuGet packages required by a One Identity Manager v10 database compile and keep the package repository aligned with the code release.

## Goal

Capture the NuGet package set produced by a clean DEV compile, store it with the backend release content, and make non-DEV environments compile from that promoted local package source instead of resolving packages independently.

## Known Paths

```powershell
$oimpath = "D:\Program Files\OneIdentity\One Identity Manager v10"
$cache = "C:\Users\rt.OneIMTools.DEV\.nuget\packages"
$assemblyCache = "$env:USERPROFILE\AppData\Local\One Identity\One Identity Manager\AssemblyCache"
```

Run these variable assignments at the start of every new PowerShell session before using the commands below.

OIM vendor package baseline:

```text
D:\Program Files\OneIdentity\One Identity Manager v10\NuGet
```

Build account NuGet cache:

```text
C:\Users\rt.OneIMTools.DEV\.nuget\packages
```

## Required Process

1. Close OIM tools for the build account, including Designer.
2. Clear NuGet local caches.
3. Clear the OIM `AssemblyCache` for the build account.
4. Run OIM database compile, preferably through `DBCompilerCMD.exe` for automation.
5. Generate a manifest from the rebuilt `global-packages` cache.
6. Compare the new manifest with the manifest already stored in the repository.
7. If packages changed, update the repository package folder and manifest.
8. For non-DEV compile, point `ExternalNugetSource` to the promoted local package folder.

## Clean The Build Account

Clear NuGet caches:

```powershell
dotnet nuget locals all --clear
```

Clear OIM AssemblyCache:

```powershell
Remove-Item $assemblyCache -Recurse -Force
```

Only run this when all OIM tools for the build account are closed.

## Compile

Run the normal OIM database compile.

For automation, validate `DBCompilerCMD.exe` with the real DEV connection/auth context:

```powershell
& "D:\Program Files\OneIdentity\One Identity Manager v10\DBCompilerCMD.exe" /?
```

The command-line compiler supports database compilation using `/Conn` and `/Auth`. The exact pipeline command must use secured credentials and must be validated against the same compile behavior as the GUI compile.

## Generate Full Manifest

Generate the full package manifest from `global-packages` after the clean compile:

```powershell
$cache = "C:\Users\rt.OneIMTools.DEV\.nuget\packages"

Get-ChildItem $cache -Directory |
  ForEach-Object {
    $packageId = $_.Name
    Get-ChildItem $_.FullName -Directory | ForEach-Object {
      [PSCustomObject]@{
        PackageId = $packageId
        Version = $_.Name
        Classification = "compile-package"
        Source = "global-packages after clean compile"
      }
    }
  } |
  Sort-Object PackageId, Version |
  Export-Csv "$env:TEMP\nuget-packages-manifest.csv" -NoTypeInformation
```

Verify:

```powershell
Import-Csv "$env:TEMP\nuget-packages-manifest.csv" | Select-Object -First 20
```

## Generate OIM Baseline Manifest

OIM vendor packages are shipped in the installation `NuGet` folder. Generate the baseline manifest from those `.nupkg` files:

```powershell
$oimpath = "D:\Program Files\OneIdentity\One Identity Manager v10"

Get-ChildItem "$oimpath\NuGet" -Filter *.nupkg |
  ForEach-Object {
    if ($_.BaseName -match "^(?<id>.+)\.(?<version>\d+\.\d+\.\d+-\d+)$") {
      [PSCustomObject]@{
        PackageId = $matches.id
        Version = $matches.version
        Classification = "oim-baseline"
        Source = "OIM installation NuGet folder"
      }
    }
  } |
  Sort-Object PackageId, Version |
  Export-Csv "$env:TEMP\oim-v10-baseline-packages.csv" -NoTypeInformation
```

## Generate External Delta Manifest

The external delta is the package/version set restored by the clean compile but not present in the OIM installation baseline.

```powershell
$oimpath = "D:\Program Files\OneIdentity\One Identity Manager v10"
$cache = "C:\Users\rt.OneIMTools.DEV\.nuget\packages"

$baseline = Get-ChildItem "$oimpath\NuGet" -Filter *.nupkg |
  ForEach-Object {
    if ($_.BaseName -match "^(?<id>.+)\.(?<version>\d+\.\d+\.\d+-\d+)$") {
      "$($matches.id.ToLowerInvariant())|$($matches.version)"
    }
  }

Get-ChildItem $cache -Directory |
  ForEach-Object {
    $packageId = $_.Name
    Get-ChildItem $_.FullName -Directory | ForEach-Object {
      $key = "$($packageId.ToLowerInvariant())|$($_.Name)"
      if ($key -notin $baseline) {
        [PSCustomObject]@{
          PackageId = $packageId
          Version = $_.Name
          Classification = "external-delta"
          Source = "global-packages after clean compile"
        }
      }
    }
  } |
  Sort-Object PackageId, Version |
  Export-Csv "$env:TEMP\nuget-delta-manifest.csv" -NoTypeInformation
```

Verify:

```powershell
Import-Csv "$env:TEMP\nuget-delta-manifest.csv" | Select-Object -First 20
```

## Detect Repository Changes

The repository should store the promoted package folder and a manifest.

Recommended repository shape:

```text
nuget/
  packages/
    <global-packages-compatible package folders>
  manifest/
    nuget-packages-manifest.csv
    nuget-delta-manifest.csv
```

Compare the fresh manifest with the repository manifest:

```powershell
$new = Import-Csv "$env:TEMP\nuget-packages-manifest.csv"
$repo = Import-Csv ".\nuget\manifest\nuget-packages-manifest.csv"

$newKeys = $new | ForEach-Object { "$($_.PackageId.ToLowerInvariant())|$($_.Version)" }
$repoKeys = $repo | ForEach-Object { "$($_.PackageId.ToLowerInvariant())|$($_.Version)" }

$added = $newKeys | Where-Object { $_ -notin $repoKeys }
$removed = $repoKeys | Where-Object { $_ -notin $newKeys }

[PSCustomObject]@{
  Added = $added.Count
  Removed = $removed.Count
}
```

If `Added` or `Removed` is greater than zero, update the package folder and manifests in the repository.

## Promote Package Folder

Copy the complete `global-packages` content into the repository/package artifact location:

```powershell
robocopy $cache ".\nuget\packages" /E
```

Commit the package folder and manifests together with the backend release content.

## Pre-Compile Gate For Non-DEV

Before compiling in TEST/UAT/PROD:

1. Read the repository manifest.
2. Verify every `PackageId` and `Version` exists in the promoted local package folder.
3. Configure `Common | Compiler | ExternalNugetSource` to the promoted local folder.
4. Fail before DB compile if any package/version is missing.

Example validation:

```powershell
$manifest = Import-Csv ".\nuget\manifest\nuget-packages-manifest.csv"
$localSource = ".\nuget\packages"

$missing = foreach ($pkg in $manifest) {
  $path = Join-Path $localSource (Join-Path $pkg.PackageId.ToLowerInvariant() $pkg.Version)
  if (-not (Test-Path $path)) {
    "$($pkg.PackageId)|$($pkg.Version)"
  }
}

if ($missing.Count -gt 0) {
  Write-Error "Missing NuGet packages: $($missing -join ', ')"
  exit 1
}
```

## Proven In DEV

The DEV PoC showed:

- OIM installation baseline contained `53` vendor packages.
- A clean compile restored `147` package/version pairs into `global-packages`.
- Excluding the OIM baseline produced `99` external delta package/version pairs.
- A local-source compile succeeded using `D:\NuGet-PoC\LocalNuGetSource`.
- During the local-source compile, the HTTP/Nexus cache was not recreated.

## Key Rule

Do not infer required packages from a dirty cache.

The reliable method is:

```text
clean compile output + manifest diff = package change detection
```

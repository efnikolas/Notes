# Fresh OIM NuGet Package Check

Use this runbook to prove that packages found in `global-packages` were restored by the current OIM compile, not left over from another developer or an older compile.

Run these commands on the DEV machine/build account that performs the OIM compile.

## 1. Set Variables And Verify Paths

```powershell
$OimPath = "D:\Program Files\OneIdentity\One Identity Manager v10"
$CachePath = "C:\Users\rt.OneIMTools.DEV\.nuget\packages"
$AssemblyCache = "$env:USERPROFILE\AppData\Local\One Identity\One Identity Manager\AssemblyCache"
$OutputDir = "$env:TEMP\oim-nuget-fresh-check"

[PSCustomObject]@{
  UserName = $env:USERNAME
  Temp = $env:TEMP
  OimPathExists = Test-Path $OimPath
  CachePathExists = Test-Path $CachePath
  AssemblyCacheExists = Test-Path $AssemblyCache
}
```

Stop if `CachePath` or `AssemblyCache` points to a different account than the account that will run the compile.

## 2. Capture Before State

```powershell
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if (Test-Path $CachePath) {
  Get-ChildItem $CachePath -Directory |
    Select-Object Name, FullName, LastWriteTime |
    Sort-Object Name |
    Export-Csv "$OutputDir\before-global-packages-folders.csv" -NoTypeInformation
}

Get-ChildItem $AssemblyCache -Recurse -Filter *.deps.json -File -ErrorAction SilentlyContinue |
  Select-Object FullName, LastWriteTime, Length |
  Sort-Object LastWriteTime -Descending |
  Export-Csv "$OutputDir\before-deps-json-files.csv" -NoTypeInformation

Get-ChildItem $OutputDir
```

## 3. Close OIM Tools

Close Designer and any other OIM tools for this build account.

Check for likely locking processes:

```powershell
Get-Process |
  Where-Object {
    $_.ProcessName -match "Designer|Manager|LaunchPad|DBCompiler|SynchronizationEditor|Compiler"
  } |
  Select-Object ProcessName, Id
```

If other people are using the same account, do not delete `AssemblyCache` manually. Use a dedicated build account/agent for the automated version.

## 4. Clear NuGet Caches

```powershell
dotnet nuget locals all --clear

[PSCustomObject]@{
  GlobalPackageEntryCount = if (Test-Path $CachePath) { (Get-ChildItem $CachePath -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }
  HttpCacheExists = Test-Path "$env:LOCALAPPDATA\NuGet\v3-cache"
}
```

Expected `GlobalPackageEntryCount` is `0`.

## 5. Clear OIM AssemblyCache

Only do this if no other session is using the same account.

```powershell
if (Test-Path $AssemblyCache) {
  Remove-Item $AssemblyCache -Recurse -Force
}

Test-Path $AssemblyCache
```

Expected result is `False`.

If removal fails because files are locked, stop. Close the locking OIM processes or use a dedicated build account/agent.

## 6. Run OIM Compile

Run the normal full OIM database compile.

Do not run other OIM package operations between cache clearing and this compile.

## 7. Generate Fresh Cache Manifest

```powershell
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$GlobalManifest = Get-ChildItem $CachePath -Directory |
  ForEach-Object {
    $PackageId = $_.Name
    Get-ChildItem $_.FullName -Directory | ForEach-Object {
      [PSCustomObject]@{
        PackageId = $PackageId
        Version = $_.Name
        Source = "global-packages after fresh clean compile"
      }
    }
  } |
  Sort-Object PackageId, Version

$GlobalManifest |
  Export-Csv "$OutputDir\nuget-packages-manifest.csv" -NoTypeInformation

$GlobalManifest.Count
```

## 8. Generate Fresh deps.json Manifest

This reads only `.deps.json` files created or updated after the compile.

```powershell
$CompileWindowStart = (Get-Date).AddHours(-4)

$DepsManifest = Get-ChildItem $AssemblyCache -Recurse -Filter *.deps.json -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -ge $CompileWindowStart } |
  ForEach-Object {
    $File = $_.FullName
    $Json = Get-Content $File -Raw | ConvertFrom-Json

    if ($Json.libraries) {
      foreach ($Library in $Json.libraries.PSObject.Properties) {
        if ($Library.Value.type -eq "package" -and $Library.Name -match "^(?<id>.+)/(?<version>[^/]+)$") {
          [PSCustomObject]@{
            PackageId = $matches.id
            Version = $matches.version
            Source = $File
          }
        }
      }
    }
  } |
  Sort-Object PackageId, Version -Unique

$DepsManifest |
  Export-Csv "$OutputDir\deps-json-packages-manifest.csv" -NoTypeInformation

$DepsManifest.Count
```

If the compile was more than four hours ago, increase the window:

```powershell
$CompileWindowStart = (Get-Date).AddHours(-24)
```

## 9. Compare Cache Manifest With deps.json Manifest

```powershell
$GlobalKeys = $GlobalManifest | ForEach-Object { "$($_.PackageId.ToLowerInvariant())|$($_.Version)" }
$DepsKeys = $DepsManifest | ForEach-Object { "$($_.PackageId.ToLowerInvariant())|$($_.Version)" }

$MissingFromDeps = @($GlobalKeys | Where-Object { $_ -notin $DepsKeys } | Sort-Object)
$ExtraInDeps = @($DepsKeys | Where-Object { $_ -notin $GlobalKeys } | Sort-Object)

$MissingFromDeps | Set-Content "$OutputDir\deps-json-missing-global-packages.txt"
$ExtraInDeps | Set-Content "$OutputDir\deps-json-extra-packages.txt"

[PSCustomObject]@{
  GlobalPackages = $GlobalKeys.Count
  DepsJsonPackages = $DepsKeys.Count
  MissingFromDepsJson = $MissingFromDeps.Count
  ExtraInDepsJson = $ExtraInDeps.Count
  OutputDir = $OutputDir
}
```

## 10. Inspect Differences

```powershell
Get-Content "$OutputDir\deps-json-missing-global-packages.txt" -ErrorAction SilentlyContinue
Get-Content "$OutputDir\deps-json-extra-packages.txt" -ErrorAction SilentlyContinue
```

Interpretation:

- If both files are empty, `.deps.json` matches `global-packages` for this fresh compile.
- If `deps-json-missing-global-packages.txt` has entries, `.deps.json` missed packages restored by the compile.
- If `deps-json-extra-packages.txt` has entries, `.deps.json` contains packages not found in `global-packages`.
- If there are differences, use `global-packages` after clean compile as the source of truth and keep `.deps.json` only as a cross-check.

## 11. Verify Missing Packages Are Absent From deps.json

If `deps-json-missing-global-packages.txt` contains packages, verify that the script did not miss them by searching the fresh `.deps.json` files directly.

Use the same `$CompileWindowStart` from the fresh compile check:

```powershell
Get-ChildItem $AssemblyCache -Recurse -Filter *.deps.json -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -ge $CompileWindowStart } |
  Select-String -Pattern "microsoft.codeanalysis.analyzers","pollysharp" |
  Select-Object Path, LineNumber, Line
```

If this returns no rows, those packages are genuinely absent from the fresh `.deps.json` files.

Also list the exact `.deps.json` files that were included in the check:

```powershell
Get-ChildItem $AssemblyCache -Recurse -Filter *.deps.json -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -ge $CompileWindowStart } |
  Select-Object FullName, LastWriteTime, Length |
  Sort-Object LastWriteTime -Descending
```

Expected interpretation for the current observed result:

```text
global-packages after compile: 147
deps.json package entries:     145
missing from deps.json:        microsoft.codeanalysis.analyzers|3.11.0, pollysharp|1.15.0
extra in deps.json:            0
```

If the direct `Select-String` search also returns no rows for those packages, `.deps.json` is not complete enough to be the source of truth. Use `global-packages` after clean compile instead.

## 12. Optional: Run Repository Script Instead

The repository script performs the same comparison:

```powershell
cd D:\DevOps\Repos\EfthymiadisN.eu

.\scripts\Capture-OimNuGetPackages.ps1 `
  -CompareDepsJson `
  -DepsJsonLookbackHours 4 `
  -CachePath $CachePath `
  -AssemblyCache $AssemblyCache `
  -OutputDir $OutputDir
```

Inspect:

```powershell
Get-ChildItem $OutputDir
Get-Content "$OutputDir\deps-json-missing-global-packages.txt" -ErrorAction SilentlyContinue
Get-Content "$OutputDir\deps-json-extra-packages.txt" -ErrorAction SilentlyContinue
```

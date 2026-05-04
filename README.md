Generate it from global-packages after the clean compile.

NuGet global-packages has this structure:

C:\Users\rt.OneIMTools.DEV\.nuget\packages\
  package.id\
    version\
      package files...
So the manifest is just:

top-level folder name = PackageId
second-level folder name = Version
Run this after clean compile:

$cache = "C:\Users\rt.OneIMTools.DEV\.nuget\packages"

Get-ChildItem $cache -Directory |
  ForEach-Object {
    $packageId = $_.Name
    Get-ChildItem $_.FullName -Directory | ForEach-Object {
      [PSCustomObject]@{
        PackageId = $packageId
        Version = $_.Name
        Source = "global-packages"
      }
    }
  } |
  Sort-Object PackageId, Version |
  Export-Csv "$env:TEMP\nuget-packages-manifest.csv" -NoTypeInformation
Verify:

Import-Csv "$env:TEMP\nuget-packages-manifest.csv" | Select-Object -First 20
That creates the full manifest.

To generate the external delta manifest excluding OIM vendor packages:

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
Verify:

Import-Csv "$env:TEMP\nuget-delta-manifest.csv" | Select-Object -First 20
That is the manifest generation method.

For the PBI, describe it like this:

After clean compile, generate the manifest by walking the NuGet global-packages folder

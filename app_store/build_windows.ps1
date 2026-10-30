<#
.SYNOPSIS
  Build a react-native-windows Store package (.msixupload) on a Windows host.

.DESCRIPTION
  The counterpart to build.sh for the one platform that cannot be built on macOS.
  Run this on the Windows PC (or a windows-latest CI runner) from the project
  root. It installs JS deps, then MSBuilds the windows/ solution in Release with
  StoreUpload packaging, and copies the resulting .msixupload into
  app_store/builds/release/ so `appstore submit --platforms microsoft` (run from
  anywhere) can upload it.

.PARAMETER Platforms
  Comma-separated app architectures to bundle (default: x64,ARM64).

.PARAMETER AppStoreDir
  Path to the app_store config dir (default: <project>/app_store).

.EXAMPLE
  pwsh app_store\build_windows.ps1
  pwsh app_store\build_windows.ps1 -Platforms x64
#>
param(
  [string]$Platforms = "x64,ARM64",
  [string]$AppStoreDir
)

$ErrorActionPreference = "Stop"

# Resolve project + app_store dirs.
$ProjectDir = (Resolve-Path "$PSScriptRoot\..").Path
if (-not $AppStoreDir) { $AppStoreDir = Join-Path $ProjectDir "app_store" }
$Info = Get-Content (Join-Path $AppStoreDir "info.json") | ConvertFrom-Json

$AppName = $Info.build.windows.appName
if (-not $AppName) { $AppName = $Info.build.ios.appName }
if (-not $AppName) { $AppName = $Info.app.name }

$Version = $Info.metadata.version
$Pkg = Get-Content (Join-Path $ProjectDir "package.json") -ErrorAction SilentlyContinue | ConvertFrom-Json
if ($Pkg -and $Pkg.version) { $Version = $Pkg.version }

Write-Host "Building Windows Store package for $AppName $Version ($Platforms)"

# 1. JS deps + native prep.
Push-Location $ProjectDir
try {
  if (Test-Path "bun.lock") { bun install --frozen-lockfile } else { npm ci }

  # 2. Locate the solution.
  $Solution = Get-ChildItem -Path (Join-Path $ProjectDir "windows") -Filter *.sln -Recurse |
    Select-Object -First 1
  if (-not $Solution) { throw "No .sln found under windows/." }
  Write-Host "Solution: $($Solution.FullName)"

  # 3. Restore + build each architecture in Release / StoreUpload mode.
  $OutRoot = Join-Path $AppStoreDir "builds\release"
  New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
  $AppxDir = Join-Path $OutRoot "AppPackages"

  msbuild $Solution.FullName `
    /restore `
    /p:Configuration=Release `
    /p:AppxBundlePlatforms=$Platforms `
    /p:AppxBundle=Always `
    /p:UapAppxPackageBuildMode=StoreUpload `
    /p:AppxPackageDir=$AppxDir `
    /p:AppxPackageSigningEnabled=false `
    /verbosity:minimal

  # 4. Copy the .msixupload (the Store artifact) up into builds/release/.
  $Upload = Get-ChildItem -Path $AppxDir -Filter *.msixupload -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if (-not $Upload) {
    $Upload = Get-ChildItem -Path $AppxDir -Filter *.appxupload -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1
  }
  if (-not $Upload) { throw "Build finished but no .msixupload was produced in $AppxDir." }

  $Dest = Join-Path $OutRoot $Upload.Name
  Copy-Item $Upload.FullName $Dest -Force
  Write-Host "Windows Store package: $Dest"
}
finally {
  Pop-Location
}

[CmdletBinding()]
param(
    [string]$BuildRoot = "D:\DawnCEFBuild",
    [string]$CefUrl = "https://github.com/Weheba/DawnCEFSource.git",
    [string]$CefCheckout = "dawn-native-codecs.1",
    [switch]$RunCefTests,
    [switch]$RunMediaTests
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$requiredSdk = "10.0.26100.0"
$requiredFreeBytes = 155GB
$chromiumCheckout = "refs/tags/146.0.7680.179"
$distributionSuffix = "dawn-native-codecs.1"

$resolvedBuildRoot = [System.IO.Path]::GetFullPath($BuildRoot)
if ($resolvedBuildRoot -match "\s") {
    throw "The Chromium build path cannot contain spaces: $resolvedBuildRoot"
}

$drive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($resolvedBuildRoot).TrimEnd(":\"))
if ($drive.Free -lt $requiredFreeBytes) {
    throw "At least 155 GB must be free on $($drive.Name):; found $([math]::Round($drive.Free / 1GB, 1)) GB."
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio Installer was not found."
}

$visualStudio = & $vswhere -latest -products * -version "[17.0,18.0)" `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) {
    throw "Visual Studio 2022 Desktop development with C++ is required."
}

$sdkInclude = "${env:ProgramFiles(x86)}\Windows Kits\10\Include\$requiredSdk"
if (-not (Test-Path -LiteralPath $sdkInclude)) {
    throw "Windows SDK $requiredSdk is required."
}

$python = Get-Command python -ErrorAction Stop
$automate = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\automate\automate-git.py"
$depotTools = Join-Path $resolvedBuildRoot "depot_tools"

$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$env:CEF_ARCHIVE_FORMAT = "tar.bz2"
$env:GN_DEFINES = 'is_official_build=true proprietary_codecs=true media_use_ffmpeg=true ffmpeg_branding="Chromium" use_thin_lto=false symbol_level=1 chrome_pgo_phase=0'
$buildTargets = "cefclient"
if ($RunMediaTests) {
    $buildTargets += " media_unittests"
}

$arguments = @(
    $automate,
    "--download-dir=$resolvedBuildRoot",
    "--depot-tools-dir=$depotTools",
    "--branch=146",
    "--url=$CefUrl",
    "--checkout=$CefCheckout",
    "--chromium-checkout=$chromiumCheckout",
    "--no-chromium-history",
    "--x64-build",
    "--no-debug-build",
    "--force-build",
    "--build-target=$buildTargets",
    "--force-distrib",
    "--minimal-distrib-only",
    "--no-distrib-symbols",
    "--no-distrib-docs",
    "--distrib-subdir-suffix=$distributionSuffix",
    "--build-log-file"
)

if ($RunCefTests) {
    $arguments += @("--build-tests", "--run-tests", "--test-target=ceftests")
}

Write-Host "Building DawnCEF from $CefCheckout against Chromium $chromiumCheckout"
Write-Host "GN_DEFINES=$env:GN_DEFINES"
& $python.Source @arguments
if ($LASTEXITCODE -ne 0) {
    throw "DawnCEF build failed with exit code $LASTEXITCODE."
}

if ($RunMediaTests) {
    $mediaTests = Join-Path $resolvedBuildRoot `
        "chromium_git\chromium\src\out\Release_GN_x64\media_unittests.exe"
    if (-not (Test-Path -LiteralPath $mediaTests)) {
        throw "media_unittests was not produced: $mediaTests"
    }
    & $mediaTests "--gtest_filter=MediaFoundation/*" "--test-launcher-jobs=1"
    if ($LASTEXITCODE -ne 0) {
        throw "Media Foundation AAC tests failed with exit code $LASTEXITCODE."
    }
}

$distributionRoot = Join-Path $resolvedBuildRoot "chromium_git\chromium\src\cef\binary_distrib"
Get-ChildItem -LiteralPath $distributionRoot -Filter "*${distributionSuffix}*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object FullName, Length, LastWriteTime

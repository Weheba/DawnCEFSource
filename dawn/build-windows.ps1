[CmdletBinding()]
param(
    [string]$BuildRoot = "D:\DawnCEFBuild",
    [string]$CefUrl = "https://github.com/Weheba/DawnCEFSource.git",
    [string]$CefCheckout = "dawn-native-codecs.3.1",
    [ValidateRange(1, 64)]
    [int]$BuildJobs = 4,
    [switch]$RunCefTests,
    [switch]$RunMediaTests
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$requiredSdk = "10.0.26100.0"
$requiredFreshFreeBytes = 155GB
$requiredResumeFreeBytes = 100GB
$chromiumCheckout = "refs/tags/146.0.7680.179"
$distributionSuffix = "dawn-native-codecs.3"

function Get-AutomateChromiumSrcCandidates {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    @(
        (Join-Path $Root "chromium\src"),
        (Join-Path $Root "chromium_git\chromium\src")
    ) | Select-Object -Unique
}

function Resolve-AutomateChromiumSrcDir {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    foreach ($candidate in (Get-AutomateChromiumSrcCandidates -Root $Root)) {
        if (Test-Path -LiteralPath (Join-Path $candidate "chrome\VERSION")) {
            return $candidate
        }
    }

    return (Get-AutomateChromiumSrcCandidates -Root $Root)[0]
}

$resolvedBuildRoot = [System.IO.Path]::GetFullPath($BuildRoot)
if ($resolvedBuildRoot -match "\s") {
    throw "The Chromium build path cannot contain spaces: $resolvedBuildRoot"
}

$drive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($resolvedBuildRoot).TrimEnd(":\"))
$chromiumSrcDir = Resolve-AutomateChromiumSrcDir -Root $resolvedBuildRoot
$chromiumVersionFile = Join-Path $chromiumSrcDir "chrome\VERSION"
$isResume = Test-Path -LiteralPath $chromiumVersionFile
$requiredFreeBytes = if ($isResume) { $requiredResumeFreeBytes } else { $requiredFreshFreeBytes }
if ($drive.Free -lt $requiredFreeBytes) {
    $buildState = if ($isResume) { "resuming the build" } else { "starting a fresh build" }
    throw "At least $([math]::Round($requiredFreeBytes / 1GB)) GB must be free on $($drive.Name): when $buildState; found $([math]::Round($drive.Free / 1GB, 1)) GB."
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

$sdkDxilCandidates = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin\$requiredSdk\x64\dxil.dll",
    "${env:ProgramFiles(x86)}\Windows Kits\10\Redist\D3D\x64\dxil.dll"
)
if (-not ($sdkDxilCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)) {
    throw "Windows SDK $requiredSdk x64 DirectX tools are required. Missing dxil.dll from both the versioned bin and Redist\D3D locations."
}

$python = Get-Command python -ErrorAction Stop
$automate = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\automate\automate-git.py"
$depotTools = Join-Path $resolvedBuildRoot "depot_tools"

$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$env:GYP_MSVS_VERSION = "2022"
$env:GYP_MSVS_OVERRIDE_PATH = $visualStudio
$env:vs2022_install = $visualStudio
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
    "--branch=7680",
    "--url=$CefUrl",
    "--checkout=$CefCheckout",
    "--cef-checkout-branch=7680",
    "--chromium-checkout=$chromiumCheckout",
    "--no-chromium-history",
    "--x64-build",
    "--no-debug-build",
    "--force-build",
    "--build-jobs=$BuildJobs",
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

$chromiumSrcDir = Resolve-AutomateChromiumSrcDir -Root $resolvedBuildRoot

if ($RunMediaTests) {
    $mediaTests = Join-Path $chromiumSrcDir "out\Release_GN_x64\media_unittests.exe"
    if (-not (Test-Path -LiteralPath $mediaTests)) {
        throw "media_unittests was not produced: $mediaTests"
    }
    & $mediaTests "--gtest_filter=MediaFoundation/*" "--test-launcher-jobs=1"
    if ($LASTEXITCODE -ne 0) {
        throw "Media Foundation AAC tests failed with exit code $LASTEXITCODE."
    }
}

$distributionRoot = Join-Path $chromiumSrcDir "cef\binary_distrib"
Get-ChildItem -LiteralPath $distributionRoot -Filter "*${distributionSuffix}*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object FullName, Length, LastWriteTime

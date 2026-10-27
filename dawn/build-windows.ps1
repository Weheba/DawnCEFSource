[CmdletBinding()]
param(
    [string]$BuildRoot = "D:\DawnCEFBuild",
    [string]$CefUrl = "https://github.com/Weheba/DawnCEFSource.git",
    [string]$CefCheckout = "dawn-native-codecs.5",
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
$distributionSuffix = "dawn-native-codecs.5"
# Code that only the OpenH264 software H.264 encoder links in.
$openH264Markers = @("OpenH264", "H264EncoderImpl", "OpenH264VideoEncoder")

function Find-AsciiMarkers {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string[]]$Markers
    )

    # Reads the file in chunks; the tail of each chunk is kept so that a marker
    # split across two chunks is still found.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $overlap = ($Markers | Measure-Object -Property Length -Maximum).Maximum - 1
    $found = New-Object System.Collections.Generic.List[string]
    $buffer = New-Object byte[] (16MB)
    $tail = ""
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $text = $tail + $latin1.GetString($buffer, 0, $read)
            foreach ($marker in $Markers) {
                if (-not $found.Contains($marker) -and $text.Contains($marker)) {
                    $found.Add($marker)
                }
            }
            $tail = $text.Substring([Math]::Max(0, $text.Length - $overlap))
        }
    } finally {
        $stream.Dispose()
    }
    return ,$found.ToArray()
}

function Assert-DawnDistribution {
    param(
        [Parameter(Mandatory)]
        [string]$ChromiumSrc,
        [Parameter(Mandatory)]
        [string]$DistributionRoot
    )

    $distributions = @(Get-ChildItem -LiteralPath $DistributionRoot -Directory -Filter "cef_binary_*_windows64_${distributionSuffix}_minimal")
    if ($distributions.Count -ne 1) {
        throw "Expected one windows64 $distributionSuffix distribution, found $($distributions.Count)."
    }
    $distribution = $distributions[0].FullName

    # automate-git.py passes --allow-partial to make_distrib.py for a Release-only
    # build, which writes a distribution without the Release files when the build
    # output is missing, so check that everything is there.
    $requiredFiles = @(
        "CMakeLists.txt",
        "cmake\FindCEF.cmake",
        "include\cef_version.h",
        "libcef_dll\CMakeLists.txt",
        "dawn-codec-build.properties",
        "Release\bootstrap.exe",
        "Release\bootstrapc.exe",
        "Release\chrome_elf.dll",
        "Release\d3dcompiler_47.dll",
        "Release\dxcompiler.dll",
        "Release\dxil.dll",
        "Release\libcef.dll",
        "Release\libcef.lib",
        "Release\libEGL.dll",
        "Release\libGLESv2.dll",
        "Release\v8_context_snapshot.bin",
        "Release\vk_swiftshader.dll",
        "Release\vk_swiftshader_icd.json",
        "Release\vulkan-1.dll",
        "Resources\chrome_100_percent.pak",
        "Resources\chrome_200_percent.pak",
        "Resources\icudtl.dat",
        "Resources\resources.pak",
        "Resources\locales\en-US.pak"
    )
    foreach ($file in $requiredFiles) {
        $path = Join-Path $distribution $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            throw "The distribution is incomplete: $file is missing or empty."
        }
    }
    $expectedRevision = (Get-Content -LiteralPath (Join-Path $PSScriptRoot "dawn-codec-build.properties") |
        Where-Object { $_ -like "codec.revision=*" }) -replace '^codec\.revision=', ''
    if (-not (Select-String -LiteralPath (Join-Path $distribution "dawn-codec-build.properties") `
            -Pattern "^codec\.revision=$([regex]::Escape($expectedRevision))$" -Quiet)) {
        throw "The distribution marker does not name $expectedRevision."
    }

    # No OpenH264: both GN args must resolve to false, and no OpenH264 or WebRTC
    # software H.264 encoder code may be linked into the binaries.
    $gn = Join-Path $ChromiumSrc "buildtools\win\gn.exe"
    Push-Location -LiteralPath $ChromiumSrc
    $previousPath = $env:PATH
    try {
        $env:PATH = "$depotTools;$env:PATH"
        foreach ($arg in @("media_use_openh264", "rtc_use_h264")) {
            $value = (& $gn args "out\Release_GN_x64" "--list=$arg" --short | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $value -ne "$arg = false") {
                throw "$arg must be false: $value"
            }
        }
    } finally {
        $env:PATH = $previousPath
        Pop-Location
    }
    $binaries = Get-ChildItem -LiteralPath (Join-Path $distribution "Release") -File |
        Where-Object { $_.Extension -in @(".dll", ".exe") }
    foreach ($binary in $binaries) {
        $found = Find-AsciiMarkers -Path $binary.FullName -Markers $openH264Markers
        if ($found.Count -gt 0) {
            throw "OpenH264 is linked into $($binary.Name): $($found -join ', ')"
        }
    }
    Write-Host "Distribution complete, OpenH264 absent: $distribution"
}

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
# media_use_openh264=false leaves out the OpenH264 software H.264 encoder that
# proprietary_codecs turns on by default; WebRTC's rtc_use_h264 follows it.
$env:GN_DEFINES = 'is_official_build=true proprietary_codecs=true media_use_ffmpeg=true ffmpeg_branding="Chromium" media_use_openh264=false use_thin_lto=false symbol_level=1 chrome_pgo_phase=0'
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
$distributionRoot = Join-Path $chromiumSrcDir "cef\binary_distrib"
Assert-DawnDistribution -ChromiumSrc $chromiumSrcDir -DistributionRoot $distributionRoot

if ($RunMediaTests) {
    $mediaTests = Join-Path $chromiumSrcDir "out\Release_GN_x64\media_unittests.exe"
    if (-not (Test-Path -LiteralPath $mediaTests)) {
        throw "media_unittests was not produced: $mediaTests"
    }
    # The FFmpegDemuxer cases check that an MP4 AAC track survives demuxing without FFmpeg's AAC decoder;
    # the MediaFoundation cases decode it.
    & $mediaTests "--gtest_filter=MediaFoundation/*:FFmpegDemuxerTest.Dawn_*:FFmpegDemuxerTest.Read_Mp4_Media_Track_Info" "--test-launcher-jobs=1"
    if ($LASTEXITCODE -ne 0) {
        throw "Media Foundation AAC tests failed with exit code $LASTEXITCODE."
    }
}

Get-ChildItem -LiteralPath $distributionRoot -Filter "*${distributionSuffix}*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object FullName, Length, LastWriteTime

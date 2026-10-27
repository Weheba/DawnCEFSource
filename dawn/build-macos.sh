#!/usr/bin/env bash
set -euo pipefail

# Builds a Release minimal CEF binary distribution for macOS.
#
# Environment:
#   DAWN_MAC_ARCH          arm64 (default) or x64. x64 cross-compiles on an
#                          Apple silicon host.
#   DAWN_BUILD_JOBS        concurrent compile jobs (default 6). Chromium
#                          compile steps take up to ~2 GB each, so keep this
#                          low on 16 GB Macs.
#   DAWN_MAC_SDK_PATH      optional macOS SDK to build against instead of the
#                          one in the selected Xcode.
#   DAWN_CEF_CHECKOUT      CEF commit or tag to build (default below).
#   DAWN_FETCH_ONLY=1      sync and patch the sources without building.
#   DAWN_AUTOMATE_ARGS     extra automate-git.py flags, for example
#                          "--force-update" to repair an interrupted sync, or
#                          "--no-update" to resume a build without syncing.
#   DAWN_RUN_MEDIA_TESTS=1 also build and run the AudioToolbox and
#                          FFmpegDemuxer regression tests.

BUILD_ROOT="${1:-$HOME/DawnCEFBuild}"
CEF_URL="${DAWN_CEF_URL:-https://github.com/Weheba/DawnCEFSource.git}"
CEF_CHECKOUT="${DAWN_CEF_CHECKOUT:-dawn-native-codecs.5}"
CHROMIUM_CHECKOUT="refs/tags/146.0.7680.179"
DISTRIBUTION_SUFFIX="dawn-native-codecs.5"
REQUIRED_KB=$((155 * 1024 * 1024))
BUILD_TARGETS="cefclient"
MAC_ARCH="${DAWN_MAC_ARCH:-arm64}"
BUILD_JOBS="${DAWN_BUILD_JOBS:-6}"

case "$MAC_ARCH" in
  arm64) ARCH_FLAG="--arm64-build" ;;
  x64)
    ARCH_FLAG="--x64-build"
    # gn_args.py only generates the host architecture unless asked.
    export CEF_ENABLE_AMD64=1
    ;;
  *)
    echo "DAWN_MAC_ARCH must be arm64 or x64: $MAC_ARCH" >&2
    exit 1
    ;;
esac
OUT_CONFIG="Release_GN_$MAC_ARCH"
# Only generate the configuration this build uses.
export GN_OUT_CONFIGS="$OUT_CONFIG"

if [[ "${DAWN_RUN_MEDIA_TESTS:-0}" == "1" ]]; then
  BUILD_TARGETS+=" media_unittests"
fi

case "$BUILD_ROOT" in
  *" "*)
    echo "The Chromium build path cannot contain spaces: $BUILD_ROOT" >&2
    exit 1
    ;;
esac

mkdir -p "$BUILD_ROOT"
AVAILABLE_KB="$(df -Pk "$BUILD_ROOT" | awk 'NR == 2 { print $4 }')"
if [[ ! -d "$BUILD_ROOT/chromium/src" ]] && (( AVAILABLE_KB < REQUIRED_KB )); then
  echo "At least 155 GB of free disk space is required." >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "A full Xcode 26 installation must be selected with xcode-select." >&2
  exit 1
fi

XCODE_MAJOR="$(xcodebuild -version | awk '/Xcode/ { split($2, v, "."); print v[1] }')"
if (( XCODE_MAJOR < 26 )); then
  echo "Xcode 26 or newer is required; found $(xcodebuild -version | head -1)." >&2
  exit 1
fi

# ANGLE compiles its Metal shaders at build time. Since Xcode 26 the Metal
# compiler is a separate component.
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "The Metal Toolchain is missing: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOMATE="$SCRIPT_DIR/../tools/automate/automate-git.py"
DEPOT_TOOLS="$BUILD_ROOT/depot_tools"

# The codec configuration matches the Windows build. media_use_openh264=false
# leaves out the OpenH264 software H.264 encoder that proprietary_codecs turns
# on by default; WebRTC's rtc_use_h264 follows it. The remaining args only
# reduce build memory and time and do not change the generated code:
#   symbol_level=0 / enable_dsyms=false: no debug info or dSYMs (the
#     distribution ships without symbols either way).
#   concurrent_links=1: one link at a time; the framework link alone needs
#     several GB.
#   treat_warnings_as_errors=false: Xcode SDKs newer than this Chromium branch
#     add deprecation warnings.
GN_DEFINES='is_official_build=true proprietary_codecs=true media_use_ffmpeg=true ffmpeg_branding="Chromium" media_use_openh264=false use_thin_lto=false chrome_pgo_phase=0'
GN_DEFINES+=' symbol_level=0 enable_dsyms=false concurrent_links=1 treat_warnings_as_errors=false'
if [[ -n "${DAWN_MAC_SDK_PATH:-}" ]]; then
  if [[ ! -f "$DAWN_MAC_SDK_PATH/SDKSettings.json" ]]; then
    echo "DAWN_MAC_SDK_PATH is not a macOS SDK: $DAWN_MAC_SDK_PATH" >&2
    exit 1
  fi
  GN_DEFINES+=" mac_sdk_path=\"$DAWN_MAC_SDK_PATH\""
fi
export GN_DEFINES
export CEF_ARCHIVE_FORMAT=tar.bz2

# The distribution is made below: automate-git.py does not pass --no-symbols to a
# minimal-only distribution on this branch, and without dSYMs that step fails.
BUILD_FLAGS="--force-build --no-distrib"
if [[ "${DAWN_FETCH_ONLY:-0}" == "1" ]]; then
  BUILD_FLAGS="--no-build --no-distrib"
fi

echo "Building DawnCEF $CEF_CHECKOUT for macOS $MAC_ARCH with $BUILD_JOBS jobs"
echo "GN_DEFINES=$GN_DEFINES"

# shellcheck disable=SC2086
python3 "$AUTOMATE" \
  --download-dir="$BUILD_ROOT" \
  --depot-tools-dir="$DEPOT_TOOLS" \
  --branch=7680 \
  --url="$CEF_URL" \
  --checkout="$CEF_CHECKOUT" \
  --cef-checkout-branch=7680 \
  --chromium-checkout="$CHROMIUM_CHECKOUT" \
  --no-chromium-history \
  "$ARCH_FLAG" \
  --no-debug-build \
  $BUILD_FLAGS \
  --build-jobs="$BUILD_JOBS" \
  --build-target="$BUILD_TARGETS" \
  --build-log-file \
  ${DAWN_AUTOMATE_ARGS:-}

if [[ "${DAWN_FETCH_ONLY:-0}" == "1" ]]; then
  exit 0
fi

CHROMIUM_SRC="$BUILD_ROOT/chromium/src"
if [[ ! -f "$CHROMIUM_SRC/chrome/VERSION" && \
      -f "$BUILD_ROOT/chromium_git/chromium/src/chrome/VERSION" ]]; then
  CHROMIUM_SRC="$BUILD_ROOT/chromium_git/chromium/src"
fi

# Minimal Release distribution without symbols, docs or archive. make_distrib.py
# formats the generated sources with depot_tools' clang-format.
case "$MAC_ARCH" in
  arm64) DISTRIB_PLATFORM="macosarm64" ;;
  x64) DISTRIB_PLATFORM="macosx64" ;;
esac
find "$CHROMIUM_SRC/cef/binary_distrib" -maxdepth 1 \
  -name "cef_binary_*_${DISTRIB_PLATFORM}_${DISTRIBUTION_SUFFIX}_minimal*" \
  -exec rm -rf {} + 2>/dev/null || true
(
  cd "$CHROMIUM_SRC/cef/tools"
  PATH="$DEPOT_TOOLS:$PATH" python3 make_distrib.py \
    --output-dir="$CHROMIUM_SRC/cef/binary_distrib" \
    --allow-partial \
    --ninja-build \
    "$ARCH_FLAG" \
    --minimal \
    --distrib-subdir-suffix="$DISTRIBUTION_SUFFIX" \
    --no-docs \
    --no-symbols \
    --no-archive
)

DISTRIB_DIRS=()
while IFS= read -r dir; do
  DISTRIB_DIRS+=("$dir")
done < <(find "$CHROMIUM_SRC/cef/binary_distrib" -mindepth 1 -maxdepth 1 -type d \
  -name "cef_binary_*_${DISTRIB_PLATFORM}_${DISTRIBUTION_SUFFIX}_minimal")
if (( ${#DISTRIB_DIRS[@]} != 1 )); then
  echo "Expected one $DISTRIB_PLATFORM distribution, found ${#DISTRIB_DIRS[@]}." >&2
  exit 1
fi
DISTRIB_DIR="${DISTRIB_DIRS[0]}"

# --allow-partial lets make_distrib.py write a distribution without the Release
# files when the build output is missing, so check that everything is there.
case "$MAC_ARCH" in
  arm64) MACHO_ARCH="arm64" ;;
  x64) MACHO_ARCH="x86_64" ;;
esac
FRAMEWORK_DIR="$DISTRIB_DIR/Release/Chromium Embedded Framework.framework"
FRAMEWORK_BINARY="$FRAMEWORK_DIR/Chromium Embedded Framework"
EXPECTED_REVISION="$(awk -F= '$1 == "codec.revision" { print $2 }' \
  "$SCRIPT_DIR/dawn-codec-build.properties")"
for path in \
  "$DISTRIB_DIR/CMakeLists.txt" \
  "$DISTRIB_DIR/cmake/FindCEF.cmake" \
  "$DISTRIB_DIR/include/cef_version.h" \
  "$DISTRIB_DIR/libcef_dll/CMakeLists.txt" \
  "$DISTRIB_DIR/dawn-codec-build.properties" \
  "$FRAMEWORK_BINARY" \
  "$FRAMEWORK_DIR/Libraries/libEGL.dylib" \
  "$FRAMEWORK_DIR/Libraries/libGLESv2.dylib" \
  "$FRAMEWORK_DIR/Libraries/libcef_sandbox.dylib" \
  "$FRAMEWORK_DIR/Libraries/libvk_swiftshader.dylib" \
  "$FRAMEWORK_DIR/Libraries/vk_swiftshader_icd.json" \
  "$FRAMEWORK_DIR/Resources/Info.plist" \
  "$FRAMEWORK_DIR/Resources/chrome_100_percent.pak" \
  "$FRAMEWORK_DIR/Resources/chrome_200_percent.pak" \
  "$FRAMEWORK_DIR/Resources/resources.pak" \
  "$FRAMEWORK_DIR/Resources/icudtl.dat" \
  "$FRAMEWORK_DIR/Resources/v8_context_snapshot.$MACHO_ARCH.bin" \
  "$FRAMEWORK_DIR/Resources/en.lproj/locale.pak"; do
  if [[ ! -s "$path" ]]; then
    echo "The distribution is incomplete: ${path#"$DISTRIB_DIR/"} is missing or empty." >&2
    exit 1
  fi
done
if [[ "$(lipo -archs "$FRAMEWORK_BINARY")" != "$MACHO_ARCH" ]]; then
  echo "The framework is not a single $MACHO_ARCH slice: $(lipo -archs "$FRAMEWORK_BINARY")" >&2
  exit 1
fi
if ! grep -Fqx "codec.revision=$EXPECTED_REVISION" "$DISTRIB_DIR/dawn-codec-build.properties"; then
  echo "The distribution marker does not name $EXPECTED_REVISION." >&2
  exit 1
fi

# No OpenH264: both GN args must resolve to false, and no OpenH264 or WebRTC
# software H.264 encoder code may be linked into the framework.
for arg in media_use_openh264 rtc_use_h264; do
  value="$(cd "$CHROMIUM_SRC" && "$CHROMIUM_SRC/buildtools/mac/gn" args \
    "out/$OUT_CONFIG" --list="$arg" --short || true)"
  if [[ "$value" != "$arg = false" ]]; then
    echo "$arg must be false: ${value:-not declared}" >&2
    exit 1
  fi
done
OPENH264_MATCHES="$(find "$FRAMEWORK_DIR" -type f \
  \( -name "Chromium Embedded Framework" -o -name "*.dylib" \) -print0 |
  xargs -0 env LC_ALL=C grep -a -o -E 'OpenH264|H264EncoderImpl|OpenH264VideoEncoder' |
  sort | uniq -c || true)"
if [[ -n "$OPENH264_MATCHES" ]]; then
  echo "OpenH264 is linked into the framework:" >&2
  echo "$OPENH264_MATCHES" >&2
  exit 1
fi
echo "Distribution complete, OpenH264 absent: $DISTRIB_DIR"

if [[ "${DAWN_RUN_MEDIA_TESTS:-0}" == "1" ]]; then
  MEDIA_TESTS="$CHROMIUM_SRC/out/$OUT_CONFIG/media_unittests"
  if [[ ! -x "$MEDIA_TESTS" ]]; then
    echo "media_unittests was not produced: $MEDIA_TESTS" >&2
    exit 1
  fi

  # The AudioToolbox suite runs sfx.m4a (AAC-LC, /0) and the three upstream
  # xHE-AAC fixtures (/1-/3). The 29.4 kHz mono fixture (/2) declares an unknown
  # channel layout while AudioToolbox reports mono, so the fixture's own setup
  # check fails for every case that loads it: all of /2, and the Reinitialize
  # cases of /1 and /3, which switch to it. Those are excluded; everything else
  # decodes and checks timestamps (and hashes for AAC-LC).
  # Dawn_AdtsFramedAac decodes sfx.m4a again with an ADTS header on every frame,
  # as Media Source delivers it, and expects the same audio.
  # The FFmpegDemuxer cases check that an MP4 AAC track survives demuxing without FFmpeg's AAC decoder.
  AUDIO_TOOLBOX_FILTER='AudioToolbox/*:FFmpegDemuxerTest.Dawn_*:FFmpegDemuxerTest.Read_Mp4_Media_Track_Info-AudioToolbox/AudioDecoderTest.*/2:AudioToolbox/AudioDecoderTest.Reinitialize_*/1:AudioToolbox/AudioDecoderTest.Reinitialize_*/3'
  "$MEDIA_TESTS" \
    --gtest_filter="$AUDIO_TOOLBOX_FILTER" \
    --test-launcher-jobs=1
fi

find "$CHROMIUM_SRC/cef/binary_distrib" \
  -maxdepth 1 -name "*$DISTRIBUTION_SUFFIX*" -print

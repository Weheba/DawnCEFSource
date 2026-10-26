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
CEF_CHECKOUT="${DAWN_CEF_CHECKOUT:-dawn-native-codecs.4}"
CHROMIUM_CHECKOUT="refs/tags/146.0.7680.179"
DISTRIBUTION_SUFFIX="dawn-native-codecs.4"
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

# The codec configuration matches the Windows build. The remaining args only
# reduce build memory and time and do not change the generated code:
#   symbol_level=0 / enable_dsyms=false: no debug info or dSYMs (the
#     distribution ships without symbols either way).
#   concurrent_links=1: one link at a time; the framework link alone needs
#     several GB.
#   treat_warnings_as_errors=false: Xcode SDKs newer than this Chromium branch
#     add deprecation warnings.
GN_DEFINES='is_official_build=true proprietary_codecs=true media_use_ffmpeg=true ffmpeg_branding="Chromium" use_thin_lto=false chrome_pgo_phase=0'
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

BUILD_FLAGS="--force-build --force-distrib"
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
  --minimal-distrib-only \
  --no-distrib-symbols \
  --no-distrib-docs \
  --distrib-subdir-suffix="$DISTRIBUTION_SUFFIX" \
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

if [[ "${DAWN_RUN_MEDIA_TESTS:-0}" == "1" ]]; then
  MEDIA_TESTS="$CHROMIUM_SRC/out/$OUT_CONFIG/media_unittests"
  if [[ ! -x "$MEDIA_TESTS" ]]; then
    echo "media_unittests was not produced: $MEDIA_TESTS" >&2
    exit 1
  fi

  # The upstream 29.4 kHz xHE-AAC fixture declares an unsupported layout, but
  # AudioToolbox resolves it to mono. Keep every decode case for that fixture
  # and exclude only the three tests whose sole failure is that config value.
  # The FFmpegDemuxer cases check that an MP4 AAC track survives demuxing without FFmpeg's AAC decoder.
  AUDIO_TOOLBOX_FILTER='AudioToolbox/*:FFmpegDemuxerTest.Dawn_*:FFmpegDemuxerTest.Read_Mp4_Media_Track_Info-AudioToolbox/AudioDecoderTest.EncryptedBuffer/2:AudioToolbox/AudioDecoderTest.DecodeEOSFirst/2:AudioToolbox/AudioDecoderTest.Reset/2'
  "$MEDIA_TESTS" \
    --gtest_filter="$AUDIO_TOOLBOX_FILTER" \
    --test-launcher-jobs=1
fi

find "$CHROMIUM_SRC/cef/binary_distrib" \
  -maxdepth 1 -name "*$DISTRIBUTION_SUFFIX*" -print

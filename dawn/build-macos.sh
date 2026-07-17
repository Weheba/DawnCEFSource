#!/usr/bin/env bash
set -euo pipefail

BUILD_ROOT="${1:-$HOME/DawnCEFBuild}"
CEF_URL="${DAWN_CEF_URL:-https://github.com/Weheba/DawnCEFSource.git}"
CEF_CHECKOUT="${DAWN_CEF_CHECKOUT:-dawn-native-codecs.2}"
CHROMIUM_CHECKOUT="refs/tags/146.0.7680.179"
DISTRIBUTION_SUFFIX="dawn-native-codecs.2"
REQUIRED_KB=$((155 * 1024 * 1024))
BUILD_TARGETS="cefclient"

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
if (( AVAILABLE_KB < REQUIRED_KB )); then
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOMATE="$SCRIPT_DIR/../tools/automate/automate-git.py"
DEPOT_TOOLS="$BUILD_ROOT/depot_tools"

export CEF_ARCHIVE_FORMAT=tar.bz2
export GN_DEFINES='is_official_build=true proprietary_codecs=true media_use_ffmpeg=true ffmpeg_branding="Chromium" use_thin_lto=false symbol_level=1 chrome_pgo_phase=0'

python3 "$AUTOMATE" \
  --download-dir="$BUILD_ROOT" \
  --depot-tools-dir="$DEPOT_TOOLS" \
  --branch=7680 \
  --url="$CEF_URL" \
  --checkout="$CEF_CHECKOUT" \
  --chromium-checkout="$CHROMIUM_CHECKOUT" \
  --no-chromium-history \
  --arm64-build \
  --no-debug-build \
  --force-build \
  --build-target="$BUILD_TARGETS" \
  --force-distrib \
  --minimal-distrib-only \
  --no-distrib-symbols \
  --no-distrib-docs \
  --distrib-subdir-suffix="$DISTRIBUTION_SUFFIX" \
  --build-log-file

if [[ "${DAWN_RUN_MEDIA_TESTS:-0}" == "1" ]]; then
  MEDIA_TESTS="$BUILD_ROOT/chromium_git/chromium/src/out/Release_GN_arm64/media_unittests"
  if [[ ! -x "$MEDIA_TESTS" ]]; then
    echo "media_unittests was not produced: $MEDIA_TESTS" >&2
    exit 1
  fi
  "$MEDIA_TESTS" \
    --gtest_filter='AudioToolbox/*' \
    --test-launcher-jobs=1
fi

find "$BUILD_ROOT/chromium_git/chromium/src/cef/binary_distrib" \
  -maxdepth 1 -name "*$DISTRIBUTION_SUFFIX*" -print

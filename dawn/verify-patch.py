#!/usr/bin/env python3
"""Verify that the Dawn Chromium codec patch applies to a source checkout."""

from __future__ import annotations

import argparse
import pathlib
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "chromium_src",
        type=pathlib.Path,
        help="Path to the Chromium src directory pinned to 146.0.7680.179",
    )
    args = parser.parse_args()

    chromium_src = args.chromium_src.resolve()
    patch_path = (
        pathlib.Path(__file__).resolve().parents[1]
        / "patch"
        / "patches"
        / "dawn_native_mp4_codecs.patch"
    )
    if not (chromium_src / "media" / "BUILD.gn").is_file():
        parser.error(f"not a Chromium source root: {chromium_src}")

    result = subprocess.run(
        ["git", "apply", "-p0", "--check", "--verbose", str(patch_path)],
        cwd=chromium_src,
        check=False,
    )
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

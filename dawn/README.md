# Dawn native MP4 codec build

This branch pins the CEF 146 source used by Dawn and carries one Chromium
patch, `dawn_native_mp4_codecs.patch`.

The build intentionally uses:

```text
proprietary_codecs=true
media_use_ffmpeg=true
ffmpeg_branding="Chromium"
```

`media_use_ffmpeg` keeps Chromium's MP4 demuxing path. The Chromium-branded
FFmpeg build does not contain Chrome's proprietary AAC or H.264 decoders.
Decode is delegated to the operating system:

| Platform | H.264 | AAC-LC / HE-AAC | xHE-AAC |
| --- | --- | --- | --- |
| Windows | D3D11/DXVA | Media Foundation | Media Foundation on Windows 11 22H2+ |
| macOS | VideoToolbox | AudioToolbox | AudioToolbox |

The patch also removes Chromium's build-time assertion that otherwise rejects
this configuration. It does not add FFmpeg codec implementations or change
CEF's public API.

Every generated binary distribution contains
`dawn-codec-build.properties`. DawnJCEF refuses custom `CEF_ROOT` inputs that
do not contain this marker with the expected source pins and codec revision.

## Source pins

- CEF commit: `82195616d8405e6081a0d90924707b82aa9e4141`
- Chromium: `refs/tags/146.0.7680.179`
- CEF/Chromium release branch: `7680`
- Immutable source tag: `dawn-native-codecs.3.1`

Keep the CEF and Chromium pins fixed when rebuilding this revision. A Chromium
upgrade requires reapplying the patch, compiling both target platforms, and
rerunning real H.264/AAC-LC playback through JCEF.

Revision 3 keeps the production decoder configuration from revision 2 and
corrects the AAC-LC regression fixture to use the MP4/M4A demuxer that this
intentionally reduced FFmpeg build retains. It also keeps custom tagged
checkouts on the local `7680` branch so CEF version generation remains valid.

## Windows build

Requirements:

- Windows 10 or newer
- Visual Studio 2022 with Desktop development with C++
- Windows 11 SDK 10.0.26100 with the x64 DirectX compiler/redist files
- 16 GB RAM minimum, 32 GB recommended
- 155 GB free on a short build path with no spaces

After the Chromium checkout exists, interrupted builds may resume with at
least 100 GB still free. The source tree already accounts for part of the
fresh-build disk budget at that point.

From PowerShell:

```powershell
.\dawn\build-windows.ps1 -BuildRoot D:\DawnCEFBuild
```

The Windows entrypoint defaults to four concurrent compile jobs to avoid
saturating desktop CPUs. Override this deliberately with `-BuildJobs`; the
value is forwarded to `autoninja -j` and Siso's local worker limit.
The Visual Studio 2022 installation discovered by `vswhere` is also pinned for
Chromium's GN toolchain, including when Build Tools is installed outside the
default `Program Files` location.

Add `-RunCefTests` for the upstream CEF test suite. The script creates a
Release x64 minimal binary distribution and places it under
`D:\DawnCEFBuild\chromium\src\cef\binary_distrib` by default because
`-BuildRoot` is passed directly to `automate-git.py` as `--download-dir`.
If you point `-BuildRoot` at an existing legacy `chromium_git` wrapper
directory, the script also resolves that layout when locating
`media_unittests.exe` and the generated distribution.
Add `-RunMediaTests` to compile and run the focused Media Foundation AAC-LC and
xHE-AAC decoder regression tests.

## macOS build

Requirements for this Chromium branch:

- macOS 15.6 or newer
- Xcode 26.0 or newer selected with `xcode-select`
- 16 GB RAM minimum, 32 GB recommended
- 155 GB free

```bash
./dawn/build-macos.sh "$HOME/DawnCEFBuild"
```

The script builds a Release arm64 minimal binary distribution.
Set `DAWN_RUN_MEDIA_TESTS=1` to compile and run the equivalent AudioToolbox
AAC-LC and xHE-AAC decoder regression tests.

The macOS gate runs 45 AudioToolbox cases. It excludes three configuration-only
assertions for Chromium's 29.4 kHz xHE-AAC fixture because the fixture expects
an unknown channel layout while AudioToolbox resolves the stream as mono. The
remaining tests retain decode, reset, and lifecycle coverage for that fixture.

## Verification

The build is not accepted based on compilation alone. For every platform:

1. Build DawnJCEF against this binary distribution.
2. Confirm `video/mp4; codecs="avc1.64001f, mp4a.40.2"` is reported as playable.
3. Play the forced Adforge video creative through the Dawn ad rail.
4. Confirm `loadeddata`, `playing`, advancing `currentTime`, and non-empty video
   dimensions in DevTools.
5. Confirm the media internals identify D3D11/Media Foundation on Windows or
   VideoToolbox/AudioToolbox on macOS.
6. Confirm the package contains Chromium-branded FFmpeg only and does not ship
   Chrome's proprietary FFmpeg decoder build.

Codec and patent licensing remains a release/legal review item even though the
decoder implementations are provided by the operating system.

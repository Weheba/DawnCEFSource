# Dawn native MP4 codec build

This branch pins the CEF 146 source used by Dawn and carries one Chromium
patch, `dawn_native_mp4_codecs.patch`.

The build intentionally uses:

```text
proprietary_codecs=true
media_use_ffmpeg=true
ffmpeg_branding="Chromium"
media_use_openh264=false
```

`media_use_ffmpeg` keeps Chromium's MP4 demuxing path. The Chromium-branded
FFmpeg build does not contain Chrome's proprietary AAC or H.264 decoders.
Decode is delegated to the operating system:

| Platform | H.264 | AAC-LC / HE-AAC | xHE-AAC |
| --- | --- | --- | --- |
| Windows | D3D11/DXVA | Media Foundation | Media Foundation on Windows 11 22H2+ |
| macOS | VideoToolbox | AudioToolbox | AudioToolbox |

`media_use_openh264=false` leaves out the OpenH264 software H.264 encoder that
`proprietary_codecs` otherwise turns on for WebCodecs, MediaRecorder and WebRTC
(`rtc_use_h264` follows it). Dawn's pages and ads only decode video. H.264
encoding is left to the operating system's encoder where a page asks for it.
Both build scripts fail when either GN arg resolves to anything but `false`, or
when `OpenH264`, `H264EncoderImpl` or `OpenH264VideoEncoder` appears in a
shipped binary.

The patch also removes Chromium's build-time assertion that otherwise rejects
this configuration. It does not add FFmpeg codec implementations or change
CEF's public API.

The patch also gives MP4 AAC tracks a sample format in
`AVCodecContextToAudioDecoderConfig` (`media/ffmpeg/ffmpeg_common.cc`).
Chromium-branded FFmpeg has no AAC decoder, so it never fills `sample_fmt`, and
`FFmpegDemuxer` dropped every AAC track of a plain (`src=`) MP4 as an invalid
config ("skipping invalid or unsupported audio track") before Media Foundation
or AudioToolbox was ever asked. H.264 still played, so clips and creatives were
silent rather than broken. Media Source playback was not affected, because
Chromium's own MP4 parser builds that config. `FFmpegDemuxerTest.Dawn_*` covers
it.

Every generated binary distribution contains
`dawn-codec-build.properties`. DawnJCEF refuses custom `CEF_ROOT` inputs that
do not contain this marker with the expected source pins and codec revision.

## Source pins

- CEF commit: `82195616d8405e6081a0d90924707b82aa9e4141`
- Chromium: `refs/tags/146.0.7680.179`
- CEF/Chromium release branch: `7680`
- Immutable source tag: `dawn-native-codecs.5` (revision 3: `dawn-native-codecs.3.1`; revision 4 was not released)

Keep the CEF and Chromium pins fixed when rebuilding this revision. A Chromium
upgrade requires reapplying the patch, compiling both target platforms, and
rerunning real H.264/AAC-LC playback through JCEF.

Revision 3 keeps the production decoder configuration from revision 2 and
corrects the AAC-LC regression fixture to use the MP4/M4A demuxer that this
intentionally reduced FFmpeg build retains. It also keeps custom tagged
checkouts on the local `7680` branch so CEF version generation remains valid.

Revision 4 adds the `ffmpeg_common.cc` AAC config fix, so plain `src=` MP4s
keep their AAC track. It is the first revision built for macOS, and it also
drops the ADTS header that Chromium's MP4 parser puts on every AAC frame of a
Media Source stream before the frame reaches AudioToolbox (`AdtsHeaderSize` in
`audio_toolbox_audio_decoder.cc`). AudioToolbox is set up for raw access units,
so without it every Media Source AAC stream failed with
`AudioConverterFillComplexBuffer() failed` ('bada'). Media Foundation on Windows
receives the same headers; that path is unchanged in this revision.

Revision 5 is revision 4 without OpenH264 (`media_use_openh264=false`; revision
3 and 4 binaries contain it). The build scripts also check that the
distribution is complete, because `make_distrib.py --allow-partial` otherwise
writes one without the Release files when build output is missing. The macOS
media tests add `Dawn_AdtsFramedAac`, which decodes `sfx.m4a` a second time with
an ADTS header on every frame, as Media Source delivers it, and expects the same
audio.

Revision 5 also fixes HE-AAC on macOS. For an HE-AAC or HE-AAC v2 config,
AudioToolbox's `kAudioFormatProperty_FormatInfo` describes only the AAC-LC
core: half the sample rate and 1024 frames per access unit, without SBR or PS.
`AudioToolboxAudioDecoder` labelled that core with the stream's sample rate, so
HE-AAC in MP4 played at twice its speed and pitch. It now decodes the richest
layer in `kAudioFormatProperty_FormatList` that the system can decode, and it
labels output with the rate the converter actually produces.
`AudioToolboxHeAacTest.Dawn_DecodesSbrLayer` decodes eight HE-AAC access units
and expects 2048 frames at 48 kHz from each one.

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
DAWN_MAC_ARCH=x64 ./dawn/build-macos.sh "$HOME/DawnCEFBuild"
```

The script builds a Release minimal binary distribution for arm64, or for x64
(cross-compiled on Apple silicon) with `DAWN_MAC_ARCH=x64`. Both architectures
share one Chromium checkout. It defaults to six compile jobs and one link at a
time, without debug info, so it fits a 16 GB Mac; `DAWN_BUILD_JOBS` overrides
the job count. Re-running the script resumes an interrupted build;
`DAWN_AUTOMATE_ARGS="--no-update"` skips the source sync when resuming, and
`DAWN_MAC_SDK_PATH` selects a macOS SDK other than the selected Xcode's.
Set `DAWN_RUN_MEDIA_TESTS=1` to compile and run the equivalent AudioToolbox
AAC-LC and xHE-AAC decoder regression tests.

The macOS gate runs the AudioToolbox suite for `sfx.m4a` (AAC-LC) and
Chromium's three xHE-AAC fixtures, plus the FFmpegDemuxer AAC cases. Chromium's
29.4 kHz mono xHE-AAC fixture declares an unknown channel layout while
AudioToolbox reports mono, so the fixture's own setup check fails wherever it is
loaded: every case of that fixture and the Reinitialize cases that switch to it.
Those are excluded; the other cases decode and check timestamps.

## Verification

The build is not accepted based on compilation alone. For every platform:

1. Build DawnJCEF against this binary distribution.
2. Confirm `video/mp4; codecs="avc1.64001f, mp4a.40.2"` is reported as playable.
   That alone does not prove AAC decodes: also play an H.264 + AAC-LC MP4
   through a plain `src=` and confirm `webkitAudioDecodedByteCount` grows and
   the player's audio decoder is MediaFoundationAudioDecoder or
   AudioToolboxAudioDecoder.
3. Play the forced Adforge video creative through the Dawn ad rail.
4. Confirm `loadeddata`, `playing`, advancing `currentTime`, and non-empty video
   dimensions in DevTools.
5. Confirm the media internals identify D3D11/Media Foundation on Windows or
   VideoToolbox/AudioToolbox on macOS.
6. Confirm the package contains Chromium-branded FFmpeg only and does not ship
   Chrome's proprietary FFmpeg decoder build.

Codec and patent licensing remains a release/legal review item even though the
decoder implementations are provided by the operating system.

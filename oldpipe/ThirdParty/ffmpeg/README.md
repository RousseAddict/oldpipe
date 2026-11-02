# FFmpeg 7.1.5 — player POC

A minimal static build of FFmpeg for `Networking/ffplayer.c`. Fat libraries, armv7 + arm64.
License: LGPL 2.1 or later (configured without `--enable-gpl`), compatible with oldpipe's GPL-3.0.

## Provenance

- Source: `https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz`,
  SHA-256 `de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f`.
- Cross-checked against GitHub's `FFmpeg/FFmpeg` tag `n7.1.5`: the two trees are identical apart
  from git metadata (`.gitignore`, `.gitattributes`) and the tarball's `VERSION` file.

## Security scan (2026-10-30)

- No binary files besides `tests/reference.pnm`, a test image.
- Nothing in `configure`, the Makefiles or `ffbuild/` downloads, decodes or evaluates anything.
- No process spawning (`system`, `popen`, `exec*`, `fork`, `posix_spawn`) in the compiled libraries.
- No hard-coded hosts beyond documentation comments. The one odd-looking domain,
  `flash1.bogulus.cfd`, is a comment in `hls.c`'s allowed-extension list.
- `getenv` only picks log colours (`TERM`, `AV_LOG_FORCE_*`); the LADSPA filter that reads
  `HOME` is not compiled in.

## What is in it

Demuxers `mov`, `mpegts`, `hls`, `aac`; decoders `h264`, `aac`; parsers `h264`, `aac`; protocols
`file`, `http`, `tcp`; filters `atempo`, `aformat`, `aresample` (plus the built-in
`abuffer`/`abuffersink`); libswscale and libswresample. No external library except zlib
(`--disable-autodetect`): no SecureTransport, VideoToolbox, AudioToolbox or iconv.

## How it was built

`scripts/build-ffmpeg.sh` (armv7, NEON, `-miphoneos-version-min=6.0`) and
`scripts/build-ffmpeg-arm64.sh` (arm64, `-miphoneos-version-min=7.0`), run as they are on SERV2
(Xcode 13.2.1, clang's integrated assembler; no gas-preprocessor), then `lipo -create` per
library. They expect the source unpacked at `~/Documents/ios6-app/ffpoc/src/ffmpeg-7.1.5`.

Two things in them matter for old iOS:

- `-D_FORTIFY_SOURCE=0`: iOS 5 and 6 do not export every `___*_chk` wrapper.
- `HAVE_CLOCK_GETTIME` is forced to 0 in `config.h` after configure. `clock_gettime` is iOS 10+,
  and configure only checks that it links. libavutil falls back to `gettimeofday`.

iOS 5.1.1 also lacks two helpers the libraries call, `__extendhfsf2` (swscale) and
`__fpclassifyd` (libavutil); `ffplayer.c` defines both. Every other import was checked against the
iOS 5.1.1 dyld shared cache.

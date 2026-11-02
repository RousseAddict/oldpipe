#!/bin/bash
# build-ffmpeg.sh — minimal FFmpeg 7.1.5 for the oldpipe player POC (arm64 slice, iOS 7+ 64-bit devices).
# Runs ON SERV2. Output: ~/Documents/ios6-app/ffpoc/out/{lib,include}
#
# Only what playing a YouTube stream needs: MP4 / MPEG-TS / HLS demux over file or
# plain HTTP (StreamProxy is loopback HTTP), H.264 + AAC decode, swscale for
# YUV->BGRA, swresample, and atempo for pitch-preserving speed.
set -e
set -o pipefail

SRC=~/Documents/ios6-app/ffpoc/src/ffmpeg-7.1.5
OUT=~/Documents/ios6-app/ffpoc/out-arm64
BUILD=~/Documents/ios6-app/ffpoc/build-arm64
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)

# 6.0 rather than 5.0: configure LINKS its test programs, and a 5.0 link wants
# LC_UNIXTHREAD + a crt1.o the SDK does not ship. The app's own link is what
# decides weak imports (-ios_version_min 5.0 in build-ios5.sh).
# _FORTIFY_SOURCE=0: ___strlcpy_chk & co. do not exist in iOS 5's libSystem.
CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=7.0 -D_FORTIFY_SOURCE=0"
LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=7.0"

rm -rf "$BUILD" "$OUT"; mkdir -p "$BUILD" "$OUT"
cd "$BUILD"

"$SRC/configure" \
  --prefix="$OUT" \
  --enable-cross-compile --target-os=darwin --arch=aarch64 \
  --cc="$CC" --sysroot="$SDK" \
  --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
  --enable-static --disable-shared \
  --disable-programs --disable-doc --disable-debug \
  --disable-autodetect --enable-zlib \
  --disable-avdevice --disable-postproc \
  --disable-everything \
  --enable-network \
  --enable-protocol=file,http,tcp \
  --enable-demuxer=mov,mpegts,hls,aac \
  --enable-decoder=h264,aac \
  --enable-parser=h264,aac \
  --enable-filter=atempo,abuffer,abuffersink,aformat,aresample \
  --enable-swscale --enable-swresample --enable-avfilter \
  2>&1 | tail -25

# clock_gettime is iOS 10+. configure only checks that it LINKS (it does, against
# the 15.2 SDK), and the app's -ios_version_min 5.0 link would merely weak-import
# it — a NULL call on iOS 5. libavutil falls back to gettimeofday without it.
sed -i '' 's/^#define HAVE_CLOCK_GETTIME 1/#define HAVE_CLOCK_GETTIME 0/' config.h
echo "--- config.h availability-sensitive HAVE_ entries:"
grep -E "HAVE_(CLOCK_GETTIME|ARC4RANDOM|GETENTROPY|GETRANDOM|POSIX_MEMALIGN|PTHREAD_SET|SYSCTL|NANOSLEEP|USLEEP|MACH_ABSOLUTE|NEON |INLINE_ASM |ARMV7 |VFP )" config.h

make -j4 2>&1 | grep -E "error|warning: .*availab|^make.*Error" | head -30 || true
make install 2>&1 | tail -3
ls -la "$OUT/lib"
for l in "$OUT"/lib/*.a; do echo "$(basename $l): $(lipo -info $l | sed 's/.*: //')"; done

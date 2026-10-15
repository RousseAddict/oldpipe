#!/bin/bash
# build-shims.sh — builds the three iOS 5 compatibility shims into ./lib.
#
# WHY THESE EXIST
# The app's own iOS 6+ API use is fixed in Swift behind #if IOS5_TARGET, but the
# Swift 5.1.5 runtime dylibs we ship are prebuilt binaries from the toolchain —
# we cannot recompile them, and they import a few symbols iOS 5 does not export.
# dyld would fail the whole app at launch.
#
# Each shim therefore (a) -reexport's the REAL system library, so every symbol
# iOS 5 already has passes straight through, and (b) defines locally only the
# handful that are missing. build-ios5.sh then points the runtime dylibs at the
# shims with `install_name_tool -change`, which rewrites just the path string in
# LC_LOAD_DYLIB. Mach-O records a library ordinal per symbol and that ordinal is
# untouched, so everything that already resolved keeps resolving (now via the
# reexport) and only the missing symbols come from the shim itself.
#
#   libS5                     libSystem.B   atomics + __mulodi4   libswiftCore
#   libFoundationCompat       Foundation    NSUUID                libswiftFoundation
#   libCoreFoundationCompat   CoreFoundation NSURLPathKey         libswiftFoundation
#
# The -compatibility_version values are NOT cosmetic. `install_name_tool -change`
# preserves the version the DEPENDENT recorded for the library it used to load,
# and dyld compares that against the shim's compatibility_version at load time
# (the mismatch message confusingly prints current_version). Each shim therefore
# has to advertise the same compatibility_version as the framework it stands in
# for, or the load is rejected. They are built armv7-only because every iOS 5
# device is armv7.

set -e
cd "$(dirname "$0")"
mkdir -p lib

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
COMMON="-arch armv7 -miphoneos-version-min=5.0 -O2 -isysroot $SDK -dynamiclib"

echo "[1/3] libS5.dylib (compiler-rt atomics + __mulodi4 for libswiftCore)"
# -fno-builtin: the names are clang builtins, and the definitions carry asm()
# labels to emit the real symbols.
clang $COMMON -fno-builtin \
  -I ../oldpipe/oldpipe/Networking \
  -install_name @loader_path/libS5.dylib \
  -compatibility_version 1.0.0 -current_version 1.0.0 \
  -Wl,-reexport-lSystem \
  -o lib/libS5.dylib src/libS5.c

echo "[2/3] libCoreFoundationCompat.dylib (NSURLPathKey)"
clang $COMMON -fno-objc-arc \
  -install_name @rpath/libCoreFoundationCompat.dylib \
  -compatibility_version 150.0.0 -current_version 1673.126.0 \
  -Wl,-reexport_framework,CoreFoundation \
  -o lib/libCoreFoundationCompat.dylib src/libCoreFoundationCompat.m

echo "[3/3] libFoundationCompat.dylib (NSUUID)"
# -Wno-objc-designated-initializers: NSUUID is implemented against the SDK's own
# @interface, so clang cannot see that every designated initializer is covered.
clang $COMMON -fno-objc-arc \
  -install_name @rpath/libFoundationCompat.dylib \
  -compatibility_version 300.0.0 -current_version 1673.126.0 \
  -Wl,-reexport_framework,Foundation \
  -Wno-objc-designated-initializers \
  -o lib/libFoundationCompat.dylib src/libFoundationCompat.m

echo
echo "--- exported symbols (must be exactly the missing set) ---"
for f in lib/*.dylib; do
  echo "$f:"
  nm -gU "$f" | sed 's/^/    /'
done

#!/bin/bash
# build-ios5.sh — builds oldpipe for iOS 5 and packages the IPA.
#
# Runs ON the build machine. It takes no credentials and hardcodes no checkout
# path: everything is derived from this script's own location, so it works from
# the worktree, from a fresh clone, or from wherever build.sh decides to put it.
# The thin SSH wrapper that drives it from a laptop stays outside the repo,
# because that is where the build server's host and password live.
#
#   ./ios5-shims/build-ios5.sh [Release|Debug]
#
# Output: build/oldpipe_ios5.ipa. Release is the default and owns the plain
# name, matching the ios6/7/8 targets; a Debug build is oldpipe_ios5_debug.ipa.
#
# HOW THIS DIFFERS FROM THE iOS 6/7/8 BUILDS
#   -D IOS5_TARGET         Swift guards for the iOS 6-only APIs (cell-class
#                          registry, UIRefreshControl, minimumScaleFactor,
#                          pull-to-refresh, AVAudioSession setActive:).
#   -ios_version_min 5.0   Makes ld emit LC_UNIXTHREAD rather than LC_MAIN
#                          (LC_MAIN is iOS 6+) and auto-weaken newer imports.
#                          Needs our own `start` (ios5_start.S) because modern
#                          SDKs ship no crt1.o -- and, because crt1.o also
#                          supplies __DATA,__program_vars, our own copy of that
#                          too (atomic_stubs.c).
#   -D_FORTIFY_SOURCE=0    Otherwise strlcpy/strlcat compile to ___strlcpy_chk
#                          and ___strlcat_chk, which iOS 5's libSystem does not
#                          export. It does have the mem*_chk variants.
#   ARCHS=armv7            Every iOS 5 device is armv7, and an arm64 slice
#                          cannot carry version-min 5.0 anyway.
#   three compat shims     libS5 / libFoundationCompat / libCoreFoundationCompat
#                          reexport the real libSystem / Foundation /
#                          CoreFoundation and add only what iOS 5 lacks. The
#                          prebuilt 5.1.5 runtime dylibs are repointed at them
#                          with install_name_tool -change.
#   class-bit strip        Swift tags its classes with the low bit of
#                          class_t.data; objc4-493 (iOS 5) does not mask it off
#                          and dies in its own initialiser. See
#                          strip-swift-class-bit.py for the full account.
set -e
set -o pipefail      # a BUILD FAILED piped through grep must abort, not
                     # silently repackage the previously-built .app

# Release is the default: it is what ships, so it gets the plain name and the
# odd Debug build is the one that carries a suffix.
CONFIG="${1:-Release}"
case "$CONFIG" in
  Release) IPA_NAME="oldpipe_ios5.ipa" ;;
  *)       IPA_NAME="oldpipe_ios5_$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]').ipa" ;;
esac

SHIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SHIM_DIR/.." && pwd)"
PROJECT_DIR="$ROOT/oldpipe"
IPA_DIR="$ROOT/build"
SHIMS="$SHIM_DIR/lib"
VENDORED_CORE="$SHIM_DIR/prebuilt/libswiftCore-ios5.dylib"
CURL_LIBS="$PROJECT_DIR/ThirdParty/curl/lib"
# Kept outside the tree so it is never mistaken for a build product, and so the
# normal build.sh DerivedData is never clobbered. Override if you need to.
DERIVED="${IOS5_DERIVED:-$HOME/Documents/ios6-app/ios5-derived}"
TOOLCHAIN_515="${IOS5_SWIFT515:-/Library/Developer/Toolchains/swift-5.1.5-RELEASE.xctoolchain/usr/lib/swift/iphoneos}"
TOOLCHAIN_ID="${IOS5_TOOLCHAIN_ID:-org.swift.563202208261a}"

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/oldpipe.app"
FWDIR="$APP/Frameworks"

echo "==> iOS 5 build: $CONFIG -> $IPA_NAME"
echo "    repo:    $ROOT"
echo "    derived: $DERIVED"

# ── 0. Preflight + build the compat shims ────────────────────────────────────
echo "[0/8] Preflight..."
[ -d "$TOOLCHAIN_515" ] || { echo "ERROR: Swift 5.1.5 runtime not at $TOOLCHAIN_515"; exit 1; }
for lib in libcurl.a libssl.a libcrypto.a; do
  [ -f "$CURL_LIBS/$lib" ] || { echo "ERROR: $CURL_LIBS/$lib not found."; exit 1; }
done
[ -f "$VENDORED_CORE" ] || { echo "ERROR: vendored runtime missing at $VENDORED_CORE"; exit 1; }
echo "      OK: curl/openssl static libs, 5.1.5 runtime, vendored libswiftCore"
echo "      building compat shims..."
"$SHIM_DIR/build-shims.sh" 2>&1 | grep -vE "^ld: warning: embedded dylibs" | sed 's/^/      /'
for shim in libS5.dylib libFoundationCompat.dylib libCoreFoundationCompat.dylib; do
  [ -f "$SHIMS/$shim" ] || { echo "ERROR: $SHIMS/$shim was not produced."; exit 1; }
done

# ── 1. Build ─────────────────────────────────────────────────────────────────
# OTHER_LDFLAGS has to restate the curl/ssl libs: assigning it on the command
# line REPLACES the project's value rather than appending to it.
echo "[1/8] xcodebuild ($CONFIG, armv7, -D IOS5_TARGET, -ios_version_min 5.0)..."
cd "$PROJECT_DIR"
xcodebuild clean build \
  -project oldpipe.xcodeproj \
  -scheme oldpipe \
  -sdk iphoneos \
  -configuration "$CONFIG" \
  -toolchain "$TOOLCHAIN_ID" \
  -derivedDataPath "$DERIVED" \
  ARCHS=armv7 \
  ONLY_ACTIVE_ARCH=NO \
  OTHER_SWIFT_FLAGS="-D IOS5_TARGET" \
  OTHER_CFLAGS="-DIOS5_TARGET -D_FORTIFY_SOURCE=0" \
  OTHER_LDFLAGS="-lcurl -lssl -lcrypto -lz -Wl,-ios_version_min,5.0" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED|CompileSwift )" | tail -20

# ── 2. Remove the Metal dylib (Metal is iOS 8+) ──────────────────────────────
echo "[2/8] Removing libswiftMetal.dylib..."
rm -f "$FWDIR/libswiftMetal.dylib"

# ── 3. Swap in the Swift 5.1.5 runtime ───────────────────────────────────────
echo "[3/8] Replacing dylibs with the 5.1.5 runtime..."
for f in "$FWDIR"/*.dylib; do
  name=$(basename "$f")
  [ -f "$TOOLCHAIN_515/$name" ] && cp "$TOOLCHAIN_515/$name" "$f"
done

# ── 3b. Vendored libswiftCore ────────────────────────────────────────────────
# The stock 5.1.5 runtime CANNOT work here, and not for want of trying. Swift
# tags its classes with the low bit of class_t.data; objc4-493.9 does not mask
# that bit and dies on the first class it walks, so step 6b clears it. But the
# Swift runtime tests the same bit to decide what is a Swift class, so stock
# then treats ours as pure Objective-C and aborts in swift_dynamicCastClassImpl.
# One field, two runtimes, opposite expectations.
#
# This build is a from-source rebuild of the 5.1.5 stdlib that resolves it with
# a side table (__swift5_ios5cls + swift_ios5_registerSwiftClass), so Swift
# learns Swift-ness without reading the bit. ios5-shims/prebuilt/README.md
# records where it came from, what was scanned, the approaches that failed, and
# what replacing it would take.
#
# It already targets @loader_path/libS5.dylib and is already version-min 5.0, so
# the repointing and vtool steps below are no-ops on it, and step 6b finds
# nothing left to strip.
echo "[3b/8] Installing the vendored libswiftCore (see prebuilt/README.md)..."
cp "$VENDORED_CORE" "$FWDIR/libswiftCore.dylib"

# ── 4. Install the compat shims ──────────────────────────────────────────────
echo "[4/8] Installing compat shims..."
cp "$SHIMS"/libS5.dylib "$SHIMS"/libFoundationCompat.dylib "$SHIMS"/libCoreFoundationCompat.dylib "$FWDIR/"

# ── 5. Repoint the prebuilt runtime at the shims ─────────────────────────────
# -change rewrites only the path in LC_LOAD_DYLIB. The per-symbol library
# ordinal is untouched, so everything that already resolved keeps resolving via
# the shim's reexport, and only the missing symbols come from the shim itself.
# The shims advertise matching compatibility_version values; dyld compares that
# field and would reject the load otherwise.
echo "[5/8] install_name_tool — repointing libswiftCore / libswiftFoundation..."
install_name_tool -change /usr/lib/libSystem.B.dylib @loader_path/libS5.dylib "$FWDIR/libswiftCore.dylib"
install_name_tool \
  -change /System/Library/Frameworks/Foundation.framework/Foundation @rpath/libFoundationCompat.dylib \
  -change /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation @rpath/libCoreFoundationCompat.dylib \
  "$FWDIR/libswiftFoundation.dylib"

# -ios_version_min 5.0 makes ld prefer the SDK's .tbd stubs over the toolchain's
# dylibs, so the main binary records absolute /usr/lib/swift/... paths instead of
# @rpath/... (the iOS 6/7/8 builds get @rpath, which is what works -- iOS 5 has
# no /usr/lib/swift). LC_RPATH already has @executable_path/Frameworks, so
# rewriting the ones we actually bundle is enough.
echo "      rewriting absolute /usr/lib/swift paths in the main binary..."
for f in "$FWDIR"/libswift*.dylib; do
  name=$(basename "$f")
  install_name_tool -change "/usr/lib/swift/$name" "@rpath/$name" "$APP/oldpipe" 2>/dev/null || true
done
if otool -L "$APP/oldpipe" | grep -q "^	/usr/lib/swift/"; then
  echo "      NOTE: still referencing /usr/lib/swift (weak, not bundled):"
  otool -L "$APP/oldpipe" | grep "^	/usr/lib/swift/"
fi

# ── 6. Version min + Info.plist ──────────────────────────────────────────────
# The main binary is NOT vtool'd: it already carries version-min 5.0 from the
# link and uses LC_UNIXTHREAD. Only the dylibs, which came from the 5.1.5
# toolchain at 7.0.
echo "[6/8] Patching dylib version min to 5.0 + Info.plist..."
for f in "$FWDIR"/*.dylib; do
  vtool -set-version-min ios 5.0 5.0 -output "$f" "$f" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 5.0" "$APP/Info.plist"

# Documents/ over USB file sharing: that is where the launch log is written, and
# without this the only way to retrieve it is a jailbreak file browser hunting
# for the container UUID. iOS 3.2+, and this build is iOS 5 only.
/usr/libexec/PlistBuddy -c "Delete :UIFileSharingEnabled" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIFileSharingEnabled bool true" "$APP/Info.plist"

# A URL scheme, so the app can be launched from a shell with `uiopen oldpipe://`.
# iOS 5 has no scriptable way to tap an icon, idevicedebug's protocol does not
# agree with 5.1.1's debugserver, and a shell launch of the binary never reaches
# SpringBoard -- so without this, every on-device test needs a human to tap. It
# handles no parameters and exists only in the iOS 5 build.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string rousseaddict.oldpipe" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string oldpipe" "$APP/Info.plist"

# Background audio (keeps playing when locked / backgrounded).
/usr/libexec/PlistBuddy -c "Delete :UIBackgroundModes" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes:0 string audio" "$APP/Info.plist"

# ── 6b. Strip Swift's is-Swift class bit ─────────────────────────────────────
# Must run BEFORE signing: it rewrites bytes in __DATA. Covers the executable
# AND every dylib -- the Swift runtime carries tagged classes of its own, and
# libobjc walks every loaded image, so stripping only the executable just moves
# the crash. strip-swift-class-bit.py explains the mechanism in full.
echo "[6b/8] Stripping Swift is-Swift class bit for objc4-493..."
echo -n "      oldpipe:"; python3 "$SHIM_DIR/strip-swift-class-bit.py" "$APP/oldpipe"
for f in "$FWDIR"/*.dylib; do
  out=$(python3 "$SHIM_DIR/strip-swift-class-bit.py" "$f")
  # only report dylibs that actually carried tagged classes
  case "$out" in *"bits-stripped=0 "*|*"nothing to do"*) ;; *) echo "      $(basename "$f"):$out" ;; esac
done

# ── 6c. Slim the bundle ──────────────────────────────────────────────────────
# Three kinds of dead weight, all of it shipped by default:
#
#   1. The 5.1.5 toolchain dylibs are fat (armv7 + armv7s + arm64). This target
#      is armv7-only and the iPhone 4 is armv7, so two of the three slices in
#      every one of them can never be mapped. That is the bulk of it.
#   2. A couple of overlays are copied in that nothing links against. The list
#      is computed, not hardcoded: a dylib goes only if no other dylib and not
#      the executable names it, so adding a framework later cannot silently
#      delete the overlay it needs.
#   3. The executable keeps its debug symbol table. Swift metadata lives in the
#      __swift5_* sections and ObjC names in the ObjC sections, so neither
#      reflection nor class lookup depends on the symbols being present.
#
# This runs before signing: every file touched here is signed in step 7.
echo "[6c/8] Slimming the bundle..."
before=$(du -sk "$APP" | cut -f1)

# 2 — drop overlays nothing references
for f in "$FWDIR"/*.dylib; do
  n=$(basename "$f")
  refs=0
  for g in "$FWDIR"/*.dylib "$APP/oldpipe"; do
    [ "$g" = "$f" ] && continue
    otool -L "$g" 2>/dev/null | grep -q "/$n" && refs=$((refs + 1))
  done
  if [ "$refs" = 0 ]; then
    echo "      unreferenced, dropping: $n"
    rm -f "$f"
  fi
done

# 1 — thin the fat dylibs to armv7
for f in "$FWDIR"/*.dylib; do
  case "$(lipo -archs "$f" 2>/dev/null)" in
    *\ *) lipo -thin armv7 "$f" -output "$f.thin" 2>/dev/null \
             && mv "$f.thin" "$f" || rm -f "$f.thin" ;;
  esac
done

# 3 — strip the executable's debug symbols
strip -S -x "$APP/oldpipe"

echo "      $((before / 1024))M -> $(($(du -sk "$APP" | cut -f1) / 1024))M"

# ── 7. Ad-hoc sign ───────────────────────────────────────────────────────────
# After install_name_tool / vtool / the strip, all of which invalidate a
# signature. installd still wants the structure to exist even with trust bypassed.
echo "[7/8] Ad-hoc signing..."
for f in "$FWDIR"/*.dylib; do codesign --force --sign - "$f"; done
codesign --force --sign - "$APP"

# ── 8. Package ───────────────────────────────────────────────────────────────
echo "[8/8] Packaging IPA..."
rm -rf "$IPA_DIR/Payload"; mkdir -p "$IPA_DIR/Payload"
cp -r "$APP" "$IPA_DIR/Payload/"
cd "$IPA_DIR"
rm -f "$IPA_NAME"
zip -r "$IPA_NAME" Payload > /dev/null && rm -rf Payload
ls -lh "$IPA_DIR/$IPA_NAME"

echo
echo "--- verification ---"
lipo -info "$APP/oldpipe"
otool -l "$APP/oldpipe" | grep -E "LC_UNIXTHREAD|LC_MAIN" || true
otool -l "$APP/oldpipe" | grep -A3 LC_VERSION_MIN | grep -E "version|sdk" || true
left=0
for f in "$APP/oldpipe" "$FWDIR"/*.dylib; do
  n=$(xcrun llvm-objdump --macho --objc-meta-data --arch armv7 "$f" 2>/dev/null | grep -c 'Swift class' || true)
  [ "$n" != "0" ] && { echo "  WARNING: $(basename "$f") still has $n tagged classes"; left=1; }
done
[ $left = 0 ] && echo "  class bit: clear across the whole bundle"
n=$(nm -arch armv7 -gU "$FWDIR/libswiftCore.dylib" 2>/dev/null | grep -c swift_ios5 || true)
if [ "$n" = "3" ]; then echo "  runtime: vendored libswiftCore in place (swift_ios5 x3)"
else echo "  ERROR: shipped libswiftCore is NOT the vendored one (swift_ios5=$n, want 3)"; exit 1; fi
echo "Done: $IPA_DIR/$IPA_NAME"

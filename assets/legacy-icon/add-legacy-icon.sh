#!/bin/bash
# add-legacy-icon.sh <path/to/oldpipe.app>
#
# Gives the iOS 5 and iOS 6 builds a rounded icon when they are installed from
# Cydia (issue #33). Run it after the Info.plist edits and BEFORE signing: it adds
# two files and an Info.plist entry, and both are sealed by the signature.
#
# WHY
# iOS 5/6 SpringBoard treats an icon differently depending on where the app lives:
#
#   /var/mobile/Applications  (an IPA install: AppSync, Filza, ideviceinstaller)
#       It takes the 57 pt icon, masks the corners, adds the gloss. Our opaque
#       square AppIcon is exactly right for this.
#   /Applications             (a Cydia install: the deb unpacks the .app there)
#       A "system" app. Its icon is drawn VERBATIM -- no mask, no gloss, no
#       shadow -- because Apple's own system apps ship pre-rendered icons (Safari's
#       is a 118x120 PNG with the corners, gloss and shadow already in it).
#       SpringBoard picks the listed file closest to that 59x60 pt canvas, which
#       for us was AppIcon60x60@2x: the square icon, shown square.
#
# Rounding AppIcon60x60 itself is not an option: iOS 7+ uses that same file and
# fills transparent corners with black (the bug the square icon fixed in 1ddb30d).
# So instead this adds ONE more candidate, pre-rendered at exactly 59x60 pt. The
# /Applications path takes it as an exact match; the IPA path still takes the
# 57 pt icon, as before. Verified on iOS 5.1.1 by decoding SpringBoard's own
# rendered-icon cache (Library/Caches/com.apple.IconsCache) for both paths.
#
# iPhone only: it is added to CFBundleIcons, not CFBundleIcons~ipad. The iPad's
# pre-rendered size on iOS 5/6 has not been measured, and a wrong guess could be
# picked by the iPad's masked path instead.
#
# Only the ios5 and ios6 pipelines call this. The ios7/ios8 IPAs never carry it.
# Regenerate the PNGs with precompose.swift (next to this script) if the icon changes.
set -e

APP="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$APP/Info.plist"
KEY=":CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles"

[ -f "$PLIST" ] || { echo "add-legacy-icon: no Info.plist in '$APP'" >&2; exit 1; }

cp "$DIR/AppIconLegacy.png" "$DIR/AppIconLegacy@2x.png" "$APP/"

# Append once, so running it twice on the same .app is harmless.
if /usr/libexec/PlistBuddy -c "Print $KEY" "$PLIST" | grep -qx '[[:space:]]*AppIconLegacy'; then
  echo "      legacy icon: already listed"
else
  /usr/libexec/PlistBuddy -c "Add $KEY: string AppIconLegacy" "$PLIST"
  echo "      legacy icon: AppIconLegacy added for iOS 5/6 /Applications installs"
fi

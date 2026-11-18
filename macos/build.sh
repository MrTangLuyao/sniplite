#!/bin/bash
# Build sniplite.app for macOS (Apple Silicon and Intel). Needs only the Xcode Command Line Tools:
#   xcode-select --install
# Output: macos/build/sniplite.app (and sniplite_<version>_macos.zip with --zip).
# SIGN_ID="Developer ID Application: ..." ./build.sh signs with your certificate instead of ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=1.3.3
APP=build/sniplite.app
ARCHS=${ARCHS:-"arm64 x86_64"}

bins=()
for a in $ARCHS; do
  # the native build system: the newer one fails on some Command Line Tools installs
  swift build -c release --arch "$a" --build-system native 2>/dev/null \
    || swift build -c release --arch "$a"
  bins+=(".build/$a-apple-macosx/release/SnipLite")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/sniplite"
strip -x "$APP/Contents/MacOS/sniplite"

# icon: the one of the Windows version, at every size macOS wants
ICONSET=build/sniplite.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256; do
  sips -z $s $s ../pics/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  if [ $d -le 256 ]; then sips -z $d $d ../pics/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null; fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/sniplite.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>sniplite</string>
  <key>CFBundleDisplayName</key><string>sniplite</string>
  <key>CFBundleIdentifier</key><string>io.github.mrtangluyao.sniplite</string>
  <key>CFBundleExecutable</key><string>sniplite</string>
  <key>CFBundleIconFile</key><string>sniplite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <!-- malloc returns the screen images of a capture to the system at once instead of caching
       them: about 15 MB between captures instead of 70, and a lower peak while capturing -->
  <key>LSEnvironment</key><dict><key>MallocLargeCache</key><string>0</string></dict>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
</dict>
</plist>
PLIST

# a fixed identity keeps macOS permissions across rebuilds: SIGN_ID, else the local certificate
# from ./make-cert.sh, else ad hoc (permissions must then be granted again after each build)
if [ -z "${SIGN_ID:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "sniplite Local Signing"; then
  SIGN_ID="sniplite Local Signing"
fi
codesign --force --deep --options runtime --sign "${SIGN_ID:--}" "$APP"
echo "signed with: ${SIGN_ID:-ad hoc}"
echo "built $APP ($(du -sh "$APP" | cut -f1), $(lipo -archs "$APP/Contents/MacOS/sniplite"))"

if [ "${1:-}" = "--zip" ]; then
  (cd build && rm -f "sniplite_${VERSION}_macos.zip" && ditto -c -k --keepParent sniplite.app "sniplite_${VERSION}_macos.zip")
  echo "packed build/sniplite_${VERSION}_macos.zip"
fi

#!/bin/zsh
# Builds Inkwell.app into $BUILD_DIR (default ./build).
#   ARCHS="arm64"        faster dev build (default: arm64 x86_64 universal)
set -euo pipefail
cd "${0:A:h}"

B=${BUILD_DIR:-build}
APP=$B/Inkwell.app
ARCHS=(${=ARCHS:-arm64 x86_64})
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" $B/obj

SDK=$(xcrun --show-sdk-path)
bins=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos14.0" -sdk "$SDK" \
    Sources/Core/*.swift Sources/App/*.swift -o "$B/obj/Inkwell-$arch"
  bins+=("$B/obj/Inkwell-$arch")
done
lipo -create $bins -output "$APP/Contents/MacOS/Inkwell"

# Icon
ICONSET=$B/obj/AppIcon.iconset
mkdir -p "$ICONSET"
swift Tools/make_icon.swift $B/obj/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s $B/obj/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) $B/obj/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Inkwell</string>
  <key>CFBundleDisplayName</key><string>Inkwell</string>
  <key>CFBundleIdentifier</key><string>local.inkwell.app</string>
  <key>CFBundleExecutable</key><string>Inkwell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Inkwell Notebook</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>local.inkwell.notebook</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>GoodNotes Notebook</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.goodnotesapp.goodnotes</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.goodnotesapp.goodnotes</string>
      <key>UTTypeDescription</key><string>GoodNotes Document</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>goodnotes</string></array></dict>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.inkwell.notebook</string>
      <key>UTTypeDescription</key><string>Inkwell Notebook</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>inkwell</string></array></dict>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>© 2026 Sanjit Mathur</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Inkwell records audio while you write, so you can play back what was said at any point in your notes.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Inkwell transcribes your recordings on this Mac so you can search what was said.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

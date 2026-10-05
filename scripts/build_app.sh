#!/bin/bash
# Builds DiskBuddy.app (release, arm64/host arch) next to this repo.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release 2>&1 | grep -v "^\s*xcrun" || true
BIN=$(swift build -c release --show-bin-path 2>/dev/null)/DiskBuddy
APP=DiskBuddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskBuddy"

ICONSET=$(mktemp -d)/AppIcon.iconset
swiftc -O scripts/make_icon.swift -o "$(dirname "$ICONSET")/make_icon" 2>/dev/null
"$(dirname "$ICONSET")/make_icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DiskBuddy</string>
  <key>CFBundleDisplayName</key><string>DiskBuddy</string>
  <key>CFBundleIdentifier</key><string>com.diskbuddy.recreation</string>
  <key>CFBundleExecutable</key><string>DiskBuddy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSDesktopFolderUsageDescription</key><string>DiskBuddy looks at your Desktop to find large and duplicate files.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DiskBuddy looks at your Documents to find large and duplicate files.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DiskBuddy lists your Downloads so you can clear old installers.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>DiskBuddy measures disk space on external volumes.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 && echo "signed (ad hoc)"
echo "Built $(pwd)/$APP"

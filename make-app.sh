#!/bin/bash
# Build TrackpadStudio.app — a local, double-clickable bundle.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=TrackpadStudio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$(swift build -c release --show-bin-path)/TrackpadStudio" "$APP/Contents/MacOS/"
cp docs/assets/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>TrackpadStudio</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>com.zaynjarvis.trackpadstudio</string>
	<key>CFBundleName</key><string>Trackpad Studio</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# Stable ad-hoc signature so TCC (Input Monitoring) grants stick to the app.
codesign --force -s - "$APP"

echo "Built $APP — double-click it, or: cp -r $APP /Applications/"

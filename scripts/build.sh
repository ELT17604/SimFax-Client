#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
mkdir -p "$ROOT/.build/module-cache" "$ROOT/release/SimuFax.app/Contents/MacOS" "$ROOT/release/SimuFax.app/Contents/Resources"
APP="$ROOT/release/SimuFax.app"
xcrun swiftc -O -target "$ARCH-apple-macos14.0" -module-cache-path "$ROOT/.build/module-cache" -parse-as-library "$ROOT/Sources/SimuFax.swift" -o "$APP/Contents/MacOS/SimuFax"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SimuFax</string>
<key>CFBundleIdentifier</key><string>uk.verstappen.simufax.client</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>SimuFax</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1.0.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
cp "$ROOT/Brand/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/SimuFax"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
test -x "$APP/Contents/MacOS/SimuFax"
(cd "$ROOT/release" && ditto -c -k --sequesterRsrc --keepParent SimuFax.app "SimuFax-macOS-$ARCH.zip")
printf 'Built: %s\n' "$APP"

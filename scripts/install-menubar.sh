#!/bin/bash
# Creates a macOS .app bundle for nudge menu bar mode
# Usage: ./scripts/install-menubar.sh

set -e

APP_NAME="Nudge"
APP_DIR="$HOME/Applications/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

echo "Building nudge..."
swift build -c release

echo "Creating $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS"

cp .build/release/nudge "$MACOS/nudge"

# Create a wrapper script that launches with --menu-bar
cat > "$MACOS/$APP_NAME" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/nudge" --menu-bar "$@"
WRAPPER
chmod +x "$MACOS/$APP_NAME"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.nudge.menubar</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo ""
echo "✅ Installed $APP_DIR"
echo "   Open it from Finder or run:"
echo "   open '$APP_DIR'"

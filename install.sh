#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "=================================================="
echo "  Installing OmniFS (Apple Silicon Native)"
echo "=================================================="

# 1. Compile in Release mode
echo "[1/4] Building OmniFS release binaries..."
swift build -c release

# 2. Package & Code-Sign Bundles
echo "[2/5] Packaging and code-signing bundles..."
mkdir -p "$DIR/OmniFS.prefPane/Contents/MacOS"
mkdir -p "$DIR/OmniFS.prefPane/Contents/Resources"
cp "$DIR/.build/release/libOmniFSPrefPane.dylib" "$DIR/OmniFS.prefPane/Contents/MacOS/OmniFS"
chmod +x "$DIR/OmniFS.prefPane/Contents/MacOS/OmniFS"
cp "$DIR/Resources/AppIcon.icns" "$DIR/OmniFS.prefPane/Contents/Resources/OmniFS.icns"
cp "$DIR/Resources/AppIcon_1024.png" "$DIR/OmniFS.prefPane/Contents/Resources/AppIcon.png"

mkdir -p "$DIR/OmniFS.app/Contents/MacOS"
mkdir -p "$DIR/OmniFS.app/Contents/Resources"
cp "$DIR/.build/release/OmniFSSettings" "$DIR/OmniFS.app/Contents/MacOS/OmniFSSettings"
chmod +x "$DIR/OmniFS.app/Contents/MacOS/OmniFSSettings"
cp "$DIR/Resources/AppIcon.icns" "$DIR/OmniFS.app/Contents/Resources/AppIcon.icns"
cp "$DIR/Resources/AppIcon_1024.png" "$DIR/OmniFS.app/Contents/Resources/AppIcon.png"

codesign --force --deep -s - "$DIR/OmniFS.app"
codesign --force --deep -s - "$DIR/OmniFS.prefPane"

ALL_USERS=false
for arg in "$@"; do
    if [ "$arg" = "--all-users" ] || [ "$arg" = "-a" ]; then
        ALL_USERS=true
    fi
done

# 3. Install PreferencePane
if [ "$ALL_USERS" = true ]; then
    echo "[3/5] Installing for ALL users to /Library/PreferencePanes/ (requires sudo)..."
    sudo mkdir -p /Library/PreferencePanes
    sudo rm -rf /Library/PreferencePanes/OmniFS.prefPane
    sudo cp -R "$DIR/OmniFS.prefPane" /Library/PreferencePanes/
    sudo xattr -cr /Library/PreferencePanes/OmniFS.prefPane 2>/dev/null || true
    TARGET_PANE="/Library/PreferencePanes/OmniFS.prefPane"
else
    echo "[3/5] Installing to ~/Library/PreferencePanes/..."
    mkdir -p "$HOME/Library/PreferencePanes"
    rm -rf "$HOME/Library/PreferencePanes/OmniFS.prefPane"
    cp -R "$DIR/OmniFS.prefPane" "$HOME/Library/PreferencePanes/"
    xattr -cr "$HOME/Library/PreferencePanes/OmniFS.prefPane" 2>/dev/null || true
    TARGET_PANE="$HOME/Library/PreferencePanes/OmniFS.prefPane"
fi

# 4. Install standalone app to ~/Applications
echo "[4/5] Installing standalone app to ~/Applications/..."
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/OmniFS.app"
cp -R "$DIR/OmniFS.app" "$HOME/Applications/"
xattr -cr "$HOME/Applications/OmniFS.app" 2>/dev/null || true

# 5. Optional CLI binary
if [ -d "$HOME/.local/bin" ]; then
    cp "$DIR/.build/release/omnifs" "$HOME/.local/bin/omnifs"
    chmod +x "$HOME/.local/bin/omnifs"
    codesign --force -s - "$HOME/.local/bin/omnifs" 2>/dev/null || true
fi

echo "[5/5] Activating OmniFS in System Settings..."
open "$TARGET_PANE"

echo ""
echo "✓ Installation complete! OmniFS is now installed and active in System Settings."
echo "=================================================="

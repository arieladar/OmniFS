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

# 2. Package OmniFS.prefPane bundle
echo "[2/4] Packaging OmniFS Preference Pane..."
mkdir -p "$DIR/OmniFS.prefPane/Contents/MacOS"
cp "$DIR/.build/release/libOmniFSPrefPane.dylib" "$DIR/OmniFS.prefPane/Contents/MacOS/OmniFS"
chmod +x "$DIR/OmniFS.prefPane/Contents/MacOS/OmniFS"

# 3. Install to user PreferencePanes
echo "[3/4] Installing to ~/Library/PreferencePanes/..."
mkdir -p "$HOME/Library/PreferencePanes"
rm -rf "$HOME/Library/PreferencePanes/OmniFS.prefPane"
cp -R "$DIR/OmniFS.prefPane" "$HOME/Library/PreferencePanes/"

# 4. Install standalone app to ~/Applications
mkdir -p "$HOME/Applications"
mkdir -p "$DIR/OmniFS.app/Contents/MacOS"
cp "$DIR/.build/release/OmniFSSettings" "$DIR/OmniFS.app/Contents/MacOS/OmniFSSettings"
chmod +x "$DIR/OmniFS.app/Contents/MacOS/OmniFSSettings"
rm -rf "$HOME/Applications/OmniFS.app"
cp -R "$DIR/OmniFS.app" "$HOME/Applications/"

# 5. Optional CLI binary
if [ -d "$HOME/.local/bin" ]; then
    cp "$DIR/.build/release/omnifs" "$HOME/.local/bin/omnifs"
    chmod +x "$HOME/.local/bin/omnifs"
fi

echo "[4/4] Activating OmniFS in System Settings..."
open "$HOME/Library/PreferencePanes/OmniFS.prefPane"

echo ""
echo "✓ Installation complete! OmniFS is now installed and active in System Settings."
echo "=================================================="

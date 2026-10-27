#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "=================================================="
echo "  Building OmniFS DMG Package (Apple Silicon Native)"
echo "=================================================="

# 1. Compile in Release mode
echo "[1/6] Compiling release binaries..."
swift build -c release

# 2. Package OmniFS.prefPane
echo "[2/6] Packaging OmniFS.prefPane bundle..."
mkdir -p "$DIR/OmniFS.prefPane/Contents/MacOS"
mkdir -p "$DIR/OmniFS.prefPane/Contents/Resources"
cp "$DIR/.build/release/libOmniFSPrefPane.dylib" "$DIR/OmniFS.prefPane/Contents/MacOS/OmniFS"
chmod +x "$DIR/OmniFS.prefPane/Contents/MacOS/OmniFS"
cp "$DIR/Resources/AppIcon.icns" "$DIR/OmniFS.prefPane/Contents/Resources/OmniFS.icns"
cp "$DIR/Resources/AppIcon_1024.png" "$DIR/OmniFS.prefPane/Contents/Resources/AppIcon.png"

# 3. Package OmniFS.app
echo "[3/6] Packaging OmniFS.app bundle..."
mkdir -p "$DIR/OmniFS.app/Contents/MacOS"
mkdir -p "$DIR/OmniFS.app/Contents/Resources"
cp "$DIR/.build/release/OmniFSSettings" "$DIR/OmniFS.app/Contents/MacOS/OmniFSSettings"
chmod +x "$DIR/OmniFS.app/Contents/MacOS/OmniFSSettings"
cp "$DIR/Resources/AppIcon.icns" "$DIR/OmniFS.app/Contents/Resources/AppIcon.icns"
cp "$DIR/Resources/AppIcon_1024.png" "$DIR/OmniFS.app/Contents/Resources/AppIcon.png"

# 4. Code sign all bundles and binaries (ad-hoc signing with hardened verification)
echo "[4/6] Code-signing bundles..."
codesign --force --deep -s - "$DIR/OmniFS.app"
codesign --force --deep -s - "$DIR/OmniFS.prefPane"
codesign --verify --deep --strict "$DIR/OmniFS.app"
codesign --verify --deep --strict "$DIR/OmniFS.prefPane"

# 5. Prepare DMG staging directory
echo "[5/6] Assembling DMG filesystem structure..."
DMG_STAGING="$DIR/.build/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy primary bundles
cp -R "$DIR/OmniFS.prefPane" "$DMG_STAGING/"
cp -R "$DIR/OmniFS.app" "$DMG_STAGING/"

# Add drag-and-drop shortcuts
ln -s /Library/PreferencePanes "$DMG_STAGING/PreferencePanes (All Users)"
ln -s /Applications "$DMG_STAGING/Applications"

# Add one-click installer script with All-Users recommendation
cat << 'EOF' > "$DMG_STAGING/Install OmniFS.command"
#!/usr/bin/env bash
set -e
SRC_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

clear
echo "================================================================"
echo "          OmniFS for macOS — System Installation"
echo "================================================================"
echo ""
echo "OmniFS provides universal read & write filesystem drivers"
echo "for Linux (ext2/3/4, Btrfs, XFS) and Windows (NTFS) storage."
echo ""
echo "Installation scope recommendation:"
echo "----------------------------------------------------------------"
echo "  [1] Install for ALL Users on this computer (Recommended)"
echo "      Installs into /Library/PreferencePanes/ so that foreign"
echo "      storage drivers are available across all user accounts."
echo "      (Requires administrator credentials)"
echo ""
echo "  [2] Install for Current User only"
echo "      Installs into ~/Library/PreferencePanes/"
echo "----------------------------------------------------------------"
read -r -p "Select option [1 or 2, default is 1]: " CHOICE
CHOICE="${CHOICE:-1}"

if [ "$CHOICE" = "1" ]; then
    echo ""
    echo "• Installing OmniFS for ALL users into /Library/PreferencePanes/..."
    sudo mkdir -p /Library/PreferencePanes
    sudo rm -rf /Library/PreferencePanes/OmniFS.prefPane
    sudo cp -R "$SRC_DIR/OmniFS.prefPane" /Library/PreferencePanes/
    sudo xattr -cr /Library/PreferencePanes/OmniFS.prefPane 2>/dev/null || true

    echo "• Installing OmniFS.app into /Applications/..."
    sudo rm -rf /Applications/OmniFS.app
    sudo cp -R "$SRC_DIR/OmniFS.app" /Applications/
    sudo xattr -cr /Applications/OmniFS.app 2>/dev/null || true

    echo "• Activating OmniFS in macOS System Settings..."
    open /Library/PreferencePanes/OmniFS.prefPane
else
    echo ""
    echo "• Installing OmniFS for CURRENT user into ~/Library/PreferencePanes/..."
    mkdir -p "$HOME/Library/PreferencePanes"
    rm -rf "$HOME/Library/PreferencePanes/OmniFS.prefPane"
    cp -R "$SRC_DIR/OmniFS.prefPane" "$HOME/Library/PreferencePanes/"
    xattr -cr "$HOME/Library/PreferencePanes/OmniFS.prefPane" 2>/dev/null || true

    echo "• Installing OmniFS.app..."
    if [ -w "/Applications" ]; then
        rm -rf "/Applications/OmniFS.app"
        cp -R "$SRC_DIR/OmniFS.app" "/Applications/"
        xattr -cr "/Applications/OmniFS.app" 2>/dev/null || true
    else
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/OmniFS.app"
        cp -R "$SRC_DIR/OmniFS.app" "$HOME/Applications/"
        xattr -cr "$HOME/Applications/OmniFS.app" 2>/dev/null || true
    fi

    echo "• Activating OmniFS in macOS System Settings..."
    open "$HOME/Library/PreferencePanes/OmniFS.prefPane"
fi

echo ""
echo "✓ Installation complete! OmniFS is now active."
echo "================================================================"
sleep 2
EOF
chmod +x "$DMG_STAGING/Install OmniFS.command"

# Add Quick Instructions with Recommendation
cat << 'EOF' > "$DMG_STAGING/README.txt"
OmniFS for macOS — Universal Filesystem Engine
=================================================

RECOMMENDED INSTALLATION (For All Users):
-----------------------------------------
It is recommended to install OmniFS for ALL users so that foreign
storage drives (Linux ext4/Btrfs/XFS and Windows NTFS) are recognized
system-wide across all user accounts on this Mac.

Choose one of the following methods:

METHOD 1 — Double-Click OmniFS.prefPane (Easiest):
1. Double-click "OmniFS.prefPane" in this folder.
2. macOS System Settings will prompt:
      "Install OmniFS preference pane?
       ○ Install for this user only
       ● Install for all users on this computer (Recommended)"
3. Select "Install for all users on this computer" and click Install.

METHOD 2 — Automated Installer:
Double-click "Install OmniFS.command" and choose Option 1.

METHOD 3 — Drag & Drop:
1. Drag "OmniFS.prefPane" into the "PreferencePanes (All Users)" folder shortcut.
2. Drag "OmniFS.app" into the "Applications" folder shortcut.
EOF

# 6. Create compressed DMG disk image using hdiutil
echo "[6/6] Generating compressed disk image (OmniFS.dmg)..."
rm -f "$DIR/OmniFS.dmg"
hdiutil create -volname "OmniFS" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DIR/OmniFS.dmg"

# Sign the DMG file itself
codesign --force -s - "$DIR/OmniFS.dmg"

echo ""
echo "=================================================="
echo "✓ Successfully created signed DMG: $DIR/OmniFS.dmg"
echo "=================================================="

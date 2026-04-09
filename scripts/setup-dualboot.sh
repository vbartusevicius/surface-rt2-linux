#!/bin/bash
# setup-dualboot.sh — Prepare dual-boot files on Surface 2 eMMC ESP
#
# Run ON the Surface 2 (from eMMC or USB):
#   sudo /root/setup-dualboot.sh
#
# This script places the EFI Shell and Linux boot files on the ESP.
# Then boot into Windows RT and run setup-dualboot.cmd to add the
# BCD menu entry — that gives you the interactive boot menu with
# Vol+/Vol- to navigate and Windows button to select.
#
# Prerequisites:
#   - Yahallo jailbreak applied (Secure Boot disabled)
#   - Linux boot files already on ESP (via install-to-emmc.sh)

set -euo pipefail

EMMC_ESP="/dev/mmcblk0p1"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Must run as root"
[ -b "$EMMC_ESP" ] || error "$EMMC_ESP not found"

echo "=== Surface 2 Dual-Boot Setup (Step 1 of 2: Linux side) ==="
echo ""
echo "This will place the EFI Shell on the ESP so the BCD can launch it."
echo ""
echo "After this, boot into Windows RT and run:"
echo "  setup-dualboot.cmd   (from the ESP)"
echo ""
echo "That gives you an interactive boot menu:"
echo "  Vol+/Vol-       → navigate"
echo "  Windows button  → select"
echo ""
read -r -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || error "Aborted"

ESP_MNT=$(mktemp -d)
mount "$EMMC_ESP" "$ESP_MNT"

# ─── Verify Linux boot files exist ──────────────────────────────────
for f in boot.efi cmdline.txt startup.nsh; do
    [ -f "$ESP_MNT/$f" ] || { umount "$ESP_MNT"; rmdir "$ESP_MNT"; error "Missing $f on ESP. Run install-to-emmc.sh first."; }
done
info "Linux boot files found on ESP"

# ─── Backup everything ─────────────────────────────────────────────
mkdir -p "$ESP_MNT/backup"

if [ -f "$ESP_MNT/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
    cp -n "$ESP_MNT/EFI/Microsoft/Boot/bootmgfw.efi" "$ESP_MNT/backup/bootmgfw.efi" 2>/dev/null || true
    info "Windows Boot Manager backed up"
else
    warn "Windows Boot Manager not found at EFI/Microsoft/Boot/bootmgfw.efi"
fi

if [ -f "$ESP_MNT/EFI/BOOT/BOOTARM.EFI" ]; then
    cp -n "$ESP_MNT/EFI/BOOT/BOOTARM.EFI" "$ESP_MNT/backup/BOOTARM.EFI.orig" 2>/dev/null || true
fi

cp -f "$ESP_MNT/boot.efi" "$ESP_MNT/backup/"
cp -f "$ESP_MNT"/*.dtb "$ESP_MNT/backup/" 2>/dev/null || true
cp -f "$ESP_MNT/cmdline.txt" "$ESP_MNT/backup/"
cp -f "$ESP_MNT/startup.nsh" "$ESP_MNT/backup/"
info "All boot files backed up to ESP /backup/"

# ─── Place EFI Shell on ESP ─────────────────────────────────────────
# The EFI Shell is what launches startup.nsh → boot.efi → Linux.
# We place it at \EFI\Linux\shellarm.efi for the BCD entry.
SHELL_EFI="EFI/Linux/shellarm.efi"
SHELL_FOUND=false
mkdir -p "$ESP_MNT/EFI/Linux"

# Check if current BOOTARM.EFI is an EFI Shell (different size from boot.efi)
if [ -f "$ESP_MNT/EFI/BOOT/BOOTARM.EFI" ]; then
    BOOTARM_SIZE=$(stat -c%s "$ESP_MNT/EFI/BOOT/BOOTARM.EFI" 2>/dev/null || echo 0)
    BOOTEFI_SIZE=$(stat -c%s "$ESP_MNT/boot.efi" 2>/dev/null || echo 0)
    if [ "$BOOTARM_SIZE" != "$BOOTEFI_SIZE" ]; then
        cp "$ESP_MNT/EFI/BOOT/BOOTARM.EFI" "$ESP_MNT/$SHELL_EFI"
        info "EFI Shell copied from existing BOOTARM.EFI"
        SHELL_FOUND=true
    fi
fi

# Look for EFI Shell on USB if not found
if ! $SHELL_FOUND; then
    for candidate in /dev/sda1 /dev/mmcblk1p1; do
        [ -b "$candidate" ] || continue
        USB_MNT=$(mktemp -d)
        if mount -o ro "$candidate" "$USB_MNT" 2>/dev/null; then
            if [ -f "$USB_MNT/EFI/BOOT/BOOTARM.EFI" ]; then
                cp "$USB_MNT/EFI/BOOT/BOOTARM.EFI" "$ESP_MNT/$SHELL_EFI"
                info "EFI Shell copied from USB"
                SHELL_FOUND=true
            fi
            umount "$USB_MNT"
        fi
        rmdir "$USB_MNT" 2>/dev/null
        $SHELL_FOUND && break
    done
fi

# Download from Tegra Jailbreak USB zip if still not found
JAILBREAK_URL="https://1434104664-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2Fg0WEvpZgMwlYVwyBqPep%2Fuploads%2FcFVuLJNCtdG2fiFlrfyO%2FTegra_Jailbreak_USB.zip?alt=media&token=1c9ef1a2-574e-4a79-ac56-3c751298d0ae"
if ! $SHELL_FOUND; then
    info "EFI Shell not found locally — downloading Tegra Jailbreak USB..."

    # Ensure dependencies
    for cmd in wget unzip; do
        if ! command -v "$cmd" &>/dev/null; then
            info "Installing $cmd..."
            apt-get update -qq && apt-get install -y -qq "$cmd" || error "Failed to install $cmd"
        fi
    done

    DL_DIR=$(mktemp -d)
    if wget -q --show-progress -O "$DL_DIR/jailbreak.zip" "$JAILBREAK_URL"; then
        info "Downloaded Tegra Jailbreak USB zip"
        # Extract only the EFI Shell binary
        if unzip -o -j "$DL_DIR/jailbreak.zip" "EFI/BOOT/BOOTARM.EFI" -d "$DL_DIR" 2>/dev/null || \
           unzip -o -j "$DL_DIR/jailbreak.zip" "*/EFI/BOOT/BOOTARM.EFI" -d "$DL_DIR" 2>/dev/null || \
           unzip -o -j "$DL_DIR/jailbreak.zip" "*/BOOTARM.EFI" -d "$DL_DIR" 2>/dev/null; then
            if [ -f "$DL_DIR/BOOTARM.EFI" ]; then
                cp "$DL_DIR/BOOTARM.EFI" "$ESP_MNT/$SHELL_EFI"
                info "EFI Shell extracted from Tegra Jailbreak USB zip"
                SHELL_FOUND=true
            fi
        else
            warn "Could not find BOOTARM.EFI in the zip — listing contents:"
            unzip -l "$DL_DIR/jailbreak.zip" | grep -i "efi\|boot" || true
        fi
    else
        warn "Download failed — check network connectivity"
    fi
    rm -rf "$DL_DIR"
fi

# Also keep it as fallback BOOTARM.EFI
if $SHELL_FOUND; then
    mkdir -p "$ESP_MNT/EFI/BOOT"
    cp "$ESP_MNT/$SHELL_EFI" "$ESP_MNT/EFI/BOOT/BOOTARM.EFI"
fi

# ─── Generate Windows-side BCD setup script ─────────────────────────
# This .cmd file is run from Windows RT admin prompt to add the BCD entry.
cat > "$ESP_MNT/setup-dualboot.cmd" << 'BATCHEOF'
@echo off
echo === Surface 2 Dual-Boot Setup (Step 2 of 2: Windows side) ===
echo.
echo This adds "Linux (Bookworm)" to the Windows Boot Manager menu.
echo After setup:
echo   Vol+/Vol-       = navigate
echo   Windows button  = select
echo.

REM ─── Must run as Administrator ──────────────────────────────────
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Run this as Administrator!
    echo Right-click cmd.exe and select "Run as administrator"
    pause
    exit /b 1
)

REM ─── Find the ESP drive letter ──────────────────────────────────
REM Mount ESP if not already accessible
mountvol S: /s 2>nul
if not exist "S:\EFI\Linux\shellarm.efi" (
    echo ERROR: EFI Shell not found at S:\EFI\Linux\shellarm.efi
    echo Run setup-dualboot.sh from Linux first.
    pause
    exit /b 1
)

REM ─── Create firmware boot entry for Linux ───────────────────────
echo Creating boot entry for Linux...
for /f "tokens=2 delims={}" %%G in ('bcdedit /create /d "Linux (Bookworm)" /application firmware') do set GUID=%%G
if not defined GUID (
    echo ERROR: Failed to create BCD entry.
    pause
    exit /b 1
)

echo GUID: {%GUID%}

REM Set the path to the EFI Shell
bcdedit /set {%GUID%} path \EFI\Linux\shellarm.efi
bcdedit /set {%GUID%} device partition=S:

REM Add to the firmware display order
bcdedit /set {fwbootmgr} displayorder {%GUID%} /addlast

REM Set timeout (seconds) for the boot menu
bcdedit /set {bootmgr} timeout 10

echo.
echo === Done! ===
echo.
echo Boot menu will show for 10 seconds:
echo   1. Windows RT (default)
echo   2. Linux (Bookworm)
echo.
echo Use Vol+/Vol- to navigate, Windows button to select.
echo Linux auto-boots if you set it as default:
echo   bcdedit /set {bootmgr} default {%GUID%}
echo.
pause
BATCHEOF
info "Generated setup-dualboot.cmd on ESP"

sync
umount "$ESP_MNT"
rmdir "$ESP_MNT"

if ! $SHELL_FOUND; then
    error "EFI Shell binary not found! Copy it to ESP at $SHELL_EFI (from Yahallo USB)."
fi

echo ""
info "=== Step 1 complete! ==="
echo ""
info "EFI Shell placed at ESP:\\$SHELL_EFI"
info "BCD setup script placed at ESP:\\setup-dualboot.cmd"
echo ""
info "Next: Boot into Windows RT, then:"
info "  1. Open Admin command prompt"
info "  2. mountvol S: /s"
info "  3. S:\\setup-dualboot.cmd"
echo ""
info "That will add the boot menu with Vol+/Vol-/Win button support."

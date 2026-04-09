#!/bin/bash
# setup-dualboot.sh — Configure dual-boot on Surface 2 eMMC
#
# Run ON the Surface 2 (from eMMC or USB):
#   sudo /root/setup-dualboot.sh
#
# Creates two UEFI boot entries visible in the Vol Up menu:
#   1. "Linux (Bookworm)"   — EFI Shell → startup.nsh → boot.efi
#   2. "Windows Boot Manager" — original Windows RT
#
# Linux is set as the default. Hold Vol Up to pick either OS.
#
# Prerequisites:
#   - Yahallo jailbreak applied (Secure Boot disabled)
#   - Linux boot files already on ESP (via install-to-emmc.sh)
#   - efibootmgr installed (apt install efibootmgr)

set -euo pipefail

EMMC_ESP="/dev/mmcblk0p1"
EMMC_DISK="/dev/mmcblk0"
ESP_PART_NUM=1

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Must run as root"
[ -b "$EMMC_ESP" ] || error "$EMMC_ESP not found"

# ─── Check dependencies ─────────────────────────────────────────────
if ! command -v efibootmgr &>/dev/null; then
    info "Installing efibootmgr..."
    apt-get update -qq && apt-get install -y -qq efibootmgr || error "Failed to install efibootmgr"
fi

echo "=== Surface 2 Dual-Boot Setup ==="
echo ""
echo "This will:"
echo "  1. Place EFI Shell on eMMC ESP as the Linux boot loader"
echo "  2. Register 'Linux (Bookworm)' as a UEFI boot entry"
echo "  3. Set Linux as the default boot option"
echo ""
echo "After setup, hold Vol Up at power-on to choose between:"
echo "  • Linux (Bookworm)"
echo "  • Windows Boot Manager"
echo ""
echo "Windows RT partition is NOT touched."
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
# The EFI Shell runs startup.nsh which launches boot.efi (Linux kernel).
# We put it at \EFI\Linux\shellarm.efi so it has its own path for the
# UEFI boot entry, separate from the fallback BOOTARM.EFI.
SHELL_EFI="EFI/Linux/shellarm.efi"
SHELL_FOUND=false
mkdir -p "$ESP_MNT/EFI/Linux"

# Check if current BOOTARM.EFI is an EFI Shell (different from boot.efi)
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

# Also keep it as the fallback BOOTARM.EFI
if $SHELL_FOUND; then
    cp "$ESP_MNT/$SHELL_EFI" "$ESP_MNT/EFI/BOOT/BOOTARM.EFI"
fi

sync
umount "$ESP_MNT"
rmdir "$ESP_MNT"

if ! $SHELL_FOUND; then
    error "EFI Shell binary not found! Copy it to ESP at $SHELL_EFI manually (from Yahallo USB)."
fi

# ─── Register UEFI boot entries ─────────────────────────────────────
info "Current UEFI boot entries:"
efibootmgr -v 2>/dev/null || warn "Could not read UEFI boot entries"
echo ""

# Remove any previous "Linux (Bookworm)" entry to avoid duplicates
EXISTING=$(efibootmgr 2>/dev/null | grep "Linux (Bookworm)" | grep -oP 'Boot\K[0-9A-Fa-f]{4}' || true)
if [ -n "$EXISTING" ]; then
    for entry in $EXISTING; do
        info "Removing old Linux boot entry: Boot$entry"
        efibootmgr -b "$entry" -B 2>/dev/null || true
    done
fi

# Create new Linux boot entry pointing to EFI Shell
info "Creating UEFI boot entry: Linux (Bookworm) → \\$SHELL_EFI"
LINUX_ENTRY=$(efibootmgr --create \
    --disk "$EMMC_DISK" --part "$ESP_PART_NUM" \
    --label "Linux (Bookworm)" \
    --loader "\\${SHELL_EFI//\//\\}" 2>&1) || error "Failed to create boot entry: $LINUX_ENTRY"

# Extract the new boot number
LINUX_BOOTNUM=$(echo "$LINUX_ENTRY" | grep -oP 'Boot\K[0-9A-Fa-f]{4}' | head -1)
info "Created boot entry: Boot$LINUX_BOOTNUM"

# Find Windows Boot Manager entry
WIN_BOOTNUM=$(efibootmgr 2>/dev/null | grep -i "Windows Boot Manager" | grep -oP 'Boot\K[0-9A-Fa-f]{4}' | head -1 || true)

# Set boot order: Linux first, then Windows
if [ -n "$WIN_BOOTNUM" ] && [ -n "$LINUX_BOOTNUM" ]; then
    info "Setting boot order: Linux ($LINUX_BOOTNUM) → Windows ($WIN_BOOTNUM)"
    efibootmgr --bootorder "$LINUX_BOOTNUM,$WIN_BOOTNUM" 2>/dev/null || \
        warn "Could not set boot order — set it manually in UEFI settings"
elif [ -n "$LINUX_BOOTNUM" ]; then
    efibootmgr --bootorder "$LINUX_BOOTNUM" 2>/dev/null || true
fi

echo ""
info "=== Dual-boot configured! ==="
echo ""
info "UEFI boot menu (Vol Up) now shows:"
info "  1. Linux (Bookworm)    ← default"
[ -n "$WIN_BOOTNUM" ] && \
info "  2. Windows Boot Manager"
echo ""
info "Final UEFI boot entries:"
efibootmgr 2>/dev/null || true
echo ""
info "KEEP THE USB as recovery medium (Vol Down to boot from USB)."
echo ""
info "NOTE: If Windows Update resets the boot order, re-run this script."

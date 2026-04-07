#!/bin/bash
# prepare-usb.sh — Prepare a USB drive with Surface 2 Linux boot files
# Usage: ./scripts/prepare-usb.sh /dev/sdX
# WARNING: This will ERASE the target USB drive!
set -euo pipefail

USB_DEV="${1:-}"
BOOT_DIR="./output/boot"
STAGING_DIR="./output/staging"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

if [ -z "$USB_DEV" ]; then
    echo "Usage: $0 /dev/sdX"
    echo ""
    echo "This script formats a USB drive as FAT32 and copies the"
    echo "Surface 2 Linux boot files onto it."
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null || true
    exit 1
fi

# Safety checks
[ -b "$USB_DEV" ] || error "$USB_DEV is not a block device"
[ "$(id -u)" -eq 0 ] || error "Must run as root (sudo)"
[ -d "$BOOT_DIR" ] || error "Boot directory not found: $BOOT_DIR — run build.sh first"
[ -f "$BOOT_DIR/boot.efi" ] || error "boot.efi not found — run build.sh first"

# Confirm
echo ""
echo "WARNING: This will ERASE ALL DATA on $USB_DEV"
lsblk "$USB_DEV" 2>/dev/null || true
echo ""
read -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || error "Aborted"

# ─── Partition USB drive ───────────────────────────────────────────
info "Partitioning $USB_DEV ..."
umount "${USB_DEV}"* 2>/dev/null || true

parted -s "$USB_DEV" \
    mklabel gpt \
    mkpart "EFI" fat32 1MiB 100%
partprobe "$USB_DEV" 2>/dev/null || sleep 2

# Detect partition name (could be /dev/sdX1 or /dev/sdXp1)
PART=""
for suffix in "1" "p1"; do
    if [ -b "${USB_DEV}${suffix}" ]; then
        PART="${USB_DEV}${suffix}"
        break
    fi
done
[ -n "$PART" ] || error "Cannot find partition on $USB_DEV"

# ─── Format ────────────────────────────────────────────────────────
info "Formatting $PART as FAT32 ..."
mkfs.vfat -F 32 -n "S2LINUX" "$PART"

# ─── Mount and copy ────────────────────────────────────────────────
MNT=$(mktemp -d)
mount "$PART" "$MNT"

info "Copying boot files ..."
cp -v "$BOOT_DIR/boot.efi"           "$MNT/"
cp -v "$BOOT_DIR/initrd.gz"          "$MNT/"
cp -v "$BOOT_DIR/startup.nsh"        "$MNT/"
cp -v "$BOOT_DIR/commandline.txt"    "$MNT/" 2>/dev/null || true
cp -v "$BOOT_DIR/startup-emmc.nsh"   "$MNT/" 2>/dev/null || true

# Copy DTBs
for dtb in "$BOOT_DIR"/*.dtb; do
    [ -f "$dtb" ] && cp -v "$dtb" "$MNT/"
done

# Create EFI directory structure
mkdir -p "$MNT/EFI/BOOT"
cp "$BOOT_DIR/boot.efi" "$MNT/EFI/BOOT/BOOTARM.EFI"

info "Copying staging files (modules, firmware) ..."
if [ -d "$STAGING_DIR/lib" ]; then
    cp -a "$STAGING_DIR/lib" "$MNT/"
fi

# ─── Sync and unmount ─────────────────────────────────────────────
sync
umount "$MNT"
rmdir "$MNT"

info ""
info "=== USB drive ready! ==="
info "Device: $USB_DEV"
info ""
info "Still needed on Surface 2 partition 6 (staging):"
info "  - rootfs.img (Raspbian Bookworm armhf root filesystem)"
info "  - lib/modules/* (already on USB if staging was built)"
info "  - lib/firmware/* (already on USB if staging was built)"

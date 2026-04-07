#!/bin/bash
# prepare-usb.sh — Prepare a USB drive with everything needed to install Linux on Surface 2
# Usage: sudo ./scripts/prepare-usb.sh /dev/sdX [rootfs.img]
# WARNING: This will ERASE the target USB drive!
set -euo pipefail

USB_DEV="${1:-}"
ROOTFS_IMG="${2:-}"
BOOT_DIR="./output/boot"
STAGING_DIR="./output/staging"
CACHE_DIR="./output"
USB_LABEL="S2LINUX"

# ─── Recommended rootfs ─────────────────────────────────────────────
# Raspberry Pi OS Lite (Bookworm) armhf — Debian 12, no desktop, ~500 MB
# Update this URL when a newer release is published:
# https://downloads.raspberrypi.com/raspios_oldstable_lite_armhf/images/
RASPIOS_URL="https://downloads.raspberrypi.com/raspios_oldstable_lite_armhf/images/raspios_oldstable_lite_armhf-2025-11-24/2025-11-24-raspios-bookworm-armhf-lite.img.xz"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

# ─── Download and extract rootfs ────────────────────────────────────
download_rootfs() {
    local XZ_FILE="$CACHE_DIR/$(basename "$RASPIOS_URL")"
    local IMG_FILE="${XZ_FILE%.xz}"
    local ROOTFS_OUT="$CACHE_DIR/rootfs.img"

    # Return cached rootfs if it exists
    if [ -f "$ROOTFS_OUT" ]; then
        info "Using cached rootfs: $ROOTFS_OUT"
        echo "$ROOTFS_OUT"
        return
    fi

    mkdir -p "$CACHE_DIR"

    # Download
    if [ ! -f "$XZ_FILE" ]; then
        info "Downloading Raspberry Pi OS Lite (Bookworm armhf) ..."
        info "URL: $RASPIOS_URL"
        wget --progress=bar:force -O "$XZ_FILE" "$RASPIOS_URL" || \
            error "Download failed. You can manually download from:\n  https://www.raspberrypi.com/software/operating-systems/"
    else
        info "Using cached download: $XZ_FILE"
    fi

    # Decompress
    if [ ! -f "$IMG_FILE" ]; then
        info "Decompressing $(basename "$XZ_FILE") ..."
        xz -dk "$XZ_FILE"
    fi

    # Extract root partition (partition 2 = Linux ext4)
    info "Extracting root partition from $(basename "$IMG_FILE") ..."
    local PART_INFO
    PART_INFO=$(fdisk -l "$IMG_FILE" | grep 'Linux' | head -1)
    [ -n "$PART_INFO" ] || error "Cannot find Linux partition in $IMG_FILE"

    local START SIZE
    START=$(echo "$PART_INFO" | awk '{print $2}')
    SIZE=$(echo "$PART_INFO" | awk '{print $4}')
    dd if="$IMG_FILE" of="$ROOTFS_OUT" bs=512 skip="$START" count="$SIZE" status=progress
    sync

    info "Root filesystem extracted: $ROOTFS_OUT ($(du -h "$ROOTFS_OUT" | cut -f1))"

    # Clean up the full .img (keep .xz for re-extraction)
    rm -f "$IMG_FILE"

    echo "$ROOTFS_OUT"
}

if [ -z "$USB_DEV" ]; then
    echo "Usage: sudo $0 /dev/sdX [rootfs.img]"
    echo ""
    echo "Formats a USB drive and copies all Surface 2 Linux installer files:"
    echo "  - Kernel (boot.efi), device trees, initramfs, startup scripts"
    echo "  - Kernel modules and Wi-Fi firmware"
    echo "  - Root filesystem image (downloaded automatically or provided)"
    echo ""
    echo "If no rootfs.img is given, Raspberry Pi OS Lite (Bookworm armhf)"
    echo "is downloaded and extracted automatically."
    echo ""
    echo "The installer (init.sh) will detect this USB by its '$USB_LABEL' label."
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null || true
    exit 1
fi

# ─── Safety checks ──────────────────────────────────────────────────
[ -b "$USB_DEV" ] || error "$USB_DEV is not a block device"
[ "$(id -u)" -eq 0 ] || error "Must run as root (sudo)"
[ -d "$BOOT_DIR" ] || error "Boot directory not found: $BOOT_DIR — run the Docker build first"
[ -f "$BOOT_DIR/boot.efi" ] || error "boot.efi not found — run the Docker build first"

if [ -n "$ROOTFS_IMG" ] && [ ! -f "$ROOTFS_IMG" ]; then
    error "Root filesystem image not found: $ROOTFS_IMG"
fi

# Download rootfs if not provided
if [ -z "$ROOTFS_IMG" ]; then
    ROOTFS_IMG=$(download_rootfs)
fi

# ─── Confirm ────────────────────────────────────────────────────────
echo ""
echo "WARNING: This will ERASE ALL DATA on $USB_DEV"
lsblk "$USB_DEV" 2>/dev/null || true
echo ""
echo "Will copy:"
echo "  - Boot files from $BOOT_DIR"
echo "  - Staging files from $STAGING_DIR"
[ -n "$ROOTFS_IMG" ] && echo "  - Root filesystem: $ROOTFS_IMG ($(du -h "$ROOTFS_IMG" | cut -f1))"
echo ""
read -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || error "Aborted"

# ─── Partition ──────────────────────────────────────────────────────
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

# ─── Format ─────────────────────────────────────────────────────────
info "Formatting $PART as FAT32 (label=$USB_LABEL) ..."
mkfs.vfat -F 32 -n "$USB_LABEL" "$PART"

# ─── Mount and copy ─────────────────────────────────────────────────
MNT=$(mktemp -d)
mount "$PART" "$MNT"

# Ensure cleanup on exit
trap 'sync; umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT

info "Copying boot files ..."
cp -v "$BOOT_DIR/boot.efi"           "$MNT/"
cp -v "$BOOT_DIR/initrd.gz"          "$MNT/"
cp -v "$BOOT_DIR/startup.nsh"        "$MNT/"
cp -v "$BOOT_DIR/commandline.txt"    "$MNT/" 2>/dev/null || true
cp -v "$BOOT_DIR/startup-emmc.nsh"   "$MNT/" 2>/dev/null || true

for dtb in "$BOOT_DIR"/*.dtb; do
    [ -f "$dtb" ] && cp -v "$dtb" "$MNT/"
done

# EFI fallback path
mkdir -p "$MNT/EFI/BOOT"
cp "$BOOT_DIR/boot.efi" "$MNT/EFI/BOOT/BOOTARM.EFI"

info "Copying kernel modules and firmware ..."
if [ -d "$STAGING_DIR/lib" ]; then
    cp -a "$STAGING_DIR/lib" "$MNT/"
else
    warn "No staging lib/ found — modules and firmware will be missing"
fi

if [ -n "$ROOTFS_IMG" ]; then
    info "Copying root filesystem image (this may take a while) ..."
    cp -v "$ROOTFS_IMG" "$MNT/rootfs.img"
fi

# ─── Summary ────────────────────────────────────────────────────────
sync
info ""
info "=== USB drive ready! ==="
info "Device: $USB_DEV ($PART), label: $USB_LABEL"
info ""
du -sh "$MNT"/* 2>/dev/null | sed 's/^/  /'
info ""

info ""
info "Next: plug USB into Surface 2, boot with Volume Up → select USB"

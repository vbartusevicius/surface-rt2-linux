#!/usr/bin/env bash
# prepare-usb.sh — Prepare a USB drive or create a disk image with everything needed to install Linux on Surface 2
#
# Usage:
#   Linux block device:
#     sudo ./scripts/prepare-usb.sh /dev/sdX [rootfs.img]
#
#   macOS-friendly image mode (run inside Linux/Docker on your Mac, then flash the IMG on macOS):
#     ./scripts/prepare-usb.sh ./output/surface2-installer.img [rootfs.img]
#
# WARNING: Writing to a block device will ERASE it.

set -euo pipefail

TARGET="${1:-}"
ROOTFS_IMG="${2:-}"
BOOT_DIR="./output/boot"
STAGING_DIR="./output/staging"
CACHE_DIR="./output"
USB_LABEL="S2LINUX"

# Default size for image mode. Adjust upward if you add more payload.
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-4096}"

# Raspberry Pi OS Lite (Bookworm) armhf — Debian 12, no desktop, ~500 MB
# Update this URL when a newer release is published.
RASPIOS_URL="https://downloads.raspberrypi.com/raspios_oldstable_lite_armhf/images/raspios_oldstable_lite_armhf-2025-11-24/2025-11-24-raspios-bookworm-armhf-lite.img.xz"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*" >&2; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*" >&2; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

is_root() { [ "$(id -u)" -eq 0 ]; }
is_block_device() { [ -b "$1" ]; }
is_image_target() { [[ "$1" == *.img || "$1" == *.img.gz ]]; }

cleanup() {
    local rc=$?
    set +e
    if [ -n "${MNT:-}" ] && mountpoint -q "$MNT" 2>/dev/null; then
        sync
        umount "$MNT" 2>/dev/null
    fi
    [ -n "${MNT:-}" ] && rmdir "$MNT" 2>/dev/null
    if [ -n "${LOOP_DEV:-}" ]; then
        losetup -d "$LOOP_DEV" 2>/dev/null
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ─── Download and extract rootfs ────────────────────────────────────
download_rootfs() {
    local XZ_FILE="$CACHE_DIR/$(basename "$RASPIOS_URL")"
    local IMG_FILE="${XZ_FILE%.xz}"
    local ROOTFS_OUT="$CACHE_DIR/rootfs.img"

    if [ -f "$ROOTFS_OUT" ]; then
        info "Using cached rootfs: $ROOTFS_OUT"
        echo "$ROOTFS_OUT"
        return
    fi

    mkdir -p "$CACHE_DIR"

    if [ ! -f "$XZ_FILE" ]; then
        info "Downloading Raspberry Pi OS Lite (Bookworm armhf)..."
        info "URL: $RASPIOS_URL"
        wget --progress=bar:force -O "$XZ_FILE" "$RASPIOS_URL" || \
            error "Download failed. You can manually download from:
  https://www.raspberrypi.com/software/operating-systems/"
    else
        info "Using cached download: $XZ_FILE"
    fi

    if [ ! -f "$IMG_FILE" ]; then
        info "Decompressing $(basename "$XZ_FILE")..."
        xz -dk "$XZ_FILE"
    fi

    info "Extracting root partition from $(basename "$IMG_FILE")..."
    local PLINE START SIZE
    PLINE=$(parted -ms "$IMG_FILE" unit s print 2>/dev/null | grep "^2:")
    [ -n "$PLINE" ] || error "Cannot find partition 2 in $IMG_FILE"

    START=$(echo "$PLINE" | cut -d: -f2 | tr -d 's')
    SIZE=$(echo "$PLINE" | cut -d: -f4 | tr -d 's')

    dd if="$IMG_FILE" of="$ROOTFS_OUT" bs=512 skip="$START" count="$SIZE" status=progress
    sync

    info "Root filesystem extracted: $ROOTFS_OUT ($(du -h "$ROOTFS_OUT" | cut -f1))"
    rm -f "$IMG_FILE"

    echo "$ROOTFS_OUT"
}

usage() {
    cat <<EOF
Usage:
  sudo $0 /dev/sdX [rootfs.img]
  $0 ./output/surface2-installer.img [rootfs.img]

Creates either:
  - a bootable USB drive (Linux block device mode), or
  - a bootable disk image (.img) that you can flash from macOS with dd

The installer package includes:
  - boot.efi, DTBs, initramfs, startup scripts
  - kernel modules and Wi-Fi firmware
  - root filesystem image (downloaded automatically or provided)

If no rootfs.img is given, Raspberry Pi OS Lite (Bookworm armhf)
is downloaded and extracted automatically.

Available block devices:
EOF
    lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null || true
}

if [ -z "$TARGET" ]; then
    usage
    exit 1
fi

[ -d "$BOOT_DIR" ] || error "Boot directory not found: $BOOT_DIR — run the Docker build first"
[ -f "$BOOT_DIR/boot.efi" ] || error "boot.efi not found — run the Docker build first"
[ -d "$STAGING_DIR" ] || warn "Staging directory not found: $STAGING_DIR — modules/firmware may be missing"

if [ -n "$ROOTFS_IMG" ] && [ ! -f "$ROOTFS_IMG" ]; then
    error "Root filesystem image not found: $ROOTFS_IMG"
fi

if [ -z "$ROOTFS_IMG" ]; then
    ROOTFS_IMG=$(download_rootfs)
fi

MODE="image"
if is_block_device "$TARGET"; then
    MODE="block"
fi

if [ "$MODE" = "block" ] && ! is_root; then
    error "Must run as root (sudo) when writing to a block device"
fi

if [ "$MODE" = "block" ]; then
    [ -b "$TARGET" ] || error "$TARGET is not a block device"
fi

if [ "$MODE" = "image" ]; then
    mkdir -p "$(dirname "$TARGET")"
fi

echo ""
echo "Will write:"
echo "  - Mode: $MODE"
echo "  - Target: $TARGET"
echo "  - Boot files from: $BOOT_DIR"
echo "  - Staging files from: $STAGING_DIR"
if [ -n "$ROOTFS_IMG" ] && [ -f "$ROOTFS_IMG" ]; then
    echo "  - Root filesystem: $ROOTFS_IMG ($(du -h "$ROOTFS_IMG" | cut -f1))"
fi
echo ""
if [ "$MODE" = "block" ]; then
    echo "WARNING: This will ERASE ALL DATA on $TARGET"
    lsblk "$TARGET" 2>/dev/null || true
    echo ""
    read -r -p "Type YES to continue: " CONFIRM
    [ "$CONFIRM" = "YES" ] || error "Aborted"
fi

# ─── Create/attach target ────────────────────────────────────────────
TARGET_DEV="$TARGET"
if [ "$MODE" = "image" ]; then
    info "Creating disk image: $TARGET (${IMAGE_SIZE_MB}MB)"
    rm -f "$TARGET"
    truncate -s "${IMAGE_SIZE_MB}M" "$TARGET"

    info "Attaching loop device..."
    LOOP_DEV=$(losetup --find --show --partscan "$TARGET")
    info "Loop device: $LOOP_DEV"
    TARGET_DEV="$LOOP_DEV"
else
    info "Partitioning block device: $TARGET"
fi

# ─── SIMPLE IMAGE MODE (NO PARTITIONS — DOCKER SAFE) ─────────────────
if [ "$MODE" = "image" ]; then
    info "Formatting image directly as FAT32 (no partition table)..."
    mkfs.vfat -F 32 -n "$USB_LABEL" "$TARGET_DEV"
    PART="$TARGET_DEV"
else
    info "Partitioning block device: $TARGET_DEV..."
    parted -s "$TARGET_DEV" mklabel gpt
    parted -s "$TARGET_DEV" mkpart "EFI" fat32 1MiB 100%
    partprobe "$TARGET_DEV" 2>/dev/null || true
    sleep 1

    for suffix in p1 1; do
        if [ -b "${TARGET_DEV}${suffix}" ]; then
            PART="${TARGET_DEV}${suffix}"
            break
        fi
    done

    [ -n "${PART:-}" ] || error "Cannot find partition on $TARGET_DEV"

    info "Formatting $PART..."
    mkfs.vfat -F 32 -n "$USB_LABEL" "$PART"
fi

# ─── Format ─────────────────────────────────────────────────────────
info "Formatting $PART as FAT32 (label=$USB_LABEL)..."
mkfs.vfat -F 32 -n "$USB_LABEL" "$PART"

# ─── Mount and copy ─────────────────────────────────────────────────
MNT=$(mktemp -d)
mount "$PART" "$MNT"

info "Copying boot files..."
cp -v "$BOOT_DIR/boot.efi"        "$MNT/"
cp -v "$BOOT_DIR/initrd.gz"       "$MNT/" 2>/dev/null || true
cp -v "$BOOT_DIR/startup.nsh"     "$MNT/" 2>/dev/null || true
cp -v "$BOOT_DIR/commandline.txt" "$MNT/" 2>/dev/null || true
cp -v "$BOOT_DIR/startup-emmc.nsh" "$MNT/" 2>/dev/null || true

for dtb in "$BOOT_DIR"/*.dtb; do
    [ -f "$dtb" ] && cp -v "$dtb" "$MNT/"
done

mkdir -p "$MNT/EFI/BOOT"
cp -v "$BOOT_DIR/boot.efi" "$MNT/EFI/BOOT/BOOTARM.EFI"

info "Copying kernel modules..."
if [ -d "$STAGING_DIR/lib/modules" ]; then
    mkdir -p "$MNT/lib/modules"
    for modver in "$STAGING_DIR"/lib/modules/*/; do
        [ -d "$modver" ] || continue
        dest="$MNT/lib/modules/$(basename "$modver")"
        mkdir -p "$dest"
        find "$modver" -mindepth 1 -maxdepth 1 ! -type l -exec cp -r {} "$dest/" \;
    done
else
    warn "No modules found in $STAGING_DIR/lib/modules"
fi

info "Copying Wi-Fi firmware..."
if [ -d "$STAGING_DIR/lib/firmware" ]; then
    mkdir -p "$MNT/lib/firmware"
    cp -r "$STAGING_DIR/lib/firmware"/* "$MNT/lib/firmware/" 2>/dev/null || true
else
    warn "No firmware found in $STAGING_DIR/lib/firmware"
fi

info "Copying root filesystem image..."
cp -v "$ROOTFS_IMG" "$MNT/rootfs.img"

sync
umount "$MNT"
rmdir "$MNT"
MNT=""

info ""
info "=== Installer image ready! ==="
info "Target: $TARGET"
info "Mode: $MODE"
info ""

if [ "$MODE" = "image" ]; then
    info "Flash from macOS with:"
    cat <<EOF
  diskutil list
  diskutil unmountDisk /dev/diskX
  sudo dd if=$TARGET of=/dev/rdiskX bs=4m status=progress
EOF
fi

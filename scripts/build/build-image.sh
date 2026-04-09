#!/bin/bash
# build-image.sh — Create bootable USB disk image for Surface 2
# Sourced by build.sh — do not run directly.
#
# Creates a 2-partition image:
#   p1 (FAT32, 128 MB) — boot.efi, DTB, cmdline.txt, startup.nsh
#   p2 (ext4,  rest)   — Raspberry Pi OS Bookworm + modules + firmware
#
# Requires: losetup, parted, mkfs.vfat, mkfs.ext4, mount (run with --privileged)

IMAGE_NAME="${IMAGE_NAME:-surface2-bookworm-usb}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-4096}"
BOOT_PART_MB=128

# Raspberry Pi OS Lite (Bookworm) armhf
RASPIOS_URL="${RASPIOS_URL:-https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2024-11-19/2024-11-19-raspios-bookworm-armhf-lite.img.xz}"

# ─── Cleanup on exit ───────────────────────────────────────────────
IMAGE_BOOT_MNT=""
IMAGE_ROOT_MNT=""
IMAGE_LOOP=""
IMAGE_RLOOP=""
IMAGE_RPI_MNT=""

image_cleanup() {
    set +e
    for m in "$IMAGE_RPI_MNT" "$IMAGE_ROOT_MNT" "$IMAGE_BOOT_MNT"; do
        [ -n "$m" ] && mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null
        [ -n "$m" ] && [ -d "$m" ] && rmdir "$m" 2>/dev/null
    done
    [ -n "$IMAGE_RLOOP" ] && losetup -d "$IMAGE_RLOOP" 2>/dev/null
    [ -n "$IMAGE_LOOP" ] && losetup -d "$IMAGE_LOOP" 2>/dev/null
}

# ─── Download Raspberry Pi OS ──────────────────────────────────────
download_raspios() {
    local CACHE="$OUTPUT_DIR"
    local XZ_FILE="$CACHE/$(basename "$RASPIOS_URL")"
    RASPIOS_IMG="${XZ_FILE%.xz}"

    if [ -f "$RASPIOS_IMG" ]; then
        info "Using cached: $(basename "$RASPIOS_IMG")"
        return
    fi

    mkdir -p "$CACHE"

    if [ ! -f "$XZ_FILE" ]; then
        info "Downloading Raspberry Pi OS Bookworm Lite..."
        info "URL: $RASPIOS_URL"
        wget --progress=bar:force -O "$XZ_FILE" "$RASPIOS_URL" || \
            error "Download failed. Set RASPIOS_URL to override."
    fi

    info "Decompressing $(basename "$XZ_FILE")..."
    xz -dk "$XZ_FILE"
    info "Decompressed: $(du -h "$RASPIOS_IMG" | cut -f1)"
}

# ─── Build the disk image ─────────────────────────────────────────
build_image() {
    local IMAGE_FILE="$OUTPUT_DIR/$IMAGE_NAME.img"
    local IMAGE_XZ="$IMAGE_FILE.xz"

    info "=== Creating bootable USB image ==="
    info "Size: ${IMAGE_SIZE_MB}MB, Boot: ${BOOT_PART_MB}MB"

    # Register cleanup
    trap 'image_cleanup; exit 1' INT TERM
    trap 'image_cleanup' EXIT

    # ── Download Raspberry Pi OS ──
    download_raspios

    # ── Create partitioned image ──
    info "Creating ${IMAGE_SIZE_MB}MB disk image..."
    rm -f "$IMAGE_FILE" "$IMAGE_XZ"
    truncate -s "${IMAGE_SIZE_MB}M" "$IMAGE_FILE"

    info "Partitioning (MBR: p1=FAT32 ${BOOT_PART_MB}MB, p2=ext4 rest)..."
    parted -s "$IMAGE_FILE" mklabel msdos
    parted -s "$IMAGE_FILE" mkpart primary fat32 1MiB "${BOOT_PART_MB}MiB"
    parted -s "$IMAGE_FILE" mkpart primary ext2  "${BOOT_PART_MB}MiB" 100%
    parted -s "$IMAGE_FILE" set 1 boot on

    # ── Attach loop device ──
    IMAGE_LOOP=$(losetup --find --show --partscan "$IMAGE_FILE")
    info "Loop device: $IMAGE_LOOP"
    sleep 1

    # Verify partition devices exist
    [ -b "${IMAGE_LOOP}p1" ] || error "Partition ${IMAGE_LOOP}p1 not found"
    [ -b "${IMAGE_LOOP}p2" ] || error "Partition ${IMAGE_LOOP}p2 not found"

    # ── Format ──
    info "Formatting p1 as FAT32 (S2BOOT)..."
    mkfs.vfat -F 32 -n "S2BOOT" "${IMAGE_LOOP}p1"

    info "Formatting p2 as ext4 (S2ROOT)..."
    mkfs.ext4 -L "S2ROOT" -q "${IMAGE_LOOP}p2"

    # ── Populate p1 (boot) ──
    IMAGE_BOOT_MNT=$(mktemp -d)
    mount "${IMAGE_LOOP}p1" "$IMAGE_BOOT_MNT"

    info "Copying boot files to p1..."
    cp "$BOOT_DIR/boot.efi"    "$IMAGE_BOOT_MNT/"
    cp "$BOOT_DIR/cmdline.txt" "$IMAGE_BOOT_MNT/"
    cp "$BOOT_DIR/cmdline-emmc.txt" "$IMAGE_BOOT_MNT/" 2>/dev/null || true
    cp "$BOOT_DIR/startup.nsh" "$IMAGE_BOOT_MNT/" 2>/dev/null || true

    for dtb in "$BOOT_DIR"/*.dtb; do
        [ -f "$dtb" ] && cp "$dtb" "$IMAGE_BOOT_MNT/"
    done

    mkdir -p "$IMAGE_BOOT_MNT/EFI/BOOT"
    cp "$BOOT_DIR/boot.efi" "$IMAGE_BOOT_MNT/EFI/BOOT/BOOTARM.EFI"

    sync
    umount "$IMAGE_BOOT_MNT"
    rmdir "$IMAGE_BOOT_MNT"
    IMAGE_BOOT_MNT=""
    info "Boot partition ready"

    # ── Populate p2 (rootfs) ──
    IMAGE_ROOT_MNT=$(mktemp -d)
    mount "${IMAGE_LOOP}p2" "$IMAGE_ROOT_MNT"

    # Extract Raspberry Pi OS rootfs (partition 2 of the RPi image)
    info "Extracting Raspberry Pi OS rootfs..."
    local PLINE START
    PLINE=$(parted -ms "$RASPIOS_IMG" unit s print 2>/dev/null | grep "^2:")
    [ -n "$PLINE" ] || error "Cannot find partition 2 in $RASPIOS_IMG"
    START=$(echo "$PLINE" | cut -d: -f2 | tr -d 's')

    IMAGE_RLOOP=$(losetup --find --show --offset $((START * 512)) "$RASPIOS_IMG")
    IMAGE_RPI_MNT=$(mktemp -d)
    mount -o ro "$IMAGE_RLOOP" "$IMAGE_RPI_MNT"

    info "Copying rootfs (this takes a few minutes)..."
    cp -a "$IMAGE_RPI_MNT"/. "$IMAGE_ROOT_MNT"/

    umount "$IMAGE_RPI_MNT"
    losetup -d "$IMAGE_RLOOP"
    rmdir "$IMAGE_RPI_MNT"
    IMAGE_RLOOP="" IMAGE_RPI_MNT=""

    # Install kernel modules
    if [ -d "$STAGING_DIR/lib/modules" ]; then
        info "Installing kernel modules..."
        mkdir -p "$IMAGE_ROOT_MNT/lib/modules"
        cp -a "$STAGING_DIR/lib/modules"/* "$IMAGE_ROOT_MNT/lib/modules/"
    fi

    # Install Wi-Fi firmware
    if [ -d "$STAGING_DIR/lib/firmware" ]; then
        info "Installing Wi-Fi firmware..."
        mkdir -p "$IMAGE_ROOT_MNT/lib/firmware"
        cp -a "$STAGING_DIR/lib/firmware"/* "$IMAGE_ROOT_MNT/lib/firmware/" 2>/dev/null || true
    fi

    # Copy install-to-emmc.sh
    if [ -f "$WORK/scripts/install-to-emmc.sh" ]; then
        cp "$WORK/scripts/install-to-emmc.sh" "$IMAGE_ROOT_MNT/root/"
        chmod +x "$IMAGE_ROOT_MNT/root/install-to-emmc.sh"
        info "install-to-emmc.sh → /root/"
    fi

    sync
    umount "$IMAGE_ROOT_MNT"
    rmdir "$IMAGE_ROOT_MNT"
    IMAGE_ROOT_MNT=""
    info "Root partition ready"

    # ── Detach loop ──
    losetup -d "$IMAGE_LOOP"
    IMAGE_LOOP=""

    # ── Compress ──
    info "Compressing image with xz (this takes a few minutes)..."
    xz -T0 -6 "$IMAGE_FILE"

    info ""
    info "=== Image ready ==="
    info "  $IMAGE_XZ ($(du -h "$IMAGE_XZ" | cut -f1))"
    info ""
    info "Flash to USB:"
    info "  xz -d $IMAGE_XZ"
    info "  sudo dd if=$IMAGE_FILE of=/dev/sdX bs=4M status=progress"
}

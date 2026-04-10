#!/bin/bash
# build-image.sh — Create boot + rootfs images for Surface 2
# Sourced by build.sh — do not run directly.
#
# Creates TWO separate dd-able images:
#   surface2-boot-usb.img     — FAT32, ~130 MB → flash to USB stick
#   surface2-rootfs-sdcard.img — ext4,  ~4 GB  → flash to micro-SD card
#
# Requires: losetup, parted, mkfs.vfat, mkfs.ext4, mount (run with --privileged)

USB_IMAGE_NAME="${USB_IMAGE_NAME:-surface2-boot-usb}"
SD_IMAGE_NAME="${SD_IMAGE_NAME:-surface2-rootfs-sdcard}"
BOOT_SIZE_MB=130
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-4096}"

# Raspberry Pi OS Lite (Bookworm) armhf
RASPIOS_URL="${RASPIOS_URL:-https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2024-11-19/2024-11-19-raspios-bookworm-armhf-lite.img.xz}"

# ─── Cleanup on exit ───────────────────────────────────────────────
IMAGE_MNT=""
IMAGE_LOOP=""
IMAGE_RLOOP=""
IMAGE_RPI_MNT=""
IMAGE_KPARTX=false

image_cleanup() {
    set +e
    for m in "$IMAGE_RPI_MNT" "$IMAGE_MNT"; do
        [ -n "$m" ] && mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null
        [ -n "$m" ] && [ -d "$m" ] && rmdir "$m" 2>/dev/null
    done
    [ -n "$IMAGE_RLOOP" ] && losetup -d "$IMAGE_RLOOP" 2>/dev/null
    $IMAGE_KPARTX && [ -n "$IMAGE_LOOP" ] && kpartx -d "$IMAGE_LOOP" 2>/dev/null
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

# ─── Helper: create a single-partition image ──────────────────────
# Usage: create_partitioned_image <file> <size_mb> <fstype> <label>
create_partitioned_image() {
    local IMG_FILE="$1" SIZE_MB="$2" FSTYPE="$3" LABEL="$4"

    rm -f "$IMG_FILE"
    truncate -s "${SIZE_MB}M" "$IMG_FILE"

    parted -s "$IMG_FILE" mklabel msdos
    if [ "$FSTYPE" = "fat32" ]; then
        parted -s "$IMG_FILE" mkpart primary fat32 1MiB 100%
        parted -s "$IMG_FILE" set 1 boot on
    else
        parted -s "$IMG_FILE" mkpart primary ext2 1MiB 100%
    fi

    IMAGE_LOOP=$(losetup --find --show "$IMG_FILE")
    kpartx -av "$IMAGE_LOOP"
    IMAGE_KPARTX=true
    sleep 1

    local LOOP_BASE PART
    LOOP_BASE=$(basename "$IMAGE_LOOP")
    PART="/dev/mapper/${LOOP_BASE}p1"
    [ -b "$PART" ] || error "$PART not found. Ensure Docker is run with --privileged."

    if [ "$FSTYPE" = "fat32" ]; then
        mkfs.vfat -F 32 -n "$LABEL" "$PART"
    else
        mkfs.ext4 -L "$LABEL" -q "$PART"
    fi

    IMAGE_MNT=$(mktemp -d)
    mount "$PART" "$IMAGE_MNT"
}

# ─── Helper: finalize and detach image ────────────────────────────
finalize_image() {
    sync
    umount "$IMAGE_MNT"
    rmdir "$IMAGE_MNT"
    IMAGE_MNT=""
    kpartx -d "$IMAGE_LOOP"
    IMAGE_KPARTX=false
    losetup -d "$IMAGE_LOOP"
    IMAGE_LOOP=""
}

# ─── Build both images ────────────────────────────────────────────
build_image() {
    local USB_FILE="$OUTPUT_DIR/$USB_IMAGE_NAME.img"
    local SD_FILE="$OUTPUT_DIR/$SD_IMAGE_NAME.img"

    info "=== Creating Surface 2 images ==="
    info "USB boot:   ${BOOT_SIZE_MB}MB → $USB_IMAGE_NAME.img"
    info "SD rootfs:  ${ROOTFS_SIZE_MB}MB → $SD_IMAGE_NAME.img"

    trap 'image_cleanup; exit 1' INT TERM
    trap 'image_cleanup' EXIT

    # ── Download Raspberry Pi OS ──
    download_raspios

    # ══════════════════════════════════════════════════════════════
    # Image 1: USB boot stick (FAT32)
    # ══════════════════════════════════════════════════════════════
    info ""
    info "--- USB boot image (${BOOT_SIZE_MB}MB) ---"

    create_partitioned_image "$USB_FILE" "$BOOT_SIZE_MB" "fat32" "S2BOOT"

    info "Copying boot files..."
    cp "$BOOT_DIR/boot.efi"    "$IMAGE_MNT/"
    cp "$BOOT_DIR/cmdline.txt" "$IMAGE_MNT/"
    cp "$BOOT_DIR/cmdline-emmc.txt" "$IMAGE_MNT/" 2>/dev/null || true
    cp "$BOOT_DIR/startup.nsh" "$IMAGE_MNT/" 2>/dev/null || true

    for dtb in "$BOOT_DIR"/*.dtb; do
        [ -f "$dtb" ] && cp "$dtb" "$IMAGE_MNT/"
    done

    # EFI/BOOT/BOOTARM.EFI — what UEFI firmware loads on ARM boot
    mkdir -p "$IMAGE_MNT/EFI/BOOT"
    cp "$BOOT_DIR/boot.efi" "$IMAGE_MNT/EFI/BOOT/BOOTARM.EFI"

    info "Boot partition contents:"
    ls -lh "$IMAGE_MNT/"

    finalize_image
    info "USB image: $(du -h "$USB_FILE" | cut -f1) → $USB_FILE"

    # ══════════════════════════════════════════════════════════════
    # Image 2: SD card rootfs (ext4)
    # ══════════════════════════════════════════════════════════════
    info ""
    info "--- SD card rootfs image (${ROOTFS_SIZE_MB}MB) ---"

    create_partitioned_image "$SD_FILE" "$ROOTFS_SIZE_MB" "ext4" "S2ROOT"

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
    cp -a "$IMAGE_RPI_MNT"/. "$IMAGE_MNT"/

    umount "$IMAGE_RPI_MNT"
    losetup -d "$IMAGE_RLOOP"
    rmdir "$IMAGE_RPI_MNT"
    IMAGE_RLOOP="" IMAGE_RPI_MNT=""

    # Install kernel modules
    if [ -d "$STAGING_DIR/lib/modules" ]; then
        info "Installing kernel modules..."
        mkdir -p "$IMAGE_MNT/lib/modules"
        cp -a "$STAGING_DIR/lib/modules"/* "$IMAGE_MNT/lib/modules/"
    fi

    # Install Wi-Fi firmware
    if [ -d "$STAGING_DIR/lib/firmware" ]; then
        info "Installing Wi-Fi firmware..."
        mkdir -p "$IMAGE_MNT/lib/firmware"
        cp -a "$STAGING_DIR/lib/firmware"/* "$IMAGE_MNT/lib/firmware/" 2>/dev/null || true
    fi

    # Copy install-to-emmc.sh
    if [ -f "$WORK/scripts/install-to-emmc.sh" ]; then
        cp "$WORK/scripts/install-to-emmc.sh" "$IMAGE_MNT/root/"
        chmod +x "$IMAGE_MNT/root/install-to-emmc.sh"
        info "install-to-emmc.sh → /root/"
    fi

    finalize_image
    info "SD image: $(du -h "$SD_FILE" | cut -f1) → $SD_FILE"

    # ══════════════════════════════════════════════════════════════
    info ""
    info "=== Both images ready ==="
    info ""
    info "1. Flash USB stick (boot):"
    info "   sudo dd if=$USB_FILE of=/dev/sdX bs=4M status=progress"
    info ""
    info "2. Flash micro-SD card (rootfs):"
    info "   sudo dd if=$SD_FILE of=/dev/sdY bs=4M status=progress"
    info ""
    info "3. Insert both into Surface 2 and boot (Volume Down)"
}

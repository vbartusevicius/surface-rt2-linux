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
IMAGE_KPARTX=false

image_cleanup() {
    set +e
    for m in "$IMAGE_RPI_MNT" "$IMAGE_ROOT_MNT" "$IMAGE_BOOT_MNT"; do
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
    # Use losetup (no --partscan) + kpartx for reliable partition access in Docker.
    # --partscan depends on udev/kernel creating /dev/loop0p1 which often fails
    # in containers. kpartx creates /dev/mapper/loop0p1 via device-mapper.
    IMAGE_LOOP=$(losetup --find --show "$IMAGE_FILE")
    info "Loop device: $IMAGE_LOOP"

    info "Creating partition mappings with kpartx..."
    kpartx -av "$IMAGE_LOOP"
    IMAGE_KPARTX=true
    sleep 1

    # kpartx creates /dev/mapper/loop<N>p<N> from /dev/loop<N>
    local LOOP_BASE
    LOOP_BASE=$(basename "$IMAGE_LOOP")
    local PART1="/dev/mapper/${LOOP_BASE}p1"
    local PART2="/dev/mapper/${LOOP_BASE}p2"

    # Verify partition devices exist
    [ -b "$PART1" ] || error "Partition $PART1 not found. Ensure Docker is run with --privileged."
    [ -b "$PART2" ] || error "Partition $PART2 not found. Ensure Docker is run with --privileged."

    # ── Format ──
    info "Formatting p1 as FAT32 (S2BOOT)..."
    mkfs.vfat -F 32 -n "S2BOOT" "$PART1"

    info "Formatting p2 as ext4 (S2ROOT)..."
    mkfs.ext4 -L "S2ROOT" -q "$PART2"

    # ── Populate p1 (boot) ──
    IMAGE_BOOT_MNT=$(mktemp -d)
    mount "$PART1" "$IMAGE_BOOT_MNT"

    info "Copying boot files to p1..."
    cp "$BOOT_DIR/boot.efi"    "$IMAGE_BOOT_MNT/"
    cp "$BOOT_DIR/cmdline.txt" "$IMAGE_BOOT_MNT/"
    cp "$BOOT_DIR/cmdline-emmc.txt" "$IMAGE_BOOT_MNT/" 2>/dev/null || true
    cp "$BOOT_DIR/startup.nsh" "$IMAGE_BOOT_MNT/" 2>/dev/null || true
    cp "$BOOT_DIR/initrd.gz"   "$IMAGE_BOOT_MNT/" 2>/dev/null || true

    for dtb in "$BOOT_DIR"/*.dtb; do
        [ -f "$dtb" ] && cp "$dtb" "$IMAGE_BOOT_MNT/"
    done

    # EFI/BOOT/BOOTARM.EFI — what UEFI firmware loads on ARM boot.
    # This is boot.efi (the kernel's EFI stub). UEFI loads it directly.
    # NOTE: Surface 2 has a ~7 min delay in BootServices->LoadImage for
    # non-edk2 binaries. EfiFileChainloader was tried but doesn't work
    # (loads file into memory but fails to execute it). Accept the delay.
    mkdir -p "$IMAGE_BOOT_MNT/EFI/BOOT"
    cp "$BOOT_DIR/boot.efi" "$IMAGE_BOOT_MNT/EFI/BOOT/BOOTARM.EFI"
    info "BOOTARM.EFI = boot.efi (kernel)"

    # Keep chainloader on partition for future experiments if available
    if [ -f "$BOOT_DIR/EfiFileChainloader.efi" ]; then
        cp "$BOOT_DIR/EfiFileChainloader.efi" "$IMAGE_BOOT_MNT/EfiFileChainloader.efi"
    fi

    sync
    umount "$IMAGE_BOOT_MNT"
    rmdir "$IMAGE_BOOT_MNT"
    IMAGE_BOOT_MNT=""
    info "Boot partition ready"

    # ── Populate p2 (rootfs) ──
    IMAGE_ROOT_MNT=$(mktemp -d)
    mount "$PART2" "$IMAGE_ROOT_MNT"

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

    # ── Detach kpartx + loop ──
    kpartx -d "$IMAGE_LOOP"
    IMAGE_KPARTX=false
    losetup -d "$IMAGE_LOOP"
    IMAGE_LOOP=""

    info ""
    info "=== Image ready ==="
    info ""
    info "Flash to USB:"
    info "  sudo dd if=$IMAGE_FILE of=/dev/sdX bs=4M status=progress"
}

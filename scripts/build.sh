#!/bin/bash
# build.sh — Automated kernel + DTB + initramfs build for Surface 2
# Run inside Docker: docker run --rm -v "$PWD:/work" surface2-build /work/scripts/build.sh
set -euo pipefail

WORK=/work
KERNEL_DIR="$WORK/linux"
OUTPUT_DIR="$WORK/output"
BOOT_DIR="$OUTPUT_DIR/boot"
STAGING_DIR="$OUTPUT_DIR/staging"
CONFIGS_DIR="$WORK/configs"
DTS_DIR="$WORK/dts"
SCRIPTS_DIR="$WORK/scripts"

KERNEL_REPO="https://github.com/Open-Surface-RT/grate-linux.git"
KERNEL_BRANCH="microsoft-surface-2"

NPROC=$(nproc)

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-

# ─── Helper ─────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

# ─── Step 1: Clone kernel ──────────────────────────────────────────
clone_kernel() {
    if [ -d "$KERNEL_DIR/.git" ]; then
        info "Kernel source already present at $KERNEL_DIR"
        cd "$KERNEL_DIR"
        git fetch --depth 1 origin "$KERNEL_BRANCH" || true
    else
        info "Cloning kernel from $KERNEL_REPO (branch: $KERNEL_BRANCH) ..."
        git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
        cd "$KERNEL_DIR"
    fi
}

# ─── Step 2: Configure kernel ──────────────────────────────────────
configure_kernel() {
    info "Configuring kernel ..."
    cd "$KERNEL_DIR"

    # Start from Tegra defconfig
    make tegra_defconfig

    # Apply Surface 2 config fragment if it exists
    if [ -f "$CONFIGS_DIR/surface2_defconfig_fragment" ]; then
        info "Applying Surface 2 config fragment ..."
        "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m .config "$CONFIGS_DIR/surface2_defconfig_fragment"
    fi

    # Ensure critical options
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_EFI
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_EFI_STUB
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_OF
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_DRM_TEGRA
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_FB
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_FRAMEBUFFER_CONSOLE

    # Wi-Fi (Marvell SD8797 via SDIO)
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_MWIFIEX
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_MWIFIEX_SDIO

    # Touchscreen (Atmel maXTouch over I2C + HID-over-I2C fallback)
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_HID
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_I2C_HID
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_I2C_HID_OF
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_TOUCHSCREEN_ATMEL_MXT

    # Audio (WM8962)
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_SND_SOC
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_SND_SOC_WM8962
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_SND_SOC_TEGRA

    # Power management
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_MFD_TPS65090
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_CHARGER_TPS65090
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_MFD_PALMAS
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_REGULATOR_PALMAS
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_REGULATOR_TPS65090

    # Storage
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_MMC
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_MMC_SDHCI
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_MMC_SDHCI_TEGRA
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_EXT4_FS

    # USB
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_USB_EHCI_HCD
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_USB_EHCI_TEGRA
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_USB_XHCI_TEGRA

    # GPIO keys (buttons)
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_KEYBOARD_GPIO
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_INPUT_GPIO_KEYS

    # Thermal
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_TEGRA_SOCTHERM

    # Initramfs support (for installer boot)
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_BLK_DEV_INITRD
    "$KERNEL_DIR/scripts/config" --enable  CONFIG_BLK_DEV_RAM
    "$KERNEL_DIR/scripts/config" --set-val CONFIG_BLK_DEV_RAM_SIZE 65536

    # Ensure the config is consistent
    make olddefconfig
}

# ─── Step 3: Build kernel ──────────────────────────────────────────
build_kernel() {
    info "Building kernel (zImage + dtbs + modules) with $NPROC jobs ..."
    cd "$KERNEL_DIR"
    make -j"$NPROC" zImage dtbs modules
}

# ─── Step 4: Install modules ──────────────────────────────────────
install_modules() {
    info "Installing kernel modules ..."
    cd "$KERNEL_DIR"
    rm -rf "$STAGING_DIR/lib"
    make modules_install INSTALL_MOD_PATH="$STAGING_DIR"
}

# ─── Step 5: Build custom DTB ─────────────────────────────────────
build_dtb() {
    info "Building custom device tree ..."
    cd "$WORK"

    # Use our custom DTS if available, otherwise use kernel's built-in
    if [ -f "$DTS_DIR/tegra114-surface2.dts" ]; then
        info "Compiling custom DTS from $DTS_DIR/tegra114-surface2.dts"
        dtc -I dts -O dtb -o "$BOOT_DIR/surface2-custom.dtb" "$DTS_DIR/tegra114-surface2.dts" 2>/dev/null || \
            warn "Custom DTS compilation had warnings (may be OK)"
    fi

    # Also copy any kernel-built Tegra114 DTBs
    for dtb in "$KERNEL_DIR"/arch/arm/boot/dts/nvidia/tegra114*.dtb \
               "$KERNEL_DIR"/arch/arm/boot/dts/tegra114*.dtb; do
        if [ -f "$dtb" ]; then
            cp "$dtb" "$BOOT_DIR/"
            info "Copied $(basename "$dtb")"
        fi
    done
}

# ─── Step 6: Build initramfs ──────────────────────────────────────
build_initramfs() {
    info "Building initramfs (installer) ..."
    local INITRAMFS_DIR="$WORK/.initramfs"
    rm -rf "$INITRAMFS_DIR"

    # Create minimal initramfs structure
    mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,mnt/stage,mnt/root,tmp,usr/bin,usr/sbin,lib}

    # Copy busybox (static)
    if [ -f /bin/busybox ]; then
        cp /bin/busybox "$INITRAMFS_DIR/bin/busybox"
    elif [ -f /usr/bin/busybox ]; then
        cp /usr/bin/busybox "$INITRAMFS_DIR/bin/busybox"
    else
        error "busybox-static not found in container"
    fi
    chmod +x "$INITRAMFS_DIR/bin/busybox"

    # Create symlinks for essential commands
    for cmd in sh ash mount umount mkdir cp dd cat echo sync reboot \
               sleep ls mknod grep sed awk blkid switch_root \
               modprobe insmod lsmod ip ifconfig; do
        ln -sf busybox "$INITRAMFS_DIR/bin/$cmd"
    done

    # Copy our installer init script
    cp "$SCRIPTS_DIR/init.sh" "$INITRAMFS_DIR/init"
    chmod +x "$INITRAMFS_DIR/init"

    # Create /etc/mdev.conf (minimal)
    echo '.*  0:0 660' > "$INITRAMFS_DIR/etc/mdev.conf"

    # Pack initramfs
    cd "$INITRAMFS_DIR"
    find . | cpio -H newc -ov --owner root:root 2>/dev/null | gzip -9 > "$BOOT_DIR/initrd.gz"
    info "initrd.gz created ($(du -h "$BOOT_DIR/initrd.gz" | cut -f1))"
}

# ─── Step 7: Assemble boot files ──────────────────────────────────
assemble_boot() {
    info "Assembling boot files ..."
    cd "$KERNEL_DIR"

    # Copy kernel as EFI binary
    cp arch/arm/boot/zImage "$BOOT_DIR/boot.efi"
    info "boot.efi created ($(du -h "$BOOT_DIR/boot.efi" | cut -f1))"

    # Create startup.nsh
    cat > "$BOOT_DIR/startup.nsh" << 'STARTUP'
fs0:
\boot.efi initrd=\initrd.gz dtb=\surface2-custom.dtb root=/dev/ram0 init=/init console=tty0 earlyprintk loglevel=7
STARTUP

    # Create commandline.txt (Raspberry Pi boot style, alternative)
    cat > "$BOOT_DIR/commandline.txt" << 'CMDLINE'
initrd=initrd.gz root=/dev/ram0 init=/init console=tty0 earlyprintk loglevel=7
CMDLINE

    # Create post-install startup.nsh (boot from eMMC)
    cat > "$BOOT_DIR/startup-emmc.nsh" << 'STARTUP_EMMC'
fs0:
\boot.efi dtb=\surface2-custom.dtb root=/dev/mmcblk0p5 rootfstype=ext4 rootwait console=tty0 loglevel=4
STARTUP_EMMC

    info "Boot files assembled in $BOOT_DIR"
}

# ─── Step 8: Copy firmware blobs ──────────────────────────────────
copy_firmware() {
    info "Preparing firmware directory ..."
    mkdir -p "$STAGING_DIR/lib/firmware/mrvl"

    # Download Marvell firmware if not present
    local FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mrvl"
    for fw in sd8797_uapsta.bin sd8797_uapsta_a0.bin; do
        if [ ! -f "$STAGING_DIR/lib/firmware/mrvl/$fw" ]; then
            info "Downloading $fw ..."
            wget -q -O "$STAGING_DIR/lib/firmware/mrvl/$fw" "$FW_URL/$fw" 2>/dev/null || \
                warn "Could not download $fw — you may need to add it manually"
        fi
    done
}

# ─── Main ──────────────────────────────────────────────────────────
main() {
    info "=== Surface 2 Linux Build ==="
    info "Host: $(uname -m), Jobs: $NPROC"

    mkdir -p "$BOOT_DIR" "$STAGING_DIR"

    clone_kernel
    configure_kernel
    build_kernel
    install_modules
    build_dtb
    build_initramfs
    assemble_boot
    copy_firmware

    info ""
    info "=== Build complete! ==="
    info ""
    info "Boot files:    $BOOT_DIR/"
    ls -lh "$BOOT_DIR/"
    info ""
    info "Staging files: $STAGING_DIR/"
    du -sh "$STAGING_DIR/lib/modules" 2>/dev/null || true
    du -sh "$STAGING_DIR/lib/firmware" 2>/dev/null || true
    info ""
    info "Next steps:"
    info "  1. Copy $BOOT_DIR/* to a FAT32 USB drive"
    info "  2. Copy $STAGING_DIR/* to Surface 2 partition 6"
    info "  3. Add a rootfs.img (Raspbian) to partition 6"
    info "  4. Boot Surface 2 from USB"
}

main "$@"

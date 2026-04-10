#!/bin/bash
# build-boot.sh — DTB compilation, boot file assembly, firmware download
# Sourced by build.sh — do not run directly.

# ─── Build custom DTB ────────────────────────────────────────────
build_dtb() {
    info "Building custom device tree ..."
    cd "$WORK"

    # Use our custom DTS if available, otherwise use kernel's built-in
    if [ -f "$DTS_DIR/tegra114-surface2.dts" ]; then
        info "Compiling custom DTS from $DTS_DIR/tegra114-surface2.dts"
        # DTS uses #include — needs cpp preprocessing, so use the kernel build system
        local DTS_DEST=""
        # Try both old and new kernel DTS paths
        for dts_path in \
            "$KERNEL_DIR/arch/arm/boot/dts" \
            "$KERNEL_DIR/arch/arm/boot/dts/nvidia"; do
            if [ -d "$dts_path" ]; then
                DTS_DEST="$dts_path/tegra114-surface2.dts"
                break
            fi
        done
        if [ -n "$DTS_DEST" ]; then
            cp "$DTS_DIR/tegra114-surface2.dts" "$DTS_DEST"
            cd "$KERNEL_DIR"
            make "$(basename "$DTS_DEST" .dts).dtb" 2>&1 || \
                warn "Custom DTS compilation failed — will use kernel built-in DTBs"
        else
            warn "Cannot find kernel DTS directory — skipping custom DTS"
        fi
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

# ─── Copy compiled kernel as EFI binary ────────────────────────
copy_kernel_efi() {
    info "Copying kernel as boot.efi ..."
    cd "$KERNEL_DIR"
    cp arch/arm/boot/zImage "$BOOT_DIR/boot.efi"
    info "boot.efi created ($(du -h "$BOOT_DIR/boot.efi" | cut -f1))"
}

# ─── Download EfiFileChainloader ─────────────────────────────────
# Fixes Surface 2 BUG#1: BootServices->LoadImage causes 7-minute delay
# for EFI binaries not compiled with edk2. The EfiFileChainloader
# (compiled with edk2, 10KB) chainloads boot.efi directly, bypassing
# LoadImage entirely. No more startup.nsh needed for boot.
# Source: https://github.com/Open-Surface-RT/EfiApps
CHAINLOADER_URL="https://github.com/Open-Surface-RT/EfiApps/releases/download/v1.0.0/EfiFileChainloader.efi"

download_chainloader() {
    local DEST="$BOOT_DIR/EfiFileChainloader.efi"
    if [ -f "$DEST" ]; then
        info "EfiFileChainloader already present"
        return 0
    fi
    info "Downloading EfiFileChainloader (fixes 7-min boot delay)..."
    wget -q --show-progress -O "$DEST" "$CHAINLOADER_URL" || {
        warn "Failed to download EfiFileChainloader — falling back to EFI Shell boot"
        warn "Boot will work but with ~7 minute delay on Surface 2"
        rm -f "$DEST"
        return 1
    }
    info "EfiFileChainloader ready ($(du -h "$DEST" | cut -f1))"
}

# ─── Assemble boot files ────────────────────────────────────────
# Uses $DTB_NAME (set by build.sh — defaults to tegra114-surface2.dtb,
# prebuilt mode uses tegra114-microsoft-surface-2.dtb).
assemble_boot() {
    info "Assembling boot files (DTB=$DTB_NAME) ..."

    # Download EfiFileChainloader to bypass 7-min LoadImage delay
    download_chainloader || true

    # Create startup.nsh — fallback for EFI Shell boot (e.g. manual recovery).
    # Normal boot uses EfiFileChainloader which loads boot.efi directly.
    cat > "$BOOT_DIR/startup.nsh" << 'STARTUP'
fs0:
boot.efi
STARTUP

    # Create cmdline.txt — REQUIRED for Surface 2.
    # CONFIG_CMDLINE_FROM_FILE=y reads this and REPLACES load_options.
    #
    # Surface 2 devices:
    #   eMMC (internal)    → /dev/mmcblk0  (Tegra SDHCI)
    #   micro-SD card      → /dev/mmcblk1  (Tegra SDHCI, built-in driver)
    #   USB flash drive    → /dev/sda      (USB mass storage — loses power after boot)
    #
    # USB+SD boot: kernel on USB FAT32, rootfs on micro-SD card.
    # Surface 2 loses USB power after kernel loads (Ubuntu Wiki confirmed).
    # Workaround: rootfs on SD card (/dev/mmcblk1) which uses built-in
    # MMC/SDHCI drivers — no initramfs or USB modules needed.
    # SD card layout: single ext4 partition (p1=rootfs)
    # No initrd= needed — all required drivers are built-in.
    cat > "$BOOT_DIR/cmdline.txt" << CMDLINE
dtb=${DTB_NAME} root=/dev/mmcblk1p1 rootfstype=ext4 console=tty1 cpuidle.off=1 rootwait rw
CMDLINE

    # eMMC boot: rootfs on eMMC partition 5 = /dev/mmcblk0p5
    cat > "$BOOT_DIR/cmdline-emmc.txt" << CMDLINE_EMMC
dtb=${DTB_NAME} root=/dev/mmcblk0p5 rootfstype=ext4 console=tty1 cpuidle.off=1 rootwait rw
CMDLINE_EMMC

    info "Boot files assembled in $BOOT_DIR"
}

# ─── Copy firmware blobs ────────────────────────────────────────
copy_firmware() {
    info "Preparing firmware directory ..."
    mkdir -p "$STAGING_DIR/lib/firmware/mrvl"

    # Download Marvell firmware if not present
    local FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mrvl"
    for fw in sd8797_uapsta.bin; do
        if [ ! -f "$STAGING_DIR/lib/firmware/mrvl/$fw" ]; then
            info "Downloading $fw ..."
            wget -q -O "$STAGING_DIR/lib/firmware/mrvl/$fw" "$FW_URL/$fw" 2>/dev/null || \
                warn "Could not download $fw — you may need to add it manually"
        fi
    done
}

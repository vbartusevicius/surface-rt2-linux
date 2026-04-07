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

# ─── Assemble boot files ────────────────────────────────────────
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

# ─── Copy firmware blobs ────────────────────────────────────────
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

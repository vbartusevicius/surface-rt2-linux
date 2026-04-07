#!/bin/bash
# build.sh — Automated kernel + DTB + initramfs build for Surface 2
# Run inside Docker: docker run --rm -v "$PWD/output:/work/output" surface2-build
set -euo pipefail

# ─── Shared variables ───────────────────────────────────────────────
WORK=/work
KERNEL_DIR="$WORK/linux"
OUTPUT_DIR="$WORK/output"
BOOT_DIR="$OUTPUT_DIR/boot"
STAGING_DIR="$OUTPUT_DIR/staging"
CONFIGS_DIR="$WORK/configs"
DTS_DIR="$WORK/dts"
SCRIPTS_DIR="$WORK/scripts/build"

KERNEL_REPO="https://github.com/Open-Surface-RT/grate-linux.git"
KERNEL_BRANCH="microsoft-surface-2"

NPROC=$(nproc)

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-

# ─── Helpers ─────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

# ─── Source build steps ──────────────────────────────────────────────
source "$SCRIPTS_DIR/build-kernel.sh"
source "$SCRIPTS_DIR/build-initramfs.sh"
source "$SCRIPTS_DIR/build-boot.sh"
source "$SCRIPTS_DIR/build-verify.sh"

# ─── Main ────────────────────────────────────────────────────────────
main() {
    info "=== Surface 2 Linux Build ==="
    info "Host: $(uname -m), Jobs: $NPROC"

    # Clean previous output
    info "Cleaning output directories ..."
    rm -rf "$BOOT_DIR" "$STAGING_DIR"
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"

    clone_kernel
    configure_kernel
    build_kernel
    install_modules
    build_dtb
    build_initramfs
    assemble_boot
    copy_firmware
    verify_output || true

    info ""
    info "Boot files:    $BOOT_DIR/"
    ls -lh "$BOOT_DIR/"
    info ""
    info "Staging files: $STAGING_DIR/"
    du -sh "$STAGING_DIR/lib/modules" 2>/dev/null || true
    du -sh "$STAGING_DIR/lib/firmware" 2>/dev/null || true
    info ""
    info "Next steps:"
    info "  1. Prepare USB:  sudo ./scripts/prepare-usb.sh /dev/sdX [rootfs.img]"
    info "  2. Boot Surface 2 from USB (Volume Up at power on)"
}

main "$@"

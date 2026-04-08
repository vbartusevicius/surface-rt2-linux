#!/bin/bash
# build.sh — Automated kernel + DTB + initramfs build for Surface 2
#
# Commands:
#   ./build.sh              Full build: clone, compile, package (30+ min)
#   ./build.sh prebuilt     Download pre-built kernel from open-rt.party (~2 min)
#   ./build.sh dtb          Rebuild DTB only, copy to output   (seconds)
#   ./build.sh boot         Rebuild DTB + reassemble boot files (seconds)
#   ./build.sh quick        Everything except kernel compile    (~2 min)
#   ./build.sh kernel       Recompile kernel + modules only     (~20 min)
#
# Run inside Docker:
#   docker run --rm -v "$PWD/output:/work/output" surface2-build
#   docker run --rm -v "$PWD/output:/work/output" surface2-build dtb
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

# DTB filename — overridden by prebuilt mode
DTB_NAME="${DTB_NAME:-tegra114-surface2.dtb}"

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
source "$SCRIPTS_DIR/build-prebuilt.sh"
source "$SCRIPTS_DIR/build-verify.sh"

# ─── Command definitions ────────────────────────────────────────────
# Each command is a function that runs the appropriate steps.
# Assumes kernel source already exists for incremental commands.

cmd_full() {
    info "=== Full build ==="
    rm -rf "$BOOT_DIR" "$STAGING_DIR"
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"
    clone_kernel
    configure_kernel
    build_kernel
    install_modules
    copy_kernel_efi
    build_dtb
    build_initramfs
    assemble_boot
    copy_firmware
    verify_output || true
}

cmd_prebuilt() {
    info "=== Pre-built kernel (Andrew Lee's method) ==="
    DTB_NAME="tegra114-microsoft-surface-2.dtb"
    rm -rf "$BOOT_DIR" "$STAGING_DIR"
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"
    download_prebuilt
    build_initramfs
    assemble_boot
    copy_firmware
    verify_output || true
}

cmd_dtb() {
    info "=== Rebuild DTB only ==="
    mkdir -p "$BOOT_DIR"
    [ -d "$KERNEL_DIR" ] || error "Kernel source not found. Run a full build first."
    build_dtb
    info "Done. Copy output/boot/tegra114-surface2.dtb to your USB."
}

cmd_boot() {
    info "=== Rebuild DTB + boot files ==="
    mkdir -p "$BOOT_DIR"
    [ -d "$KERNEL_DIR" ] || error "Kernel source not found. Run a full build first."
    build_dtb
    assemble_boot
    info "Done. Copy output/boot/* to your USB."
}

cmd_quick() {
    info "=== Quick rebuild (skip kernel compile) ==="
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"
    [ -d "$KERNEL_DIR" ] || error "Kernel source not found. Run a full build first."
    build_dtb
    build_initramfs
    assemble_boot
    copy_firmware
    verify_output || true
}

cmd_kernel() {
    info "=== Recompile kernel + modules ==="
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"
    [ -d "$KERNEL_DIR" ] || error "Kernel source not found. Run a full build first."
    configure_kernel
    build_kernel
    install_modules
}

usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
  (none)    Full build: clone, compile, package         (~30 min)
  prebuilt  Download pre-built kernel from open-rt.party (~2 min)
  dtb       Rebuild DTB only, copy to output            (seconds)
  boot      Rebuild DTB + reassemble boot files         (seconds)
  quick     Skip kernel compile, rebuild everything else (~2 min)
  kernel    Recompile kernel + modules only              (~20 min)

Typical workflow after the first full build:
  1. Edit dts/tegra114-surface2.dts
  2. Run: ./build.sh dtb
  3. Copy output/boot/tegra114-surface2.dtb to USB
  4. Reboot Surface 2

Docker:
  docker run --rm -v "\$PWD/output:/work/output" surface2-build [COMMAND]
EOF
    exit 0
}

# ─── Main ────────────────────────────────────────────────────────────
CMD="${1:-full}"

case "$CMD" in
    full|"")  ;;
    prebuilt) ;;
    dtb)      ;;
    boot)     ;;
    quick)    ;;
    kernel)   ;;
    -h|--help|help) usage ;;
    *) error "Unknown command: $CMD  (try --help)" ;;
esac

info "=== Surface 2 Linux Build ==="
info "Host: $(uname -m), Jobs: $NPROC, Command: $CMD"

"cmd_$CMD"

# Summary
info ""
info "Boot files:    $BOOT_DIR/"
ls -lh "$BOOT_DIR/" 2>/dev/null || true
info ""
info "Staging files: $STAGING_DIR/"
du -sh "$STAGING_DIR/lib/modules" 2>/dev/null || true
du -sh "$STAGING_DIR/lib/firmware" 2>/dev/null || true

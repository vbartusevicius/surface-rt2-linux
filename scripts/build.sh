#!/bin/bash
# build.sh — Build system for Surface 2 Linux
#
# Commands:
#   ./build.sh prebuilt   Download pre-built kernel + create bootable USB image
#   ./build.sh image      (Re)create USB image from existing output/
#   ./build.sh dtb        Compile custom DTS only (for testing)
#   ./build.sh kernel     Recompile kernel + modules from source
#   ./build.sh full       Full build from source + create USB image
#
# Docker:
#   docker run --rm --privileged -v "$PWD/output:/work/output" surface2-build prebuilt
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
source "$SCRIPTS_DIR/build-boot.sh"
source "$SCRIPTS_DIR/build-prebuilt.sh"
source "$SCRIPTS_DIR/build-image.sh"
source "$SCRIPTS_DIR/build-verify.sh"

# ─── Command definitions ────────────────────────────────────────────

cmd_prebuilt() {
    info "=== Pre-built kernel + bootable USB image ==="
    DTB_NAME="tegra114-microsoft-surface-2.dtb"
    rm -rf "$BOOT_DIR" "$STAGING_DIR"
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"
    download_prebuilt
    assemble_boot
    copy_firmware
    verify_output || true
    build_image
}

cmd_image() {
    info "=== (Re)create USB image from existing output ==="
    [ -d "$BOOT_DIR" ] || error "Boot directory not found: $BOOT_DIR — run 'prebuilt' or 'full' first"
    [ -f "$BOOT_DIR/boot.efi" ] || error "boot.efi not found — run 'prebuilt' or 'full' first"
    build_image
}

cmd_dtb() {
    info "=== Compile custom DTB ==="
    mkdir -p "$BOOT_DIR"
    [ -d "$KERNEL_DIR" ] || error "Kernel source not found. Run 'full' first."
    build_dtb
    info ""
    info "Done. To test on Surface 2:"
    info "  1. Mount eMMC ESP:  mount /dev/mmcblk0p1 /mnt"
    info "  2. Backup old DTB:  cp /mnt/*.dtb /mnt/dtb-backup/"
    info "  3. Copy new DTB:    cp output/boot/*.dtb /mnt/"
    info "  4. Reboot"
    info "  If broken → boot from USB, restore DTB from backup"
}

cmd_kernel() {
    info "=== Recompile kernel + modules ==="
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"
    [ -d "$KERNEL_DIR" ] || clone_kernel
    configure_kernel
    build_kernel
    install_modules
    copy_kernel_efi
    build_dtb
    assemble_boot
    copy_firmware
    verify_output || true
}

cmd_full() {
    info "=== Full build from source + USB image ==="
    rm -rf "$BOOT_DIR" "$STAGING_DIR"
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"
    clone_kernel
    configure_kernel
    build_kernel
    install_modules
    copy_kernel_efi
    build_dtb
    assemble_boot
    copy_firmware
    verify_output || true
    build_image
}

usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
  prebuilt  Download pre-built kernel + create bootable USB image  (~10 min)
  image     (Re)create USB image from existing output/             (~5 min)
  dtb       Compile custom DTS only                                (seconds)
  kernel    Recompile kernel + modules from source                 (~20 min)
  full      Full build from source + create USB image              (~30 min)

Quick start (pre-built kernel):
  docker build -t surface2-build .
  docker run --rm --privileged -v "\$PWD/output:/work/output" surface2-build prebuilt
  # Flash output/*.img.xz to USB

DTS development workflow:
  1. Edit dts/tegra114-surface2.dts
  2. docker run --rm -v "\$PWD/output:/work/output" surface2-build dtb
  3. Copy output/boot/*.dtb to Surface 2 eMMC ESP
  4. Reboot — if broken, boot from USB to recover
EOF
    exit 0
}

# ─── Main ────────────────────────────────────────────────────────────
CMD="${1:-}"

case "$CMD" in
    prebuilt) ;;
    image)    ;;
    dtb)      ;;
    kernel)   ;;
    full)     ;;
    -h|--help|help|"") usage ;;
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

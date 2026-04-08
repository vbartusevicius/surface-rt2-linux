#!/bin/bash
# build-prebuilt.sh — Download pre-built boot files from open-rt.party
# Sourced by build.sh — do not run directly.
#
# Downloads surface-2-bootfiles+kernel.zip which contains the proven
# 5.17.0-rc4 kernel, DTB, and modules that work on Surface 2.

PREBUILT_ZIP_URL="https://files.open-rt.party/Linux/Other/surface-2-bootfiles%2Bkernel.zip"

# ─── Download and extract pre-built boot files ────────────────────
download_prebuilt() {
    info "Downloading pre-built Surface 2 boot files from open-rt.party ..."
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"

    # Download the zip if not cached
    local ZIP="/tmp/surface-2-bootfiles-kernel.zip"
    if [ ! -f "$ZIP" ]; then
        info "Downloading surface-2-bootfiles+kernel.zip ..."
        wget --progress=bar:force -O "$ZIP" "$PREBUILT_ZIP_URL" || \
            error "Failed to download from $PREBUILT_ZIP_URL"
    else
        info "Using cached zip"
    fi

    # Extract to a temp dir, then copy what we need
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    info "Extracting zip ..."
    python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$ZIP" "$TMP_DIR"

    # Copy boot.efi and DTB
    cp "$TMP_DIR/boot.efi" "$BOOT_DIR/"
    info "boot.efi copied ($(du -h "$BOOT_DIR/boot.efi" | cut -f1))"

    local dtb
    dtb=$(ls "$TMP_DIR"/tegra114*.dtb 2>/dev/null | head -1)
    if [ -n "$dtb" ]; then
        DTB_NAME=$(basename "$dtb")
        cp "$dtb" "$BOOT_DIR/"
        info "DTB copied: $DTB_NAME"
    else
        error "No DTB found in zip"
    fi

    # Copy modules (directory named after kernel version)
    mkdir -p "$STAGING_DIR/lib/modules"
    local mod_dir
    mod_dir=$(ls -d "$TMP_DIR"/5.17.0-* 2>/dev/null | head -1)
    if [ -n "$mod_dir" ] && [ -d "$mod_dir" ]; then
        cp -a "$mod_dir" "$STAGING_DIR/lib/modules/"
        info "Modules copied: $(basename "$mod_dir")"
    else
        warn "No modules directory found in zip"
    fi

    rm -rf "$TMP_DIR"
    info "Pre-built files ready"
}

#!/bin/bash
# build-prebuilt.sh — Download pre-built kernel + modules from open-rt.party
# Sourced by build.sh — do not run directly.
#
# Uses the same kernel and DTB that Andrew Lee's guide references.
# See: https://www.andrewjameslee.com/2025/03/running-linux-on-microsoft-surface-2-rt.html

PREBUILT_BASE_URL="https://files.open-rt.party/Linux-Kernel-Download/surface-2/2022-02-10"
PREBUILT_ZIMAGE="s2-zImage-5.17.0-rc3-next-20220207-Open-Surface-RT-g140d9605476d"
PREBUILT_MODULES="s2-modules-5.17.0-rc3-next-20220207-Open-Surface-RT-g140d9605476d.tar.xz"
PREBUILT_DTB="tegra114-microsoft-surface-2.dtb"

# ─── Download pre-built kernel, DTB, modules ──────────────────────
download_prebuilt() {
    info "Downloading pre-built Surface 2 kernel from open-rt.party ..."
    mkdir -p "$BOOT_DIR" "$STAGING_DIR"

    # Download kernel (zImage → boot.efi)
    if [ ! -f "$BOOT_DIR/boot.efi" ]; then
        info "Downloading kernel (zImage) ..."
        wget --progress=bar:force -O "$BOOT_DIR/boot.efi" \
            "$PREBUILT_BASE_URL/$PREBUILT_ZIMAGE" || \
            error "Failed to download kernel from $PREBUILT_BASE_URL/$PREBUILT_ZIMAGE"
        info "boot.efi downloaded ($(du -h "$BOOT_DIR/boot.efi" | cut -f1))"
    else
        info "Using cached boot.efi"
    fi

    # Download DTB
    if [ ! -f "$BOOT_DIR/$PREBUILT_DTB" ]; then
        info "Downloading device tree ($PREBUILT_DTB) ..."
        wget --progress=bar:force -O "$BOOT_DIR/$PREBUILT_DTB" \
            "$PREBUILT_BASE_URL/$PREBUILT_DTB" || \
            error "Failed to download DTB"
        info "DTB downloaded"
    else
        info "Using cached $PREBUILT_DTB"
    fi

    # Download and extract kernel modules
    if [ ! -d "$STAGING_DIR/lib/modules" ] || \
       [ -z "$(ls -A "$STAGING_DIR/lib/modules" 2>/dev/null)" ]; then
        info "Downloading kernel modules ..."
        local TMP_TAR="/tmp/$PREBUILT_MODULES"
        wget --progress=bar:force -O "$TMP_TAR" \
            "$PREBUILT_BASE_URL/$PREBUILT_MODULES" || \
            error "Failed to download modules"

        info "Extracting modules ..."
        local TMP_DIR
        TMP_DIR=$(mktemp -d)
        tar xf "$TMP_TAR" -C "$TMP_DIR"

        # Handle different tarball layouts:
        # Layout A: lib/modules/<version>/...
        # Layout B: <version>/kernel/...  (just the modules dir contents)
        mkdir -p "$STAGING_DIR/lib/modules"
        if [ -d "$TMP_DIR/lib/modules" ]; then
            cp -a "$TMP_DIR/lib/modules/"* "$STAGING_DIR/lib/modules/"
        else
            # Assume tarball contains the version directory directly
            cp -a "$TMP_DIR"/* "$STAGING_DIR/lib/modules/"
        fi

        rm -rf "$TMP_DIR" "$TMP_TAR"
        info "Modules extracted to $STAGING_DIR/lib/modules/"
    else
        info "Using cached modules in $STAGING_DIR/lib/modules/"
    fi
}

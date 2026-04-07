#!/bin/bash
# build-kernel.sh — Kernel clone, configure, build, install modules
# Sourced by build.sh — do not run directly.

# ─── Clone kernel ────────────────────────────────────────────────
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

# ─── Configure kernel ───────────────────────────────────────────
configure_kernel() {
    info "Configuring kernel ..."
    cd "$KERNEL_DIR"

    # Start from Tegra defconfig
    make tegra_defconfig

    # Apply Surface 2 config fragment (single source of truth for all HW options)
    if [ -f "$CONFIGS_DIR/surface2_defconfig_fragment" ]; then
        info "Applying Surface 2 config fragment ..."
        "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m .config "$CONFIGS_DIR/surface2_defconfig_fragment"
    else
        warn "Config fragment not found at $CONFIGS_DIR/surface2_defconfig_fragment"
    fi

    make olddefconfig
}

# ─── Build kernel ────────────────────────────────────────────────
build_kernel() {
    info "Building kernel (zImage + dtbs + modules) with $NPROC jobs ..."
    cd "$KERNEL_DIR"
    make -j"$NPROC" zImage dtbs modules
}

# ─── Install modules ────────────────────────────────────────────
install_modules() {
    info "Installing kernel modules ..."
    cd "$KERNEL_DIR"
    rm -rf "$STAGING_DIR/lib"
    make modules_install INSTALL_MOD_PATH="$STAGING_DIR"
}

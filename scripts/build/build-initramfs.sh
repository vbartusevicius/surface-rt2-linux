#!/bin/bash
# build-initramfs.sh — Build the initramfs (installer image)
# Sourced by build.sh — do not run directly.

build_initramfs() {
    info "Building initramfs (installer) ..."
    local INITRAMFS_DIR="$WORK/.initramfs"
    rm -rf "$INITRAMFS_DIR"

    # Create minimal initramfs structure
    mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,mnt/stage,mnt/root,tmp,usr/bin,usr/sbin,lib}

    # Copy busybox (static, ARM) — installed via busybox-static:armhf
    local BB_ARM=""
    for candidate in \
        /usr/lib/arm-linux-gnueabihf/busybox/busybox \
        /usr/bin/arm-linux-gnueabihf-busybox \
        /bin/busybox; do
        if [ -f "$candidate" ] && file "$candidate" | grep -qi arm; then
            BB_ARM="$candidate"
            break
        fi
    done
    [ -n "$BB_ARM" ] || error "ARM busybox-static not found. Install busybox-static:armhf in the container."
    cp "$BB_ARM" "$INITRAMFS_DIR/bin/busybox"
    chmod +x "$INITRAMFS_DIR/bin/busybox"
    info "Using ARM busybox from $BB_ARM"

    # Create symlinks for essential commands
    for cmd in sh ash mount umount mkdir cp dd cat echo sync reboot \
               sleep ls mknod grep sed awk blkid switch_root \
               modprobe insmod lsmod ip ifconfig; do
        ln -sf busybox "$INITRAMFS_DIR/bin/$cmd"
    done

    # Copy ARM e2fsprogs (for e2fsck / resize2fs in installer)
    for tool in e2fsck resize2fs; do
        local TOOL_ARM=""
        for candidate in \
            /opt/armhf/root/sbin/$tool \
            /opt/armhf/root/usr/sbin/$tool \
            /usr/lib/arm-linux-gnueabihf/$tool \
            /usr/sbin/$tool; do
            if [ -f "$candidate" ] && file "$candidate" | grep -qi arm; then
                TOOL_ARM="$candidate"
                break
            fi
        done
        if [ -n "$TOOL_ARM" ]; then
            cp "$TOOL_ARM" "$INITRAMFS_DIR/sbin/$tool"
            chmod +x "$INITRAMFS_DIR/sbin/$tool"
            info "Copied ARM $tool from $TOOL_ARM"
        else
            warn "ARM $tool not found — installer will skip filesystem check/resize"
        fi
    done

    # Copy ARM shared libraries needed by e2fsprogs
    if [ -d /opt/armhf/root/lib ]; then
        mkdir -p "$INITRAMFS_DIR/lib"
        cp -a /opt/armhf/root/lib/arm-linux-gnueabihf/* "$INITRAMFS_DIR/lib/" 2>/dev/null || true
        # Also copy the dynamic linker
        cp -a /opt/armhf/root/lib/ld-linux-armhf.so* "$INITRAMFS_DIR/lib/" 2>/dev/null || true
    fi

    # Copy our installer init script
    cp "$WORK/scripts/init.sh" "$INITRAMFS_DIR/init"
    chmod +x "$INITRAMFS_DIR/init"

    # Create /etc/mdev.conf (minimal)
    echo '.*  0:0 660' > "$INITRAMFS_DIR/etc/mdev.conf"

    # Pack initramfs
    cd "$INITRAMFS_DIR"
    find . | cpio -H newc -ov --owner root:root 2>/dev/null | gzip -9 > "$BOOT_DIR/initrd.gz"
    info "initrd.gz created ($(du -h "$BOOT_DIR/initrd.gz" | cut -f1))"
}

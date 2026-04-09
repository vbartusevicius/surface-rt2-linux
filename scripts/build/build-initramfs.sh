#!/bin/bash
# build-initramfs.sh — Create minimal initramfs for USB boot on Surface 2
# Sourced by build.sh — do not run directly.
#
# The pre-built kernel has USB_STORAGE=m (module). Without initramfs,
# USB flash drives never appear as /dev/sda. This tiny initramfs loads
# the USB storage module, waits for the root device, then switch_roots.
#
# Contents (~1.5 MB):
#   /init                  — minimal shell script
#   /bin/busybox           — static ARM binary (shell, insmod, mount, switch_root)
#   /lib/modules/...       — usb-storage.ko + dependencies (scsi_mod, sd_mod)

INITRD_NAME="initrd.gz"

# ─── Download busybox static ARM binary ─────────────────────────────
# Try multiple sources since individual mirrors go down.
download_busybox_arm() {
    local DEST="$1"

    # Source 1: GitHub pre-built static binaries (v1.36.0, ARM EABI5)
    local URL1="https://github.com/shutingrz/busybox-static-binaries-fat/raw/main/busybox-arm-linux-gnueabi"
    # Source 2: busybox.net official (may be down)
    local URL2="https://busybox.net/downloads/binaries/1.35.0-arm-linux-musleabi/busybox"

    for url in "$URL1" "$URL2"; do
        info "Trying: $url"
        if wget -q --show-progress -O "$DEST" "$url" 2>/dev/null; then
            chmod +x "$DEST"
            local FTYPE
            FTYPE=$(file "$DEST" 2>/dev/null || true)
            if echo "$FTYPE" | grep -qi "ARM"; then
                info "Downloaded busybox ARM static binary"
                return 0
            else
                warn "Downloaded file is not ARM binary: $FTYPE"
                rm -f "$DEST"
            fi
        fi
    done

    # Source 3: Extract from Debian armhf package
    info "Trying Debian armhf package..."
    local DEB_DIR
    DEB_DIR=$(mktemp -d)
    if wget -q -O "$DEB_DIR/bb.deb" \
        "https://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.35.0-4+b3_armhf.deb" 2>/dev/null; then
        if dpkg-deb -x "$DEB_DIR/bb.deb" "$DEB_DIR/extract" 2>/dev/null; then
            if [ -f "$DEB_DIR/extract/bin/busybox" ]; then
                cp "$DEB_DIR/extract/bin/busybox" "$DEST"
                chmod +x "$DEST"
                rm -rf "$DEB_DIR"
                info "Extracted busybox from Debian armhf package"
                return 0
            fi
        fi
    fi
    rm -rf "$DEB_DIR"

    error "Failed to download busybox ARM static binary from all sources"
}

# ─── Build initramfs ────────────────────────────────────────────────
build_initramfs() {
    info "=== Building minimal initramfs for USB boot ==="

    local INITRAMFS_DIR
    INITRAMFS_DIR=$(mktemp -d)

    # ── Directory structure ──
    mkdir -p "$INITRAMFS_DIR"/{bin,dev,proc,sys,mnt,lib/modules}

    # ── Download busybox-static (ARM) ──
    local BUSYBOX_CACHE="/tmp/busybox-arm-static"
    if [ ! -f "$BUSYBOX_CACHE" ]; then
        download_busybox_arm "$BUSYBOX_CACHE"
    else
        info "Using cached busybox"
    fi
    cp "$BUSYBOX_CACHE" "$INITRAMFS_DIR/bin/busybox"
    chmod +x "$INITRAMFS_DIR/bin/busybox"
    info "busybox: $(du -h "$INITRAMFS_DIR/bin/busybox" | cut -f1)"

    # ── Collect USB storage modules ──
    # Find the kernel version from the modules directory
    local KVER_DIR
    KVER_DIR=$(ls -d "$STAGING_DIR/lib/modules"/5.* 2>/dev/null | head -1)
    if [ -z "$KVER_DIR" ]; then
        KVER_DIR=$(ls -d "$STAGING_DIR/lib/modules"/*/ 2>/dev/null | head -1)
    fi

    if [ -n "$KVER_DIR" ] && [ -d "$KVER_DIR" ]; then
        local KVER
        KVER=$(basename "$KVER_DIR")
        info "Kernel modules version: $KVER"
        mkdir -p "$INITRAMFS_DIR/lib/modules/$KVER"

        # Modules needed for USB mass storage (in load order):
        #   scsi_mod.ko    — SCSI core
        #   sd_mod.ko      — SCSI disk
        #   usb-storage.ko — USB mass storage class
        local MOD_COUNT=0
        for mod_name in scsi_mod sd_mod usb-storage; do
            local mod_file
            mod_file=$(find "$KVER_DIR" -name "${mod_name}.ko" -o -name "${mod_name}.ko.xz" -o -name "${mod_name}.ko.gz" 2>/dev/null | head -1)
            if [ -n "$mod_file" ] && [ -f "$mod_file" ]; then
                cp "$mod_file" "$INITRAMFS_DIR/lib/modules/$KVER/"
                MOD_COUNT=$((MOD_COUNT + 1))
                info "  Included: $(basename "$mod_file")"
            else
                info "  Not found as module: ${mod_name}.ko (may be built-in)"
            fi
        done
        info "Collected $MOD_COUNT modules"
    else
        warn "No modules directory found — initramfs will try without insmod"
    fi

    # ── Create /init script ──
    cat > "$INITRAMFS_DIR/init" << 'INITEOF'
#!/bin/busybox sh
# Minimal initramfs for Surface 2 USB boot
# Loads USB storage module, waits for root device, then switch_root.
#
# Surface 2 known issue: USB VBUS power may be cut after kernel loads.
# cmdline.txt includes usbcore.autosuspend=-1 to prevent this.

BB=/bin/busybox

# Mount virtual filesystems
$BB mount -t proc none /proc
$BB mount -t sysfs none /sys
$BB mount -t devtmpfs none /dev 2>/dev/null || $BB mdev -s

echo "[initramfs] Surface 2 USB boot initramfs"
echo "[initramfs] cmdline: $($BB cat /proc/cmdline)"

# Load modules (order matters: dependencies first)
echo "[initramfs] Loading USB storage modules..."
KVER=$($BB uname -r 2>/dev/null || echo "unknown")
echo "[initramfs] Kernel: $KVER"
for mod in scsi_mod sd_mod usb-storage; do
    for ext in .ko .ko.xz .ko.gz; do
        MOD="/lib/modules/$KVER/${mod}${ext}"
        if [ -f "$MOD" ]; then
            $BB insmod "$MOD" 2>/dev/null && echo "[initramfs]   Loaded: $mod" || \
                echo "[initramfs]   Already built-in or failed: $mod"
            break
        fi
    done
done

# Trigger device discovery after module load
$BB mdev -s 2>/dev/null
$BB sleep 1

# Parse root= from /proc/cmdline
ROOT_DEV=""
for param in $($BB cat /proc/cmdline); do
    case "$param" in
        root=*) ROOT_DEV="${param#root=}" ;;
    esac
done

[ -n "$ROOT_DEV" ] || ROOT_DEV="/dev/sda2"
echo "[initramfs] Waiting for root device: $ROOT_DEV"

# Wait up to 30 seconds for the root device
TRIES=0
while [ ! -b "$ROOT_DEV" ] && [ $TRIES -lt 30 ]; do
    $BB sleep 1
    TRIES=$((TRIES + 1))
    # Trigger device discovery
    $BB mdev -s 2>/dev/null
    # Print progress every 5 seconds
    if [ $((TRIES % 5)) -eq 0 ]; then
        echo "[initramfs]   ...waiting ($TRIES/30s)"
        $BB ls /dev/sd* /dev/mmcblk* 2>/dev/null | $BB head -20
    fi
done

if [ ! -b "$ROOT_DEV" ]; then
    echo ""
    echo "[initramfs] ============================================"
    echo "[initramfs] ERROR: Root device $ROOT_DEV not found!"
    echo "[initramfs] ============================================"
    echo "[initramfs] cmdline: $($BB cat /proc/cmdline)"
    echo "[initramfs] Block devices:"
    $BB ls -l /dev/sd* /dev/mmcblk* 2>/dev/null || echo "  (none)"
    echo "[initramfs] USB devices:"
    $BB ls /sys/bus/usb/devices/ 2>/dev/null
    echo "[initramfs] Loaded modules:"
    $BB cat /proc/modules 2>/dev/null | $BB head -20
    echo ""
    echo "[initramfs] TIP: Surface 2 may need a powered USB hub."
    echo "[initramfs] Dropping to debug shell..."
    exec $BB sh
fi

echo "[initramfs] Found $ROOT_DEV after ${TRIES}s — mounting..."

# Parse rootfstype= from cmdline
FSTYPE="ext4"
for param in $($BB cat /proc/cmdline); do
    case "$param" in
        rootfstype=*) FSTYPE="${param#rootfstype=}" ;;
    esac
done

$BB mount -t "$FSTYPE" -o rw "$ROOT_DEV" /mnt || {
    echo "[initramfs] ERROR: Failed to mount $ROOT_DEV as $FSTYPE"
    exec $BB sh
}

echo "[initramfs] Mounted $ROOT_DEV → switch_root"

# Clean up and switch
$BB umount /proc /sys
exec $BB switch_root /mnt /sbin/init
INITEOF
    chmod +x "$INITRAMFS_DIR/init"

    # ── Pack as cpio.gz ──
    info "Creating initrd.gz..."
    (cd "$INITRAMFS_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$BOOT_DIR/$INITRD_NAME")
    local SIZE
    SIZE=$(du -h "$BOOT_DIR/$INITRD_NAME" | cut -f1)
    info "initrd.gz ready: $SIZE"

    # Cleanup
    rm -rf "$INITRAMFS_DIR"
}

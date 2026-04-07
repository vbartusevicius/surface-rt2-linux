#!/bin/sh
# init.sh — Surface 2 Linux automated installer
# This script runs as PID 1 inside the initramfs.
# It copies the root filesystem to the internal eMMC partition,
# installs kernel modules and firmware, then boots the real system.
set -eu

# ─── Configuration ──────────────────────────────────────────────────
ROOT_PART="/dev/mmcblk0p5"    # Target Linux root partition
ROOTFS_IMG="rootfs.img"       # Name of the rootfs image on staging
USB_LABEL="S2LINUX"           # FAT32 label set by prepare-usb.sh
STAGE_MNT="/mnt/stage"
ROOT_MNT="/mnt/root"

# ─── Helpers ────────────────────────────────────────────────────────
msg()  { echo "[INSTALLER] $*"; }
fail() { echo "[INSTALLER] ERROR: $*"; echo "Dropping to shell..."; exec /bin/sh; }

# ─── Setup minimal environment ─────────────────────────────────────
msg "Surface 2 Linux Installer starting ..."
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts
mount -t devpts   devpts   /dev/pts

# Wait for eMMC to appear
msg "Waiting for eMMC ..."
RETRY=30
while [ ! -b "$ROOT_PART" ] && [ "$RETRY" -gt 0 ]; do
    sleep 1
    RETRY=$((RETRY - 1))
done
[ -b "$ROOT_PART" ] || fail "Root partition $ROOT_PART not found after 30s"

# ─── Find staging source ────────────────────────────────────────
# Try USB drive (S2LINUX label from prepare-usb.sh) first, then eMMC p6
msg "Looking for staging source ..."
sleep 2  # give USB time to enumerate

STAGE_PART=""
for dev in /dev/sd[a-z]1 /dev/sd[a-z]2; do
    [ -b "$dev" ] || continue
    if blkid "$dev" 2>/dev/null | grep -q "LABEL=\"$USB_LABEL\""; then
        STAGE_PART="$dev"
        msg "Found USB staging: $dev (label=$USB_LABEL)"
        break
    fi
done

if [ -z "$STAGE_PART" ]; then
    if [ -b "/dev/mmcblk0p6" ]; then
        STAGE_PART="/dev/mmcblk0p6"
        msg "Using eMMC staging: $STAGE_PART"
    else
        fail "No staging source found (no USB with $USB_LABEL label, no /dev/mmcblk0p6)"
    fi
fi


# ─── Safety checks ────────────────────────────────────────────────
# Refuse to write to EFI (p1), Windows (p2), or recovery (p3/p4)
case "$ROOT_PART" in
    *mmcblk0p[1234])
        fail "SAFETY: $ROOT_PART looks like an EFI/Windows/recovery partition. Refusing to overwrite."
        ;;
esac

# Detect filesystem type and label
ROOT_FSTYPE=$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null || true)
ROOT_LABEL=$(blkid -s LABEL -o value "$ROOT_PART" 2>/dev/null || true)
ROOT_LABEL_LC=$(printf '%s' "$ROOT_LABEL" | tr '[:upper:]' '[:lower:]')

# Refuse NTFS always
case "$ROOT_FSTYPE" in
    ntfs|ntfs-3g)
        fail "SAFETY: $ROOT_PART contains NTFS (Windows). Refusing to overwrite."
        ;;
    vfat)
        # Allow FAT32 only if the volume label is exactly "linux"
        if [ "$ROOT_LABEL_LC" != "linux" ]; then
            fail "SAFETY: $ROOT_PART contains FAT32 but label is '${ROOT_LABEL:-unknown}'. Refusing to overwrite unless label is 'linux'."
        fi
        ;;
esac

msg "Target partition $ROOT_PART passed safety checks (type: ${ROOT_FSTYPE:-unformatted}, label: ${ROOT_LABEL:-none})"

# ─── Mount staging ─────────────────────────────────────────────────
msg "Mounting staging partition ($STAGE_PART) ..."
mkdir -p "$STAGE_MNT" "$ROOT_MNT"
mount -t vfat "$STAGE_PART" "$STAGE_MNT" || fail "Cannot mount $STAGE_PART"

# Locate rootfs image
ROOTFS_PATH=""
for candidate in \
    "$STAGE_MNT/$ROOTFS_IMG" \
    "$STAGE_MNT/raspios_armhf-*/$ROOTFS_IMG" \
    "$STAGE_MNT"/root.img; do
    # Use shell glob
    for f in $candidate; do
        if [ -f "$f" ]; then
            ROOTFS_PATH="$f"
            break 2
        fi
    done
done

[ -n "$ROOTFS_PATH" ] || fail "No rootfs image found on staging partition"
msg "Found rootfs image: $ROOTFS_PATH"

# ─── Write rootfs to target partition ──────────────────────────────
msg "Writing rootfs to $ROOT_PART (this may take several minutes) ..."
dd if="$ROOTFS_PATH" of="$ROOT_PART" bs=4M status=progress conv=fsync 2>&1 || \
    fail "dd failed writing rootfs"
sync

msg "Checking filesystem ..."
e2fsck -fy "$ROOT_PART" 2>/dev/null || true

# Resize to fill partition
resize2fs "$ROOT_PART" 2>/dev/null || true
sync

# ─── Mount new root and install extras ─────────────────────────────
msg "Mounting new root filesystem ..."
mount -t ext4 "$ROOT_PART" "$ROOT_MNT" || fail "Cannot mount new root at $ROOT_PART"

# Copy kernel modules
if [ -d "$STAGE_MNT/lib/modules" ]; then
    msg "Installing kernel modules ..."
    mkdir -p "$ROOT_MNT/lib/modules"
    cp -a "$STAGE_MNT/lib/modules/"* "$ROOT_MNT/lib/modules/" 2>/dev/null || true
fi

# Copy firmware
if [ -d "$STAGE_MNT/lib/firmware" ]; then
    msg "Installing firmware ..."
    mkdir -p "$ROOT_MNT/lib/firmware"
    cp -a "$STAGE_MNT/lib/firmware/"* "$ROOT_MNT/lib/firmware/" 2>/dev/null || true
fi

# ─── Fix fstab ─────────────────────────────────────────────────────
msg "Writing /etc/fstab ..."
# Try to get PARTUUID, fall back to device path
ROOT_UUID=$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)

if [ -n "$ROOT_UUID" ]; then
    cat > "$ROOT_MNT/etc/fstab" << EOF
# Surface 2 Linux - generated by installer
PARTUUID=$ROOT_UUID  /  ext4  defaults,noatime  0  1
EOF
else
    cat > "$ROOT_MNT/etc/fstab" << EOF
# Surface 2 Linux - generated by installer
$ROOT_PART  /  ext4  defaults,noatime  0  1
EOF
fi

# ─── Set hostname ──────────────────────────────────────────────────
echo "surface2" > "$ROOT_MNT/etc/hostname"

# ─── Enable serial console (useful for debugging) ──────────────────
if [ -d "$ROOT_MNT/etc/systemd/system" ]; then
    mkdir -p "$ROOT_MNT/etc/systemd/system/getty.target.wants"
    ln -sf /lib/systemd/system/serial-getty@.service \
        "$ROOT_MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" 2>/dev/null || true
fi

# ─── Cleanup ───────────────────────────────────────────────────────
msg "Syncing and unmounting ..."
sync
umount "$ROOT_MNT"  2>/dev/null || true
umount "$STAGE_MNT" 2>/dev/null || true
sync

# ─── Done ──────────────────────────────────────────────────────────
msg ""
msg "========================================"
msg "  Installation complete!"
msg "========================================"
msg ""
msg "Next: Change startup.nsh to boot from eMMC:"
msg "  root=/dev/mmcblk0p5 rootfstype=ext4"
msg ""
msg "Rebooting in 5 seconds ..."
sleep 5
reboot -f

#!/bin/bash
# build-initramfs.sh — Create RAM-based rescue initramfs for Surface 2
# Sourced by build.sh — do not run directly.
#
# The Surface 2 loses USB VBUS power after kernel boot, so we can't
# rely on USB being available at boot. This initramfs boots entirely
# into RAM as a rescue system, providing tools to probe USB, rebind
# controllers, and mount the USB rootfs when it appears.
#
# Boot: root=/dev/ram0 init=/init → initramfs IS the root filesystem.
#
# Contents (~2 MB):
#   /init                  — boot script (loads modules, sets up env)
#   /bin/busybox + symlinks — all shell commands
#   /lib/modules/...       — usb-storage.ko + dependencies
#   /usr/bin/try-usb       — helper script to probe USB and mount rootfs
#   /usr/bin/go-usb        — pivot to USB rootfs when ready

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
    info "=== Building RAM-based rescue initramfs ==="

    local INITRAMFS_DIR
    INITRAMFS_DIR=$(mktemp -d)

    # ── Directory structure (full rootfs) ──
    mkdir -p "$INITRAMFS_DIR"/{bin,sbin,usr/bin,usr/sbin,dev,proc,sys,tmp,run}
    mkdir -p "$INITRAMFS_DIR"/{mnt/usb,root,etc,lib/modules,var/log}

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

    # ── Create busybox symlinks for all applets ──
    # This gives us: sh, ls, cat, mount, insmod, dmesg, vi, wget, etc.
    info "Creating busybox applet symlinks..."
    local APPLETS
    # Get applet list from busybox itself (runs in Docker x86, but binary is ARM)
    # Hardcode the essential ones instead:
    for applet in \
        ash sh login getty \
        ls cat echo mkdir rm cp mv ln chmod chown \
        mount umount mdev mknod \
        insmod lsmod rmmod modprobe \
        dmesg sysctl \
        ps kill sleep date \
        df du free \
        ifconfig ip route ping \
        vi less more head tail grep sed awk cut sort uniq wc tr \
        find xargs \
        tar gzip gunzip \
        dd hexdump od \
        reboot poweroff halt \
        switch_root pivot_root chroot \
        depmod \
    ; do
        ln -sf /bin/busybox "$INITRAMFS_DIR/bin/$applet"
    done
    # sbin symlinks
    for applet in init mdev switch_root pivot_root reboot poweroff halt; do
        ln -sf /bin/busybox "$INITRAMFS_DIR/sbin/$applet"
    done
    info "Symlinks created"

    # ── Collect ALL kernel modules (not just USB) ──
    local KVER_DIR
    KVER_DIR=$(ls -d "$STAGING_DIR/lib/modules"/5.* 2>/dev/null | head -1)
    if [ -z "$KVER_DIR" ]; then
        KVER_DIR=$(ls -d "$STAGING_DIR/lib/modules"/*/ 2>/dev/null | head -1)
    fi

    if [ -n "$KVER_DIR" ] && [ -d "$KVER_DIR" ]; then
        local KVER
        KVER=$(basename "$KVER_DIR")
        info "Copying ALL kernel modules ($KVER)..."
        cp -a "$KVER_DIR" "$INITRAMFS_DIR/lib/modules/"
        local MOD_COUNT
        MOD_COUNT=$(find "$INITRAMFS_DIR/lib/modules/$KVER" -name '*.ko' -o -name '*.ko.*' 2>/dev/null | wc -l)
        info "Included $MOD_COUNT modules"
    else
        warn "No modules directory found"
    fi

    # ── Create /etc files ──
    # /etc/profile — nice shell prompt
    cat > "$INITRAMFS_DIR/etc/profile" << 'PROFILEEOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export PS1='surface2# '
alias ll='ls -la'
alias dmesg='dmesg | tail -40'

echo ""
echo "=== Surface 2 Rescue System ==="
echo "Commands:  try-usb     — probe USB and show devices"
echo "           go-usb      — mount USB rootfs and pivot into it"
echo "           usb-reset   — rebind USB host controller"
echo "           dmesg       — kernel messages (last 40)"
echo ""
PROFILEEOF

    # /etc/passwd, /etc/group — minimal for login
    echo "root:x:0:0:root:/root:/bin/sh" > "$INITRAMFS_DIR/etc/passwd"
    echo "root:x:0:" > "$INITRAMFS_DIR/etc/group"
    echo "root::0:0:99999:7:::" > "$INITRAMFS_DIR/etc/shadow"

    # /etc/fstab
    cat > "$INITRAMFS_DIR/etc/fstab" << 'FSTAB'
proc    /proc   proc    defaults    0 0
sysfs   /sys    sysfs   defaults    0 0
devtmpfs /dev   devtmpfs defaults   0 0
FSTAB

    # ── Create helper scripts ──

    # try-usb — probe USB devices, reload modules, show status
    cat > "$INITRAMFS_DIR/usr/bin/try-usb" << 'TRYUSBEOF'
#!/bin/sh
echo "=== USB Status ==="
echo ""

echo "--- Loaded modules ---"
cat /proc/modules 2>/dev/null | head -20
echo ""

echo "--- Loading USB storage modules ---"
KVER=$(uname -r)
for mod in scsi_mod sd_mod usb-storage; do
    for ext in .ko .ko.xz .ko.gz; do
        MOD="/lib/modules/$KVER/kernel/*/${mod}${ext}"
        FOUND=$(find /lib/modules/$KVER -name "${mod}${ext}" 2>/dev/null | head -1)
        if [ -n "$FOUND" ]; then
            insmod "$FOUND" 2>/dev/null && echo "  Loaded: $mod" || echo "  Already loaded or failed: $mod"
            break
        fi
    done
done
echo ""

# Trigger device discovery
mdev -s 2>/dev/null
sleep 2
mdev -s 2>/dev/null

echo "--- Block devices ---"
ls -l /dev/sd* /dev/mmcblk* 2>/dev/null || echo "  (none found)"
echo ""

echo "--- USB bus ---"
ls /sys/bus/usb/devices/ 2>/dev/null
echo ""

echo "--- USB host controllers ---"
for hc in /sys/bus/usb/devices/usb*; do
    [ -d "$hc" ] || continue
    echo "  $(basename $hc): $(cat $hc/manufacturer 2>/dev/null) $(cat $hc/product 2>/dev/null)"
    echo "    speed=$(cat $hc/speed 2>/dev/null)Mbps authorized=$(cat $hc/authorized 2>/dev/null)"
done
echo ""

echo "--- Recent USB dmesg ---"
dmesg | grep -i "usb\|ehci\|scsi\|sd " | tail -20
echo ""

if [ -b /dev/sda ]; then
    echo "*** USB storage detected! ***"
    ls -l /dev/sda*
    echo "Run 'go-usb' to mount and boot into USB rootfs"
else
    echo "No USB storage yet. Try:"
    echo "  1. Unplug & replug USB drive"
    echo "  2. Use a powered USB hub"
    echo "  3. Run 'usb-reset' to rebind host controller"
    echo "  4. Run 'try-usb' again"
fi
TRYUSBEOF
    chmod +x "$INITRAMFS_DIR/usr/bin/try-usb"

    # usb-reset — unbind/rebind USB host controller
    cat > "$INITRAMFS_DIR/usr/bin/usb-reset" << 'USBRESETEOF'
#!/bin/sh
echo "=== Resetting USB host controllers ==="

# Try to authorize all USB devices
for d in /sys/bus/usb/devices/usb*; do
    [ -d "$d" ] || continue
    echo "Authorizing $(basename $d)..."
    echo 1 > "$d/authorized" 2>/dev/null
done

# Unbind and rebind EHCI/XHCI controllers
for driver in ehci-tegra tegra-ehci ehci-platform; do
    DRIVER_DIR="/sys/bus/platform/drivers/$driver"
    [ -d "$DRIVER_DIR" ] || continue
    echo "Found driver: $driver"
    for dev in "$DRIVER_DIR"/*/driver; do
        DEV_NAME=$(basename $(dirname "$dev"))
        echo "  Rebinding $DEV_NAME..."
        echo "$DEV_NAME" > "$DRIVER_DIR/unbind" 2>/dev/null
        sleep 1
        echo "$DEV_NAME" > "$DRIVER_DIR/bind" 2>/dev/null
        sleep 1
    done
done

# Also try toggling USB port power via sysfs
for port in /sys/bus/usb/devices/*/power/control; do
    echo "on" > "$port" 2>/dev/null
done

sleep 2
mdev -s 2>/dev/null

echo ""
echo "Done. Checking for USB devices..."
try-usb
USBRESETEOF
    chmod +x "$INITRAMFS_DIR/usr/bin/usb-reset"

    # go-usb — mount USB rootfs and pivot into it
    cat > "$INITRAMFS_DIR/usr/bin/go-usb" << 'GOUSBEOF'
#!/bin/sh
USB_DEV="${1:-/dev/sda2}"

if [ ! -b "$USB_DEV" ]; then
    echo "ERROR: $USB_DEV not found"
    echo "Usage: go-usb [device]    (default: /dev/sda2)"
    echo ""
    echo "Available block devices:"
    ls -l /dev/sd* /dev/mmcblk* 2>/dev/null
    exit 1
fi

echo "Mounting $USB_DEV on /mnt/usb..."
mount -t ext4 -o rw "$USB_DEV" /mnt/usb || {
    echo "ERROR: Failed to mount $USB_DEV"
    exit 1
}

if [ ! -x /mnt/usb/sbin/init ] && [ ! -x /mnt/usb/lib/systemd/systemd ]; then
    echo "WARNING: No init found on $USB_DEV"
    echo "Contents of /mnt/usb:"
    ls /mnt/usb/
    echo ""
    echo "You can still chroot: chroot /mnt/usb /bin/bash"
    exit 1
fi

echo "Found rootfs on $USB_DEV — pivoting..."
echo ""

# Move virtual filesystems to new root
mkdir -p /mnt/usb/proc /mnt/usb/sys /mnt/usb/dev
mount --move /proc /mnt/usb/proc 2>/dev/null
mount --move /sys /mnt/usb/sys 2>/dev/null
mount --move /dev /mnt/usb/dev 2>/dev/null

# Pivot root
cd /mnt/usb
pivot_root . mnt 2>/dev/null || {
    echo "pivot_root failed, trying switch_root..."
    exec switch_root /mnt/usb /sbin/init
}

# Clean up old root
umount -l /mnt 2>/dev/null

# Start real init
exec chroot . /sbin/init
GOUSBEOF
    chmod +x "$INITRAMFS_DIR/usr/bin/go-usb"

    # ── Create /init ──
    cat > "$INITRAMFS_DIR/init" << 'INITEOF'
#!/bin/sh
# Surface 2 RAM-based rescue system
# Boots entirely into RAM. USB may or may not be available.

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount virtual filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || mdev -s
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

echo ""
echo "======================================"
echo "  Surface 2 Rescue System"
echo "======================================"
echo ""
echo "Kernel: $(uname -r)"
echo "cmdline: $(cat /proc/cmdline)"
echo ""

# Load ALL available modules (try USB-related first)
echo "Loading kernel modules..."
KVER=$(uname -r)

# Priority modules for USB storage
for mod in scsi_mod sd_mod usb-storage; do
    FOUND=$(find /lib/modules/$KVER -name "${mod}.ko" -o -name "${mod}.ko.*" 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        insmod "$FOUND" 2>/dev/null && echo "  [OK] $mod" || echo "  [--] $mod (built-in or dep missing)"
    fi
done

# Trigger device discovery
mdev -s 2>/dev/null

echo ""
echo "Waiting 10s for USB devices..."
TRIES=0
while [ ! -b /dev/sda ] && [ $TRIES -lt 10 ]; do
    sleep 1
    TRIES=$((TRIES + 1))
    mdev -s 2>/dev/null
    printf "  %d/10s\r" $TRIES
done
echo ""

# Show what we found
echo "--- Block devices ---"
ls -l /dev/sd* /dev/mmcblk* 2>/dev/null || echo "  (none)"
echo ""

if [ -b /dev/sda2 ]; then
    echo "*** USB rootfs found at /dev/sda2! ***"
    echo "Run 'go-usb' to pivot into it, or explore first."
elif [ -b /dev/sda ]; then
    echo "*** USB drive found but no partition 2 ***"
    echo "Partitions:"
    ls -l /dev/sda*
else
    echo "No USB storage detected."
    echo "  - Try 'usb-reset' to rebind USB controllers"
    echo "  - Try 'try-usb' for detailed diagnostics"
    echo "  - Try unplugging and replugging the USB drive"
    echo "  - A powered USB hub may be needed"
fi

echo ""
echo "--- Recent USB dmesg ---"
dmesg | grep -i "usb\|ehci\|scsi\|sd " | tail -15
echo ""
echo "Type 'help' for busybox commands, 'try-usb' to probe USB."
echo ""

# Set hostname
echo "surface2" > /proc/sys/kernel/hostname

# Start mdev daemon for hotplug
echo /sbin/mdev > /proc/sys/kernel/hotplug 2>/dev/null

# Source profile for nice prompt
export HOME=/root
export PS1='surface2# '
cd /root

# Drop to interactive shell
exec /bin/sh -l
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

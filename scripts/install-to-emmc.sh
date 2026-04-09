#!/bin/bash
# install-to-emmc.sh — Install Bookworm rootfs + boot files to eMMC
#
# Run ON the Surface 2 after booting from USB:
#   sudo /root/install-to-emmc.sh
#
# Copies rootfs to eMMC p5 and boot files to eMMC p1 (ESP).
# Windows RT partition (p2 NTFS) is NEVER touched.
# After install, run setup-dualboot.sh to configure boot selection.

set -euo pipefail

EMMC_ROOT="/dev/mmcblk0p5"
EMMC_ESP="/dev/mmcblk0p1"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || error "Must run as root"
[ -b "$EMMC_ROOT" ] || error "$EMMC_ROOT not found. Run resizepart-emmc first to create partition 5."

echo "=== Surface 2 eMMC Installer ==="
echo ""
echo "This will:"
echo "  1. Format $EMMC_ROOT (p5) as ext4"
echo "  2. Copy the running rootfs to it"
echo "  3. Copy boot files (kernel, DTB, cmdline) to $EMMC_ESP (p1)"
echo ""
echo "Windows RT (p2 NTFS) is NOT touched."
echo ""
read -r -p "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || error "Aborted"

# ─── Find USB boot partition ────────────────────────────────────────
USB_BOOT=""
for candidate in /dev/sda1 /dev/mmcblk1p1; do
    if [ -b "$candidate" ]; then
        TMP=$(mktemp -d)
        if mount -o ro "$candidate" "$TMP" 2>/dev/null; then
            if [ -f "$TMP/boot.efi" ]; then
                USB_BOOT="$TMP"
                info "Found USB boot partition: $candidate"
                break
            fi
            umount "$TMP"
        fi
        rmdir "$TMP" 2>/dev/null
    fi
done

[ -n "$USB_BOOT" ] || warn "USB boot partition not found — will need manual boot file setup"

# ─── Format and populate eMMC rootfs ────────────────────────────────
info "Formatting $EMMC_ROOT as ext4..."
mkfs.ext4 -L "S2ROOT" -q "$EMMC_ROOT"

EMMC_MNT=$(mktemp -d)
mount "$EMMC_ROOT" "$EMMC_MNT"

info "Copying rootfs to eMMC (this takes several minutes)..."
rsync -aAX --info=progress2 \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/tmp/*' --exclude='/run/*' --exclude='/mnt/*' \
    --exclude='/media/*' / "$EMMC_MNT/"

mkdir -p "$EMMC_MNT"/{proc,sys,dev,tmp,run,mnt,media,boot}

cat > "$EMMC_MNT/etc/fstab" << 'FSTAB'
/dev/mmcblk0p5  /     ext4  defaults,noatime  0 1
/dev/mmcblk0p1  /boot vfat  defaults          0 2
FSTAB

sync
umount "$EMMC_MNT"
rmdir "$EMMC_MNT"
info "Rootfs installed to $EMMC_ROOT"

# ─── Copy boot files to ESP ─────────────────────────────────────────
info "Copying boot files to eMMC ESP ($EMMC_ESP)..."
ESP_MNT=$(mktemp -d)
mount "$EMMC_ESP" "$ESP_MNT"

mkdir -p "$ESP_MNT/backup"

if [ -n "$USB_BOOT" ] && [ -f "$USB_BOOT/boot.efi" ]; then
    cp -v "$USB_BOOT/boot.efi" "$ESP_MNT/"
    cp -v "$USB_BOOT"/*.dtb "$ESP_MNT/" 2>/dev/null || true
    cp -v "$USB_BOOT/startup.nsh" "$ESP_MNT/" 2>/dev/null || true

    # Use eMMC cmdline (root=/dev/mmcblk0p5)
    if [ -f "$USB_BOOT/cmdline-emmc.txt" ]; then
        cp -v "$USB_BOOT/cmdline-emmc.txt" "$ESP_MNT/cmdline.txt"
    fi

    # Save backup of known-good boot files
    cp "$ESP_MNT/boot.efi" "$ESP_MNT/backup/"
    cp "$ESP_MNT"/*.dtb "$ESP_MNT/backup/" 2>/dev/null || true
    cp "$ESP_MNT/cmdline.txt" "$ESP_MNT/backup/" 2>/dev/null || true
    cp "$ESP_MNT/startup.nsh" "$ESP_MNT/backup/" 2>/dev/null || true
    info "Backup of boot files saved to ESP /backup/"

    umount "$USB_BOOT"
    rmdir "$USB_BOOT" 2>/dev/null
else
    warn "USB boot partition not found — copy boot files to $EMMC_ESP manually"
fi

sync
umount "$ESP_MNT"
rmdir "$ESP_MNT"

echo ""
info "=== Installation complete! ==="
echo ""
info "Boot files and rootfs are on the eMMC."
info "To set up dual-boot (Linux default, Vol Up for Windows):"
info "  sudo /root/setup-dualboot.sh"
echo ""
info "KEEP THE USB as recovery medium."

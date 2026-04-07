#!/bin/bash
# test-prepare-usb.sh — Test prepare-usb.sh with a loopback device
# Run inside Docker with --privileged
set -euo pipefail

info()  { echo -e "\033[1;34m[TEST]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

ERRORS=0

# ─── Setup ────────────────────────────────────────────────────────────
# Clean up any stale loop devices
losetup -D 2>/dev/null || true

info "Creating 512MB dummy USB image ..."
rm -f /tmp/fake-usb.img
truncate -s 512M /tmp/fake-usb.img

info "Setting up loopback device ..."
LOOP=$(losetup --show -fP /tmp/fake-usb.img)
info "Loop device: $LOOP"
info "Loop devices: $(losetup -l 2>/dev/null)"

# Create a small dummy rootfs (skip the big RPi OS download)
info "Creating 10MB dummy rootfs.img ..."
dd if=/dev/urandom of=/work/output/rootfs.img bs=1M count=10 status=none

# ─── Run prepare-usb.sh ──────────────────────────────────────────────
info "Running prepare-usb.sh with $LOOP ..."
echo YES | bash scripts/prepare-usb.sh "$LOOP" /work/output/rootfs.img && RC=0 || RC=$?
if [ $RC -eq 0 ]; then
    ok "prepare-usb.sh exited with code 0"
else
    echo "[FAIL] prepare-usb.sh exited with code $RC"
    ERRORS=$((ERRORS + 1))
fi

# The loop device may have been re-assigned by prepare-usb.sh
NEW_LOOP=$(losetup -nO NAME -j /tmp/fake-usb.img 2>/dev/null | head -1 | tr -d ' ')
if [ -n "$NEW_LOOP" ] && [ "$NEW_LOOP" != "$LOOP" ]; then
    info "Loop device re-assigned: $LOOP -> $NEW_LOOP"
    LOOP=$NEW_LOOP
fi
info "Loop devices after: $(losetup -l 2>/dev/null)"
info "Block devices: $(ls /dev/loop* 2>/dev/null | tr '\n' ' ')"

# ─── Verify results ──────────────────────────────────────────────────
info ""
info "=== Verifying USB contents ==="

# Find partition
PART=""
for suffix in "p1" "1"; do
    if [ -b "${LOOP}${suffix}" ]; then
        PART="${LOOP}${suffix}"
        break
    fi
done
if [ -z "$PART" ]; then
    echo "[FAIL] No partition found on $LOOP"
    info "Trying to mount $LOOP directly (whole-disk FAT32 fallback) ..."
    PART="$LOOP"
fi
ok "Partition: $PART"

# Check label
LABEL=$(blkid -s LABEL -o value "$PART" 2>/dev/null || true)
if [ "$LABEL" = "S2LINUX" ]; then
    ok "Label is S2LINUX"
else
    echo "[FAIL] Expected label S2LINUX, got: '$LABEL'"
    ERRORS=$((ERRORS + 1))
fi

# Mount and check files
MNT=$(mktemp -d)
mount "$PART" "$MNT"

check_file() {
    local f="$1"
    local desc="$2"
    if [ -f "$MNT/$f" ]; then
        local sz
        sz=$(du -h "$MNT/$f" | cut -f1)
        ok "$f present ($sz) — $desc"
    else
        echo "[FAIL] Missing: $f — $desc"
        ERRORS=$((ERRORS + 1))
    fi
}

check_dir() {
    local d="$1"
    local desc="$2"
    if [ -d "$MNT/$d" ]; then
        local count
        count=$(find "$MNT/$d" -type f | wc -l)
        ok "$d/ present ($count files) — $desc"
    else
        echo "[FAIL] Missing directory: $d — $desc"
        ERRORS=$((ERRORS + 1))
    fi
}

check_file "boot.efi"          "kernel EFI binary"
check_file "initrd.gz"         "initramfs"
check_file "startup.nsh"       "EFI boot script"
check_file "startup-emmc.nsh"  "eMMC boot script"
check_file "rootfs.img"        "root filesystem"
check_file "EFI/BOOT/BOOTARM.EFI" "EFI fallback"

# Check DTBs
DTB_COUNT=$(find "$MNT" -maxdepth 1 -name '*.dtb' | wc -l)
if [ "$DTB_COUNT" -gt 0 ]; then
    ok "*.dtb present ($DTB_COUNT files)"
else
    echo "[FAIL] No DTB files found"
    ERRORS=$((ERRORS + 1))
fi

check_dir "lib/modules"       "kernel modules"
check_dir "lib/firmware/mrvl" "Wi-Fi firmware"

info ""
info "=== Full listing ==="
du -sh "$MNT"/* 2>/dev/null | sed 's|'"$MNT"'/||' | sed 's/^/  /'
info ""
ls -la "$MNT/" | tail -n +2 | sed 's/^/  /'

umount "$MNT"
rmdir "$MNT"

# ─── Cleanup ─────────────────────────────────────────────────────────
losetup -d "$LOOP"
rm -f /tmp/fake-usb.img

info ""
if [ $ERRORS -eq 0 ]; then
    ok "All checks passed!"
else
    fail "$ERRORS check(s) failed"
fi

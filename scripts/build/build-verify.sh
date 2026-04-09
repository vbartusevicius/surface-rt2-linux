#!/bin/bash
# build-verify.sh — Verify build output integrity
# Sourced by build.sh — do not run directly.

verify_output() {
    info "Verifying build output ..."
    local FAIL=0

    # ── boot.efi (ARM zImage) ──
    if [ ! -f "$BOOT_DIR/boot.efi" ]; then
        warn "MISSING: boot.efi"
        FAIL=1
    elif [ "$(stat -c%s "$BOOT_DIR/boot.efi")" -lt 1000000 ]; then
        warn "SUSPECT: boot.efi is smaller than 1 MB ($(du -h "$BOOT_DIR/boot.efi" | cut -f1))"
        FAIL=1
    else
        local BOOT_TYPE
        BOOT_TYPE=$(file "$BOOT_DIR/boot.efi")
        if echo "$BOOT_TYPE" | grep -qi arm; then
            info "OK  boot.efi — ARM kernel ($(du -h "$BOOT_DIR/boot.efi" | cut -f1))"
        else
            warn "SUSPECT: boot.efi does not look like an ARM binary: $BOOT_TYPE"
            FAIL=1
        fi
    fi

    # ── DTB files ──
    local DTB_COUNT=0
    for dtb in "$BOOT_DIR"/*.dtb; do
        [ -f "$dtb" ] || continue
        DTB_COUNT=$((DTB_COUNT + 1))
        # DTB magic: 0xd00dfeed (big-endian)
        local MAGIC
        MAGIC=$(od -A n -N 4 -t x1 "$dtb" | tr -d ' ')
        if [ "$MAGIC" = "d00dfeed" ]; then
            info "OK  $(basename "$dtb") — valid DTB ($(du -h "$dtb" | cut -f1))"
        else
            warn "SUSPECT: $(basename "$dtb") has wrong magic: $MAGIC (expected d00dfeed)"
            FAIL=1
        fi
    done
    if [ "$DTB_COUNT" -eq 0 ]; then
        warn "NO DTB files found in $BOOT_DIR"
        FAIL=1
    fi

    # ── Kernel modules ──
    local MOD_DIR="$STAGING_DIR/lib/modules"
    if [ -d "$MOD_DIR" ]; then
        local MOD_COUNT
        MOD_COUNT=$(find "$MOD_DIR" -name '*.ko' | wc -l)
        if [ "$MOD_COUNT" -gt 0 ]; then
            # Spot-check one module for ARM architecture
            local SAMPLE_KO
            SAMPLE_KO=$(find "$MOD_DIR" -name '*.ko' | head -1)
            local KO_TYPE
            KO_TYPE=$(file "$SAMPLE_KO")
            if echo "$KO_TYPE" | grep -qi arm; then
                info "OK  modules — $MOD_COUNT .ko files, ARM ($(du -sh "$MOD_DIR" | cut -f1))"
            else
                warn "WRONG ARCH: modules are NOT ARM: $KO_TYPE"
                FAIL=1
            fi
        else
            warn "NO kernel modules found in $MOD_DIR"
            FAIL=1
        fi
    else
        warn "MISSING: $MOD_DIR directory"
        FAIL=1
    fi

    # ── Firmware ──
    local FW_FILE="$STAGING_DIR/lib/firmware/mrvl/sd8797_uapsta.bin"
    if [ -f "$FW_FILE" ] && [ "$(stat -c%s "$FW_FILE")" -gt 1000 ]; then
        info "OK  firmware — sd8797_uapsta.bin present ($(du -h "$FW_FILE" | cut -f1))"
    else
        warn "MISSING or empty: $FW_FILE (Wi-Fi will not work)"
    fi

    # ── startup.nsh ──
    if [ -f "$BOOT_DIR/startup.nsh" ]; then
        if grep -q 'boot.efi' "$BOOT_DIR/startup.nsh"; then
            info "OK  startup.nsh — looks valid"
        else
            warn "SUSPECT: startup.nsh does not reference boot.efi"
            FAIL=1
        fi
    else
        warn "MISSING: startup.nsh"
        FAIL=1
    fi

    # ── cmdline.txt ──
    if [ -f "$BOOT_DIR/cmdline.txt" ]; then
        if grep -q 'dtb=' "$BOOT_DIR/cmdline.txt" && grep -q 'root=' "$BOOT_DIR/cmdline.txt"; then
            info "OK  cmdline.txt — has dtb= and root="
        else
            warn "SUSPECT: cmdline.txt missing dtb= or root="
            FAIL=1
        fi
    else
        warn "MISSING: cmdline.txt"
        FAIL=1
    fi

    # ── Summary ──
    info ""
    if [ "$FAIL" -eq 0 ]; then
        info "=== ALL CHECKS PASSED ==="
    else
        warn "=== SOME CHECKS FAILED — review warnings above ==="
    fi
    return $FAIL
}

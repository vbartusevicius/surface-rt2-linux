# Surface 2 — Linux on Tegra 4

Run Linux on the **Microsoft Surface 2** tablet (NVIDIA Tegra 4 T114, ARM32).

Based on [Andrew Lee's guide](https://www.andrewjameslee.com/2025/03/running-linux-on-microsoft-surface-2-rt.html) and the [Open Surface RT](https://open-rt.gitbook.io/open-surfacert) community. Uses the [grate-linux](https://github.com/Open-Surface-RT/grate-linux/tree/microsoft-surface-2) kernel with EFI stub boot.

> **Hardware details** — ACPI/DSDT analysis, GPIO pins, power rails — see [`docs/hardware-analysis.md`](docs/hardware-analysis.md).

## Quick Start

```bash
git clone https://github.com/YOUR_USER/surface-rt2-linux.git
cd surface-rt2-linux

# Build Docker image (one-time)
docker build -t surface2-build .

# Create image (~10 min: downloads kernel + Raspberry Pi OS)
docker run --rm --privileged -v "$PWD/output:/work/output" surface2-build prebuilt

# Flash to USB stick (boot)
sudo dd if=output/surface2-boot-usb.img of=/dev/sdX bs=4M status=progress

# Flash to micro-SD card (rootfs)
sudo dd if=output/surface2-rootfs-sdcard.img of=/dev/sdY bs=4M status=progress

# Insert both into Surface 2 → Power on with Volume Down → wait ~7 min → Linux!
```

## Prerequisites

- **Jailbroken Surface 2** — Secure Boot disabled (GoldenKeys + Yahallo)
- **Host PC** — Windows, macOS, or Linux with [Docker](https://www.docker.com/)
- **USB stick** ≥ 256 MB — boot files only (kernel, DTB, cmdline)
- **micro-SD card** ≥ 4 GB — root filesystem (Raspberry Pi OS)

> **Why two devices?** Surface 2 cuts USB power after the kernel loads ([Ubuntu Wiki](https://wiki.ubuntu.com/ARM/SurfaceRT#Surface_2)). The USB stick boots the kernel, then the SD card takes over as root. The SD card uses built-in MMC/SDHCI drivers — no initramfs needed.

## Step 1 — Partition the eMMC

Download [`resizepart-emmc.zip`](https://files.open-rt.party/Linux/Other/surface-2-linux-resizepart-emmc.zip), copy to USB, boot from it — shrinks Windows and creates Linux partitions.

Target eMMC layout:

| # | Size | Format | Purpose |
|---|------|--------|---------|
| p1 | ~350 MB | FAT32 | EFI System Partition (keep) |
| p2 | ~16 GB | NTFS | Windows RT (shrunk) |
| p5 | ~6 GB | ext4 | Linux root `/` |

## Step 2 — Build the image

```bash
docker run --rm --privileged -v "$PWD/output:/work/output" surface2-build prebuilt
```

This downloads the [proven pre-built kernel](https://files.open-rt.party/Linux/Other/surface-2-bootfiles%2Bkernel.zip) (5.17.0-rc4) + Raspberry Pi OS Bookworm Lite, and creates **two images**:

| Image | Size | Contents | Flash to |
|-------|------|----------|----------|
| `surface2-boot-usb.img` | ~130 MB | boot.efi, DTB, cmdline.txt | **USB stick** |
| `surface2-rootfs-sdcard.img` | ~4 GB | Raspberry Pi OS + modules + firmware | **micro-SD card** |

### Build commands

| Command | What it does | Time |
|---------|-------------|------|
| `prebuilt` | Download pre-built kernel + create USB image | ~10 min |
| `image` | Recreate USB image from existing `output/` | ~5 min |
| `dtb` | Compile custom DTS only | seconds |
| `kernel` | Recompile kernel from source | ~20 min |
| `full` | Full build from source + USB image | ~30 min |

All via Docker: `docker run --rm --privileged -v "$PWD/output:/work/output" surface2-build <command>`

(`dtb` and `kernel` don't need `--privileged`)

## Step 3 — Flash USB stick and SD card

Both images are flashed the same way — `dd` (Linux/macOS) or [balenaEtcher](https://etcher.balena.io/) / [Rufus](https://rufus.ie/) (Windows).

```bash
# USB stick (boot)
sudo dd if=output/surface2-boot-usb.img of=/dev/sdX bs=4M status=progress

# micro-SD card (rootfs)
sudo dd if=output/surface2-rootfs-sdcard.img of=/dev/sdY bs=4M status=progress
```

### Boot

1. Insert **USB stick** into the Surface 2 USB port
2. Insert **micro-SD card** into the Surface 2 SD card slot
3. Power on holding **Volume Down** → boots from USB
4. Wait ~7 minutes (Surface 2 UEFI bug — one-time delay each boot)
5. Kernel loads from USB, mounts rootfs from SD card
6. Raspberry Pi OS boots — login: `pi` / `raspberry`

```
Boot flow:
  UEFI → USB:/EFI/BOOT/BOOTARM.EFI (kernel)
       → USB:/cmdline.txt (root=/dev/mmcblk1p1)
       → SD card /dev/mmcblk1p1 (ext4 rootfs)
```

## Step 4 — Install to eMMC

From the running USB system:

```bash
sudo /root/install-to-emmc.sh
```

This formats eMMC p5, copies rootfs and boot files. Windows RT (p2) is **not touched**.

### Step 4b — Set up dual-boot (optional)

Two-step setup that gives you an interactive boot menu using the Surface hardware buttons:

**Step 1 — From Linux:**
```bash
sudo /root/setup-dualboot.sh
```
Places the EFI Shell on the ESP and generates `setup-dualboot.cmd`.

**Step 2 — From Windows RT (Admin command prompt):**
```cmd
mountvol S: /s
S:\setup-dualboot.cmd
```
Adds "Linux (Bookworm)" to the Windows Boot Manager BCD menu.

**After setup — boot menu appears for 10 seconds:**

| Button | Action |
|--------|--------|
| **Vol +/-** | Navigate between Linux / Windows |
| **Windows button** | Select highlighted OS |
| *(timeout)* | Boots default OS |

**Keep the USB** — it's your recovery medium (hold Volume Down to boot from USB).

## DTS / Kernel Development

After installing to eMMC, you have a safe setup for testing custom DTS and kernels.

### Test a custom DTB

```bash
# On your PC — compile the DTS
docker run --rm -v "$PWD/output:/work/output" surface2-build dtb

# On the Surface 2 — swap the DTB
mount /dev/mmcblk0p1 /mnt
mkdir -p /mnt/backup
cp /mnt/*.dtb /mnt/backup/              # backup first!
cp /path/to/output/boot/*.dtb /mnt/
umount /mnt
reboot
```

### Test a custom kernel

```bash
# On your PC — build kernel
docker run --rm -v "$PWD/output:/work/output" surface2-build kernel

# On the Surface 2 — swap boot.efi + DTB + modules
mount /dev/mmcblk0p1 /mnt
cp /mnt/boot.efi /mnt/backup/           # backup first!
cp /path/to/output/boot/boot.efi /mnt/
cp /path/to/output/boot/*.dtb /mnt/
umount /mnt
# Also update kernel modules:
cp -a /path/to/output/staging/lib/modules/* /lib/modules/
reboot
```

### Recovery (if display goes black)

1. Insert the USB drive
2. Boot from USB (Volume Up → USB)
3. Restore the backup:
   ```bash
   mount /dev/mmcblk0p1 /mnt
   cp /mnt/backup/* /mnt/
   umount /mnt
   reboot    # remove USB first
   ```

## Step 5 — Verify

```bash
dmesg | grep -Ei 'mwifiex|sdhci|mxt|wm8962|tps6591|tegra|drm'
ip a                              # wlan0 should appear
aplay -l                          # WM8962 audio card
cat /sys/class/power_supply/*/uevent
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Generating empty DTB" | Kernel ignores `dtb=` due to Secure Boot check. Pre-built kernel has this fixed. For custom: `CONFIG_WINDOWS_RT=y` + `CONFIG_WINDOWS_RT_SECUREBOOT_SKIP=y` |
| Black screen | Disable `CONFIG_DRM_TEGRA`, use `CONFIG_FB_SIMPLE=y` + `CONFIG_SYSFB_SIMPLEFB=y`. Happens randomly on ~1/3 of boots — power cycle and try again. |
| "waiting for root device" | Check `cmdline.txt` root= device. SD card → `/dev/mmcblk1p1`, eMMC → `/dev/mmcblk0p5`. Ensure SD card is inserted and formatted as ext4. |
| No Wi-Fi | Check `/lib/firmware/mrvl/sd8797_uapsta.bin` exists |
| No touch | Verify I2C1 HID node in DTS; try `atmel_mxt_ts` driver |
| Kernel panic on eMMC | Verify `cmdline.txt` has `root=/dev/mmcblk0p5`, verify ext4 on p5 |
| SD card not detected | Ensure kernel is 5.17+ (early kernels used the SD slot as serial port). Check `dmesg \| grep mmc` |
| 7-minute boot delay | Normal — Surface 2 UEFI `BootServices->LoadImage` bug for non-edk2 binaries. Cannot be bypassed. |

## Technical Notes

**Why `cmdline.txt`?** The Yahallo EFI Shell does not pass command-line arguments to the kernel via `loaded_image->load_options`. The grate-linux `CONFIG_CMDLINE_FROM_FILE=y` reads `cmdline.txt` from the FAT partition and injects the parameters.

**Why no `initrd=`?** The SD card approach uses built-in MMC/SDHCI drivers, so no initramfs is needed. Previous attempts with `initrd=` for USB boot failed — the initramfs never loaded (kernel panicked on `root=/dev/ram0` with `unknown-block(0,0)`), likely because the EFI stub doesn't process `initrd=` from `CONFIG_CMDLINE_FROM_FILE`.

**Kernel config fragment:** `configs/surface2_defconfig_fragment` — applied on top of `tegra_defconfig`.

**Pre-built files:** [`surface-2-bootfiles+kernel.zip`](https://files.open-rt.party/Linux/Other/surface-2-bootfiles%2Bkernel.zip) on [files.open-rt.party](https://files.open-rt.party/).

## Resources

- [Andrew Lee's guide](https://www.andrewjameslee.com/2025/03/running-linux-on-microsoft-surface-2-rt.html) — step-by-step Surface 2 Linux install
- [Open Surface RT GitBook](https://open-rt.gitbook.io/open-surfacert) — community wiki
- [grate-linux `microsoft-surface-2` branch](https://github.com/Open-Surface-RT/grate-linux/tree/microsoft-surface-2) — kernel
- [grate-driver](https://github.com/grate-driver) — Tegra 2/3/4 open-source GPU
- [Open-RT Discord](https://discord.gg/VW75GmWa95)

## License

MIT

# Surface 2 - Linux on Tegra 4

Run Linux on the **Microsoft Surface 2** tablet (NVIDIA Tegra 4 T114, ARM32).

This repository follows the guide written by [Andrew Lee](https://www.andrewjameslee.com/2025/03/running-linux-on-microsoft-surface-2-rt.html), with additional hardware analysis from ACPI dumps and the [Open Surface RT](https://open-rt.gitbook.io/open-surfacert) community. It uses the [Open-Surface-RT/grate-linux](https://github.com/Open-Surface-RT/grate-linux/tree/microsoft-surface-2) kernel, EFI stub boot, and an initramfs-based installer.

> **Technical details** — hardware map, ACPI/DSDT/SSDT analysis, GPIO pins, power rails, known issues — are in [`docs/hardware-analysis.md`](docs/hardware-analysis.md).
>
> **ACPI dump files** referenced in the analysis are published at the [Open-RT GitBook ACPI tables page](https://open-rt.gitbook.io/open-surfacert/surface-rt2/hardware/acpi-dsdt-tables).

## Prerequisites

- **Jailbroken Surface 2** — Secure Boot disabled (GoldenKeys + Yahallo)
- **Host PC** — Windows (WSL), macOS, or Linux x86_64, with [Docker](https://www.docker.com/) installed
- **USB drive** ≥ 8 GB (FAT32)

## Step 1 — Partition the eMMC (on Windows RT)

The eMMC needs free partitions for Linux. You can either:

- **Use the pre-built repartitioning tool** from the Open Surface RT community:
  Download [`surface-2-linux-resizepart-emmc.zip`](https://files.open-rt.party/Linux/Other/surface-2-linux-resizepart-emmc.zip),
  copy its contents to a USB drive, and boot from it — it will shrink Windows and create the Linux partitions.

- **Manual method** — Open Disk Management on the Surface 2 (`Win+X` → Disk Management):
  shrink the Windows partition (~16 GB), delete the recovery partition, and create new partitions.

Target eMMC layout:

| # | Size | Format | Purpose |
|---|------|--------|---------|
| p1 | ~350 MB | FAT32 | EFI System Partition (keep) |
| p2 | ~16 GB | NTFS | Windows RT (shrink) |
| p5 | ~6 GB | ext4 | Linux root `/` |
| p6 | ~5 GB | FAT32 | Staging (optional — only if not using USB) |

> See [Andrew Lee's guide](https://www.andrewjameslee.com/2025/03/running-linux-on-microsoft-surface-2-rt.html) for detailed step-by-step instructions with screenshots.

## Step 2 — Build (on your PC)

```bash
git clone https://github.com/YOUR_USER/surface-rt2-linux.git
cd surface-rt2-linux

# Build cross-compilation container (one-time)
docker build -t surface2-build .
mkdir -p output
```

### Option A: Pre-built kernel (recommended first time)

Downloads the proven kernel + DTB + modules from [open-rt.party](https://files.open-rt.party/),
builds only the initramfs installer locally. **~2 min, no kernel compilation.**

```bash
docker run --rm -v "$PWD/output:/work/output" surface2-build prebuilt
```

### Option B: Full custom build

Compiles the kernel from source with your own defconfig fragment and custom DTS.

```bash
docker run --rm -v "$PWD/output:/work/output" surface2-build
```

### All build commands

| Command | What it does | Time |
|---------|-------------|------|
| `./build.sh` | Full build (clone + compile + package) | ~30 min |
| `./build.sh prebuilt` | Download pre-built kernel + build initramfs | ~2 min |
| `./build.sh dtb` | Rebuild DTB only | seconds |
| `./build.sh boot` | Rebuild DTB + reassemble boot files | seconds |
| `./build.sh quick` | Everything except kernel compile | ~2 min |
| `./build.sh kernel` | Recompile kernel + install modules | ~20 min |

Via Docker: `docker run --rm -v "$PWD/output:/work/output" surface2-build dtb`

**Typical DTS iteration loop:**
1. Edit `dts/tegra114-surface2.dts`
2. `./build.sh dtb` (or via Docker)
3. Copy `output/boot/tegra114-surface2.dtb` to USB
4. Reboot Surface 2

> See [`docs/dts-testing-guide.md`](docs/dts-testing-guide.md) for DTB testing, hardware probing, and debugging tips.

The Dockerfile copies the project files into the image and runs `scripts/build.sh` automatically.
All kernel config options live in a single file: `configs/surface2_defconfig_fragment`.

This produces:
- `output/boot/` — `boot.efi`, `*.dtb`, `initrd.gz`, `startup.nsh`
- `output/staging/` — kernel modules + Marvell Wi-Fi firmware

## Step 3 — Prepare USB

The `prepare-usb.sh` script supports two modes:

| Mode | Command | Use case |
|------|---------|----------|
| **Block device** (Linux) | `sudo ./scripts/prepare-usb.sh /dev/sdX` | Direct USB write on Linux |
| **Image file** (macOS-friendly) | `./scripts/prepare-usb.sh ./output/surface2-installer.img` | Create `.img` to flash later |

### Linux — Direct USB write

```bash
sudo ./scripts/prepare-usb.sh /dev/sdX
```

### macOS / Windows — Create image, then flash

Use Docker to build the image (no native tools needed):

```bash
docker run --rm -it --privileged -v "$PWD/output:/work/output" surface2-build bash /work/scripts/prepare-usb.sh /work/output/surface2-installer.img

# Then flash from macOS using dd:
diskutil list
diskutil unmountDisk /dev/diskX
sudo dd if=output/surface2-installer.img of=/dev/rdiskX bs=4m status=progress
diskutil eject /dev/diskX
```

Or on Windows, use [Rufus](https://rufus.ie/) or [balenaEtcher](https://www.balena.io/etcher/) to flash the `.img` file.

### What the script does

1. Downloads [Raspberry Pi OS Lite (Bookworm armhf)](https://www.raspberrypi.com/software/operating-systems/) if needed
2. Extracts the root partition into `rootfs.img`
3. Formats the target (USB or image) as FAT32 (labeled `S2LINUX`)
4. Copies boot files, kernel modules, firmware, and rootfs.img

The download is cached in `output/` — subsequent runs skip it.
To use your own rootfs image instead, pass it as the second argument:

```bash
# Linux direct write with custom rootfs:
sudo ./scripts/prepare-usb.sh /dev/sdX path/to/rootfs.img

# Image mode with custom rootfs:
./scripts/prepare-usb.sh ./output/surface2-installer.img path/to/rootfs.img
```

**USB drive layout after preparation:**

```
S2LINUX (FAT32):
├── boot.efi              ← kernel (zImage as EFI binary)
├── initrd.gz             ← initramfs containing the installer
├── cmdline.txt           ← kernel command line (REQUIRED — see note below)
├── startup.nsh           ← EFI Shell script: boots installer
├── startup-emmc.nsh      ← EFI Shell script: boots from eMMC (use after install)
├── cmdline-emmc.txt      ← kernel command line for eMMC boot
├── *.dtb                 ← device tree blobs for Tegra 114
├── rootfs.img            ← root filesystem (Raspberry Pi OS)
├── EFI/BOOT/BOOTARM.EFI  ← EFI fallback boot path (copy of boot.efi)
└── lib/
    ├── modules/          ← kernel modules
    └── firmware/mrvl/    ← Marvell Wi-Fi firmware
```

> **Why `cmdline.txt`?** The Yahallo-jailbroken EFI Shell does not pass command-line
> arguments to the loaded kernel via `loaded_image->load_options`. Without `cmdline.txt`,
> the EFI stub never sees `dtb=`, `initrd=`, or `root=` and you get "Generating empty DTB".
> The grate-linux `CONFIG_CMDLINE_FROM_FILE=y` feature reads this file and injects the
> parameters. **After install**, replace `cmdline.txt` with `cmdline-emmc.txt` (rename it).

## Step 4 — Boot & install

1. Plug USB into Surface 2
2. Power on holding **Volume Up** → UEFI boot menu → select USB
3. The EFI Shell runs `startup.nsh` from the USB root, which loads `boot.efi` + `initrd.gz`
4. The initramfs installer (`init.sh`) runs automatically:
   - Detects the USB by its `S2LINUX` label (or falls back to eMMC partition 6)
   - Writes `rootfs.img` → partition 5 (ext4)
   - Copies kernel modules + firmware into the new root
   - Writes `/etc/fstab` and reboots

## Step 5 — Switch to eMMC boot

After the installer finishes, the USB still has `startup.nsh` and `cmdline.txt` in
installer mode. To boot the installed system from eMMC, **swap both files**:

1. Mount the USB on any PC
2. Replace the startup script **and** command line:
   ```bash
   # On Linux:
   cp /mnt/usb/startup-emmc.nsh /mnt/usb/startup.nsh
   cp /mnt/usb/cmdline-emmc.txt /mnt/usb/cmdline.txt
   ```
   On Windows/macOS: rename `startup-emmc.nsh` → `startup.nsh` and
   `cmdline-emmc.txt` → `cmdline.txt` (overwrite the old ones).

The files differ in boot target:

| File pair | Boots | Root device |
|-----------|-------|-------------|
| `startup.nsh` + `cmdline.txt` (default) | Installer initramfs | `root=/dev/ram0 init=/init` |
| `startup-emmc.nsh` + `cmdline-emmc.txt` | eMMC partition 5 | `root=/dev/mmcblk0p5 rootfstype=ext4 rootwait` |

> **Important:** You must swap **both** `startup.nsh` and `cmdline.txt`. The kernel reads
> parameters from `cmdline.txt` (not from startup.nsh arguments), so leaving the old
> `cmdline.txt` will boot back into the installer.

**To boot permanently without USB**, copy the boot files to the EFI System Partition (p1):

```bash
# On the Surface 2 running Linux, or from Windows RT:
mount /dev/mmcblk0p1 /mnt/efi
cp /mnt/usb/boot.efi /mnt/efi/
cp /mnt/usb/*.dtb /mnt/efi/
cp /mnt/usb/startup-emmc.nsh /mnt/efi/startup.nsh
cp /mnt/usb/cmdline-emmc.txt /mnt/efi/cmdline.txt
umount /mnt/efi
```

## Step 6 — Verify

```bash
dmesg | grep -Ei 'mwifiex|sdhci|mxt|wm8962|tps6591|tegra|drm'
ip a                              # wlan0 should appear
aplay -l                          # WM8962 audio card
cat /sys/class/power_supply/*/uevent
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Generating empty DTB" then hang | Kernel ignores `dtb=` due to Secure Boot check. Ensure `CONFIG_WINDOWS_RT=y` and `CONFIG_WINDOWS_RT_SECUREBOOT_SKIP=y` in defconfig and rebuild kernel |
| Black screen after boot text | `CONFIG_DRM_TEGRA` takes over the EFI framebuffer and fails to reinitialize DSI. Disable it and use `CONFIG_FB_SIMPLE=y` + `CONFIG_SYSFB_SIMPLEFB=y` (already set in defconfig fragment). Rebuild kernel. |
| No Wi-Fi | Check `/lib/firmware/mrvl/sd8797_uapsta.bin` exists |
| No touch | Verify I2C1 HID node in DTS; try `atmel_mxt_ts` driver |
| USB flaky | Known ACPI issue — USB2/USB3 use HSIC, see hardware analysis |
| Kernel panic | Check `root=` partition number, verify ext4 on p5 |
| "waiting for root device /dev/ram0" | `initrd.gz` is missing from the USB. The installer cmdline uses `root=/dev/ram0` which requires an initramfs. Run `./build.sh prebuilt` and `prepare-usb.sh` to create a complete USB. |
| Re-runs installer on reboot | Replace **both** `startup.nsh` and `cmdline.txt` with their `-emmc` versions (see Step 5) |

## Alternative: Pre-built boot files

If you don't want to build the kernel yourself, pre-built files are available:

- [`surface-2-bootfiles+kernel.zip`](https://files.open-rt.party/Linux/Other/surface-2-bootfiles%2Bkernel.zip) — kernel + DTB + boot scripts
- [`surface-2-rpi-bookworm-bootfiles.zip`](https://files.open-rt.party/Linux/Distro/surface-2-rpi-bookworm-bootfiles.zip) — Bookworm boot files
- [`surface-2-linux-resizepart-emmc.zip`](https://files.open-rt.party/Linux/Other/surface-2-linux-resizepart-emmc.zip) — eMMC repartitioning tool
- [Pre-built kernel images](https://files.open-rt.party/Linux-Kernel-Download/surface-2/) — zImage + modules + DTB

All hosted at [files.open-rt.party](https://files.open-rt.party/).

## Resources

- [Andrew Lee's guide](https://www.andrewjameslee.com/2025/03/running-linux-on-microsoft-surface-2-rt.html) — step-by-step Surface 2 Linux install
- [Open Surface RT GitBook](https://open-rt.gitbook.io/open-surfacert) — community wiki
- [grate-linux `microsoft-surface-2` branch](https://github.com/Open-Surface-RT/grate-linux/tree/microsoft-surface-2) — kernel
- [grate-driver](https://github.com/grate-driver) — Tegra 2/3/4 open-source GPU
- [Open-RT Discord](https://discord.gg/VW75GmWa95)

## License

MIT

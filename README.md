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

Open Disk Management on the Surface 2 (`Win+X` → Disk Management):

| # | Size | Format | Purpose |
|---|------|--------|---------|
| p1 | ~350 MB | FAT32 | EFI System Partition (keep) |
| p2 | ~16 GB | NTFS | Windows RT (shrink) |
| p5 | ~6 GB | ext4 | Linux root `/` |
| p6 | ~5 GB | FAT32 | Staging (optional — only if not using USB) |

Delete the recovery partition (p3) to free space.

## Step 2 — Build (on your PC)

```bash
git clone https://github.com/YOUR_USER/surface-rt2-linux.git
cd surface-rt2-linux

# Build cross-compilation container (one-time)
docker build -t surface2-build .

# Full build: kernel + DTB + initramfs (~30 min, first time)
mkdir -p output
docker run --rm -v "$PWD/output:/work/output" surface2-build
```

### Incremental builds

After the first full build, use these to iterate faster:

| Command | What it does | Time |
|---------|-------------|------|
| `./build.sh` | Full build (clone + compile + package) | ~30 min |
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

After the installer finishes, the USB still has `startup.nsh` in installer mode.
To boot the installed system from eMMC, **edit `startup.nsh` on the USB**:

1. Mount the USB on any PC
2. Replace `startup.nsh` with the post-install version:
   ```bash
   # On Linux:
   cp /mnt/usb/startup-emmc.nsh /mnt/usb/startup.nsh
   ```
   Or on Windows/macOS, rename `startup-emmc.nsh` → `startup.nsh` (overwrite the old one).

The two startup scripts differ in boot target:

| File | Boots | Kernel cmdline |
|------|-------|---------------|
| `startup.nsh` (default) | Installer initramfs | `root=/dev/ram0 init=/init` |
| `startup-emmc.nsh` | eMMC partition 5 | `root=/dev/mmcblk0p5 rootfstype=ext4 rootwait` |

**To boot permanently without USB**, copy the boot files to the EFI System Partition (p1):

```bash
# On the Surface 2 running Linux, or from Windows RT:
mount /dev/mmcblk0p1 /mnt/efi
cp /mnt/usb/boot.efi /mnt/efi/
cp /mnt/usb/*.dtb /mnt/efi/
cp /mnt/usb/startup-emmc.nsh /mnt/efi/startup.nsh
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
| Black screen | Add `earlyprintk loglevel=7` to cmdline, check `dtb=` path matches filename on FAT partition |
| No Wi-Fi | Check `/lib/firmware/mrvl/sd8797_uapsta.bin` exists |
| No touch | Verify I2C1 HID node in DTS; try `atmel_mxt_ts` driver |
| USB flaky | Known ACPI issue — USB2/USB3 use HSIC, see hardware analysis |
| Kernel panic | Check `root=` partition number, verify ext4 on p5 |
| Re-runs installer on reboot | Replace `startup.nsh` with `startup-emmc.nsh` on USB (see Step 5) |

## Resources

- [Open Surface RT GitBook](https://open-rt.gitbook.io/open-surfacert) — community wiki
- [grate-linux `microsoft-surface-2` branch](https://github.com/Open-Surface-RT/grate-linux/tree/microsoft-surface-2) — kernel
- [grate-driver](https://github.com/grate-driver) — Tegra 2/3/4 open-source GPU
- [Open-RT Discord](https://discord.gg/VW75GmWa95)

## License

MIT

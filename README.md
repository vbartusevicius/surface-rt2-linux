# Surface 2 — Linux on Tegra 4

Run Linux on the **Microsoft Surface 2** tablet (NVIDIA Tegra 4 T114, ARM32).

This repository follows the guide written by [Andrew Lee](https://www.andrewjameslee.com/2025/03/running-linux-on-microsoft-surface-2-rt.html), with additional hardware analysis from ACPI dumps and the [Open Surface RT](https://open-rt.gitbook.io/open-surfacert) community. It uses the [Open-Surface-RT/grate-linux](https://github.com/Open-Surface-RT/grate-linux/tree/microsoft-surface-2) kernel, EFI stub boot, and an initramfs-based installer.

> **Technical details** — hardware map, ACPI/DSDT/SSDT analysis, GPIO pins, power rails, known issues — are in [`docs/hardware-analysis.md`](docs/hardware-analysis.md).
>
> **ACPI dump files** referenced in the analysis are published at the [Open-RT GitBook ACPI tables page](https://open-rt.gitbook.io/open-surfacert/surface-rt2/hardware/acpi-dsdt-tables).

## Prerequisites

- **Jailbroken Surface 2** — Secure Boot disabled (GoldenKeys + Yahallo)
- **Host PC** — macOS or Linux x86_64, with [Docker](https://www.docker.com/) installed
- **USB drive** ≥ 8 GB (FAT32)

## Step 1 — Partition the eMMC (on Windows RT)

Open Disk Management on the Surface 2 (`Win+X` → Disk Management):

| # | Size | Format | Purpose |
|---|------|--------|---------|
| p1 | ~350 MB | FAT32 | EFI System Partition (keep) |
| p2 | ~16 GB | NTFS | Windows RT (shrink) |
| p5 | ~6 GB | ext4 | Linux root `/` |
| p6 | ~5 GB | FAT32 | Staging (installer files) |

Delete the recovery partition (p3) to free space.

## Step 2 — Build (on your PC)

```bash
git clone https://github.com/YOUR_USER/surface-rt2-linux.git
cd surface-rt2-linux

# Build cross-compilation container (one-time)
docker build -t surface2-build .

# Compile kernel + DTB + initramfs
docker run --rm -v "$PWD:/work" surface2-build /work/scripts/build.sh
```

This produces:
- `output/boot/` — `boot.efi`, `surface2-custom.dtb`, `initrd.gz`, `startup.nsh`
- `output/staging/` — kernel modules + Marvell Wi-Fi firmware

## Step 3 — Prepare USB + staging

1. Format USB as **FAT32**
2. Copy everything from `output/boot/` to the USB root
3. Copy `output/staging/*` to Surface 2 **partition 6**
4. Also place a root filesystem image (e.g. Raspbian Bookworm armhf `rootfs.img`) on partition 6

## Step 4 — Boot & install

1. Plug USB into Surface 2
2. Power on holding **Volume Up** → UEFI boot menu → select USB
3. The initramfs installer (`init.sh`) runs automatically:
   - Writes `rootfs.img` → partition 5 (ext4)
   - Copies modules + firmware
   - Writes `/etc/fstab`
   - Reboots

## Step 5 — Boot from eMMC

After install, switch `startup.nsh` on the EFI partition to:

```
fs0:
\boot.efi dtb=\surface2-custom.dtb root=/dev/mmcblk0p5 rootfstype=ext4 rootwait console=tty0
```

Or copy boot files directly to the EFI System Partition to boot without USB.

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
| Black screen | Add `earlyprintk loglevel=7` to cmdline, check `dtb=` path |
| No Wi-Fi | Check `/lib/firmware/mrvl/sd8797_uapsta.bin` exists |
| No touch | Verify I2C1 HID node in DTS; try `atmel_mxt_ts` driver |
| USB flaky | Known ACPI issue — USB2/USB3 use HSIC, see hardware analysis |
| Kernel panic | Check `root=` partition number, verify ext4 on p5 |

## Project structure

```
surface-rt2-linux/
├── README.md                       # This file — quick start
├── Dockerfile                      # ARM cross-compilation container
├── docs/
│   └── hardware-analysis.md        # Full DSDT/SSDT analysis & hardware map
├── scripts/
│   ├── build.sh                    # Build kernel + DTB + initramfs
│   ├── init.sh                     # Initramfs installer (runs on device)
│   ├── prepare-usb.sh              # Format & populate USB drive
│   ├── winrt-device-discovery.ps1  # WinRT device enumeration
│   └── winrt-devinfo.bat           # WinRT driver dump (batch)
├── configs/
│   ├── surface2_defconfig_fragment # Kernel config additions
│   └── kernel-options.txt          # CONFIG_* checklist
└── dts/
    └── tegra114-surface2.dts       # Device tree template
```

## Resources

- [Open Surface RT GitBook](https://open-rt.gitbook.io/open-surfacert) — community wiki
- [grate-linux `microsoft-surface-2` branch](https://github.com/Open-Surface-RT/grate-linux/tree/microsoft-surface-2) — kernel
- [grate-driver](https://github.com/grate-driver) — Tegra 2/3/4 open-source GPU
- [Open-RT Discord](https://discord.gg/VW75GmWa95)

## License

MIT

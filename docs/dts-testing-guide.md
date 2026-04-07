# DTS Testing & Iteration Guide for Surface 2

How to test, debug, and update the device tree (`tegra114-surface2.dts`) on a running Surface 2.

---

## 1. Build Cycle

### Full build (Docker)

```bash
docker build -t surface2-build .
docker run --rm -v "$PWD/output:/work/output" surface2-build
```

This clones grate-linux, applies the defconfig fragment, copies our DTS into the kernel tree, and compiles everything. Output lands in `output/boot/`.

### DTS-only rebuild (fast iteration)

If you already have the kernel source checked out, you can rebuild just the DTB without recompiling the entire kernel:

```bash
# Inside the kernel tree (or Docker container)
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-

# Copy the DTS into the kernel tree
cp dts/tegra114-surface2.dts arch/arm/boot/dts/

# Compile only the DTB (seconds, not minutes)
make tegra114-surface2.dtb

# Result:
ls -la arch/arm/boot/dts/tegra114-surface2.dtb
```

### Syntax check without full compile

```bash
# Preprocess + compile to check for errors without linking
dtc -I dts -O dtb -o /dev/null -W no-unit_address_vs_reg \
    arch/arm/boot/dts/tegra114-surface2.dts
```

> **Note:** Our DTS uses `#include` (C preprocessor), so standalone `dtc` won't work directly. Use the kernel `make` target or preprocess first with `cpp`.

---

## 2. Deploying a New DTB

The Surface 2 boots via EFI. The DTB is loaded from the USB/eMMC FAT partition.

### USB boot (safest for testing)

1. Mount the USB EFI partition
2. Replace the DTB:
   ```bash
   cp tegra114-surface2.dtb /mnt/usb/surface2-custom.dtb
   ```
3. `startup.nsh` already references `surface2-custom.dtb`
4. Reboot with Volume Up held to enter EFI shell

### eMMC boot (after install)

```bash
# On the running Surface 2:
mount /dev/mmcblk0p1 /boot   # EFI system partition
cp tegra114-surface2.dtb /boot/surface2-custom.dtb
reboot
```

---

## 3. Inspecting the Live Device Tree

Once Linux is booted, the active device tree is exposed at `/proc/device-tree/` (aka `/sys/firmware/devicetree/base/`).

### Read a specific property

```bash
# Check model string
cat /proc/device-tree/model

# Check compatible strings
cat /proc/device-tree/compatible | tr '\0' '\n'

# Check if a node is enabled
cat /proc/device-tree/serial@70006200/status
```

### Dump the full tree

```bash
# Human-readable dump of the live DTB
dtc -I fs -O dts /proc/device-tree/ 2>/dev/null | less

# Or save to file for comparison
dtc -I fs -O dts /proc/device-tree/ > /tmp/live-dt.dts 2>/dev/null
```

### Compare live vs compiled DTB

```bash
# Decompile the DTB you built
dtc -I dtb -O dts tegra114-surface2.dtb > /tmp/compiled.dts

# Decompile the live tree
dtc -I fs -O dts /proc/device-tree/ > /tmp/live.dts 2>/dev/null

# Diff — differences reveal what the bootloader/EFI may have modified
diff /tmp/compiled.dts /tmp/live.dts
```

> EFI stub may inject `chosen` properties, memory nodes, and command line. These are normal.

---

## 4. Probing Hardware (I2C, GPIO, USB)

### I2C bus scan

```bash
# List all I2C buses
i2cdetect -l

# Scan a bus for devices (e.g., bus 0 = I2C1 at 0x7000C000)
# WARNING: can confuse some devices. Safe on most I2C buses.
i2cdetect -y 0    # I2C1: expect sensor hub @ 0x28
i2cdetect -y 1    # I2C2: expect touchscreen @ 0x4b (EFI boot)
i2cdetect -y 2    # I2C3: expect WM8962 @ 0x1a, NCT1008 @ 0x4c
i2cdetect -y 3    # I2C4: HDMI DDC (only responds with cable connected)
i2cdetect -y 4    # I2C5: Palmas @ 0x58, TPS65090 @ 0x48
```

Key things to verify:
- **Sensor hub conflict**: DTS says 0x28 (Andrew's tested value), registry says 0x3D. Scan I2C1 to see which responds.
- **Touch conflict**: DTS has 0x4b on I2C2 (EFI DTS). Registry says 0x3B on I2C1. Try both.

### GPIO state

```bash
# List all GPIO chips and their current state
cat /sys/kernel/debug/gpio

# Or per-chip:
gpioinfo gpiochip0
```

### USB devices

```bash
lsusb
cat /sys/bus/usb/devices/*/product
```

### Check what drivers bound

```bash
# See which drivers matched which DT nodes
ls /sys/bus/i2c/devices/
ls /sys/bus/platform/devices/

# Check a specific device's driver
cat /sys/bus/i2c/devices/0-0028/uevent
```

---

## 5. Debugging a Failing Node

### Kernel log (dmesg)

```bash
# Full boot log — look for probe failures
dmesg | less

# Filter for a specific subsystem
dmesg | grep -i i2c
dmesg | grep -i hid
dmesg | grep -i mmc
dmesg | grep -i wm8962
dmesg | grep -i palmas
dmesg | grep -i tps65090
```

Common messages to look for:
- `probe failed` — wrong compatible, address, or missing regulator/clock
- `NACK` on I2C — device not present at that address
- `no irq` — interrupt configuration wrong
- `timeout` — device not responding (power supply issue?)

### Enable verbose driver logging

```bash
# At boot (add to startup.nsh kernel cmdline):
# ... loglevel=7 dyndbg="module i2c_hid +p" ...

# At runtime:
echo "module i2c_hid +p" > /sys/kernel/debug/dynamic_debug/control
echo "module mwifiex_sdio +p" > /sys/kernel/debug/dynamic_debug/control
```

### Regulator state

```bash
# Check what regulators are registered and their state
cat /sys/kernel/debug/regulator/regulator_summary
```

---

## 6. Common DTS Edits

### Change an I2C address

If `i2cdetect` shows the sensor hub at 0x3D instead of 0x28:

```dts
/* In the i2c@7000c000 (I2C1) node, change: */
sensor@28 {
    reg = <0x28>;
/* To: */
sensor@3d {
    reg = <0x3d>;
```

Rebuild DTB, copy to boot partition, reboot.

### Enable/disable a node

```dts
/* Disable a problematic node: */
serial@70006200 {
    status = "disabled";  /* was "okay" */
};

/* Enable a node for testing: */
hda@70030000 {
    status = "okay";  /* was missing or "disabled" */
};
```

### Add a new I2C device

```dts
&i2c1 {   /* or i2c@7000c000 inside the root node */
    my_device@3b {
        compatible = "vendor,chip-name";
        reg = <0x3b>;
        interrupt-parent = <&gpio>;
        interrupts = <TEGRA_GPIO(X, Y) IRQ_TYPE_LEVEL_LOW>;
        /* supply-supply = <&some_regulator>; */
    };
};
```

### Test touchscreen at registry address

To try the registry-confirmed touch address instead of Andrew's EFI value:

```dts
/* Option A: Move touch to I2C1 at 0x3B (registry value) */
i2c@7000c000 {
    /* ... existing sensor@28 ... */

    touchscreen@3b {
        compatible = "hid-over-i2c";
        reg = <0x3b>;
        hid-descr-addr = <0x0001>;
        interrupt-parent = <&gpio>;
        interrupts = <TEGRA_GPIO(O, 6) IRQ_TYPE_LEVEL_LOW>;
    };
};

/* And disable the I2C2 touch node: */
i2c@7000c400 {
    touchscreen@4b {
        status = "disabled";
    };
};
```

---

## 7. Workflow Summary

```
 Edit DTS ──> make tegra114-surface2.dtb ──> Copy to USB/eMMC
     ^                                              │
     │                                              v
     └──── dmesg + i2cdetect + /proc/device-tree ───┘
```

1. **Edit** `dts/tegra114-surface2.dts` on your dev machine
2. **Build** DTB only (fast: `make tegra114-surface2.dtb`)
3. **Deploy** to USB FAT partition as `surface2-custom.dtb`
4. **Boot** Surface 2, check `dmesg` for probe results
5. **Probe** buses with `i2cdetect`, check `/proc/device-tree/`
6. **Iterate** — fix addresses, GPIOs, regulators based on findings

### Key conflicts to resolve on hardware

| What | Current DTS | Alternative | How to test |
|------|------------|-------------|-------------|
| Sensor hub addr | 0x28 on I2C1 | 0x3D on I2C1 | `i2cdetect -y 0` |
| Touch addr/bus | 0x4b on I2C2 | 0x3B on I2C1 | `i2cdetect -y 0` and `-y 1` |
| BT on UART-C | `mrvl,88w8797` | may need different compatible | `hciconfig`, `btmgmt info` |
| WiFi compatible | `marvell,sd8897` | may need `sd8797` | `dmesg | grep mwifiex` |
| HDMI HPD GPIO | N7 (guessed) | unknown | Test with cable, check `dmesg | grep hdmi` |

---

## 8. Useful Kernel Configs for Debugging

Already in our `surface2_defconfig_fragment`, but double-check these are enabled:

```
CONFIG_EARLY_PRINTK=y       # See messages before console init
CONFIG_MAGIC_SYSRQ=y        # Emergency keyboard commands
CONFIG_DEBUG_INFO=y          # Symbols in stack traces
CONFIG_I2C_CHARDEV=y         # Enables i2cdetect/i2cget tools
CONFIG_GPIO_SYSFS=y          # /sys/class/gpio/ interface (deprecated but useful)
CONFIG_DYNAMIC_DEBUG=y       # Per-module debug logging
CONFIG_REGULATOR_DEBUG=y     # Verbose regulator state logging (noisy!)
```

To add temporarily at the kernel command line:
```
loglevel=8 ignore_loglevel dyndbg="module i2c_tegra +p; module i2c_hid +p"
```

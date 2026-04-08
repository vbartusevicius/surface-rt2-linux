# Surface 2 — Hardware Analysis

Complete hardware map and ACPI analysis for the Microsoft Surface 2 (NVIDIA Tegra 4 / T114).

Sources:
- `SurfaceRT2.dsdt.txt` — DSDT from [Open-RT GitBook](https://open-rt.gitbook.io/open-surfacert/surface-rt2/hardware/acpi-dsdt-tables)
- `acpiview_dump_rt2_20200805.txt` — Full ACPI dump (DSDT + SSDT) from the same page
- `Surface2DevInfo/reg-acpi-enum.txt` — Live WinRT registry export (ACPI device enumeration)
- Board teardowns and community research

---

## Hardware Overview

| Component | Chip | Linux Driver | Status |
|-----------|------|-------------|--------|
| **SoC** | NVIDIA Tegra 4 (T114), 4× Cortex-A15 @ 1.7 GHz | `tegra114` | ✅ Works |
| **GPU** | Tegra 4 (72-core, custom arch — NOT Kepler) | `drm-tegra` + `grate` Mesa | 🟡 Experimental 3D |
| **Display** | Samsung LTL106HL02 10.6" 1080p, dual DSI | `drm-tegra` DSI panel | ✅ Framebuffer |
| **RAM** | SK Hynix 2 GB DDR3 | — | ✅ Works |
| **eMMC** | SK Hynix H26M64003DQR 32/64 GB | `sdhci-tegra` | ✅ Works |
| **SD Card** | SDHCI slot | `sdhci-tegra` | ✅ Works |
| **Wi-Fi** | Marvell Avastar 88W8797 (SDIO) | `mwifiex_sdio` | ✅ Works |
| **Bluetooth** | Marvell AVASTAR (NVDAF000) on UART-C | `hci_uart` (Marvell) | 🟡 Untested |
| **Audio** | Wolfson WM8962 | `snd-soc-wm8962` | ✅ Works |
| **HDMI Audio** | Tegra HDA | `snd-hda-tegra` | 🟡 Untested |
| **Touchscreen** | Atmel maXTouch mXT1664S (MSHW0100, I2C1 @ 0x3B) | `atmel_mxt_ts` / `i2c-hid-of` | ✅ Works |
| **PMIC** | TI TPS65913 (Palmas) | `palmas` | 🟡 Partial |
| **Charger** | TI TPS65090 | `tps65090-charger` | 🟡 Partial |
| **USB** | 3× EHCI + 1× xHCI | `ehci-tegra` / `tegra-xhci` | 🟡 Flaky |
| **Front Camera** | 3.5 MP (sensor model unknown) | TBD | ❌ Needs ID |
| **Rear Camera** | 5.0 MP (sensor model unknown) | TBD | ❌ Needs ID |
| **Sensors** | MSHW0102 HID sensor hub (I2C1 @ 0x3D, rev 100C92C) | `hid-sensor-hub` | ❓ Unknown |
| **Thermal** | Tegra TSENSOR + 4 thermal zones | `tegra-soctherm` | 🟡 Partial |
| **RTC** | Palmas RTC on I2C5 | `palmas-rtc` | ✅ Should work |
| **Lid sensor** | GPIO H3 | `gpio-keys` | ✅ Should work |
| **Buttons** | Vol+/−, Power, Windows | `gpio-keys` | ✅ Works |

---

## DSDT Device Map

DSDT identifier: `NVIDIA T114EDK2`, 15 KB.

| ACPI HID | Device | Base Address | IRQ | Notes |
|----------|--------|-------------|-----|-------|
| `NVDA0205` | GFXC (GPU) | 0x50000000 | — | 80 MB aperture, FB at 0xB0000000 |
| `NVDA0212` | SDM1 (Wi-Fi, instance 0) | 0x78000000 | — | SDMMC1, Marvell 88W8797 |
| `NVDA0212` | SDM2 (DSDT only) | 0x78000200 | — | **Not enumerated** on live system |
| `NVDA0212` | SDM3 (SD card, instance 2) | 0x78000400 | — | SDMMC3, disabled (UART-A pin conflict) |
| `NVDA0212` | SDM4 (eMMC, instance 3) | 0x78000600 | — | STOR.EMMC child |
| `NVDA0107` | AUDI (I2S) | 0x70080000 | — | DMA channels for WM8962 |
| `NVDA010F` | HDAU (HDA) | 0x70030000 | — | HDMI audio |
| `NVDA0101` | I2C1 | 0x7000C000 | 70 | Touchscreen + sensor hub |
| `NVDA0101` | I2C2 | 0x7000C400 | 116 | Touchscreen (EFI: HID@0x4b) |
| `NVDA0101` | I2C3 | 0x7000C500 | 124 | Audio codec (WM8962@0x1a) + temp sensor (NCT1008@0x4c) |
| `NVDA0101` | I2C4 | 0x7000C700 | 152 | HDMI DDC |
| `NVDA0101` | I2C5 | 0x7000D000 | 85 | PMIC + camera + charger + RTC |
| `NVDA0203` | USB1 (EHCI) | 0x7D000000 | — | Host, PNP0D20 |
| `NVDA0203` | USB2 (EHCI+HSIC) | 0x7D004000 | — | Internal HSIC |
| `NVDA0203` | USB3 (EHCI+HSIC) | 0x7D008000 | — | Internal HSIC |
| `NVDA0214` | XUSB (xHCI) | 0x70090000 | — | USB 3.0, PNP0D10 |
| `NVDA020E` | MCDV (MC) | 0x70019000 | — | Memory controller / display |
| `NVDA0008` | GPIO | 0x6000D000 | — | 8 banks |
| `NVDAF300` | THEM (Thermal) | 0x700E2000 | — | TSENSOR |
| `NVDA0100` | UAR-A/C/D (instances 0,2,3) | 0x70006000+ | — | 3 UARTs active (B,E not enumerated) |
| `NVDA0220` | PEPD | — | — | PNP0D80 power engine plugin |
| `NVDA010D` | NVSE | 0x70012000 | — | Security engine |

---

## SSDT Analysis — Camera

The camera is **not in the DSDT**. It is defined in the **first SSDT** (84,806 bytes at physical address `0xFDF05000`, OEM ID `NVIDIA`, table `AP20EDK2`).

### CAM0 device

- **Scope:** `\_SB.GFXC` (under the GPU/graphics controller)
- **`_ADR`:** `0x80031200` — NVIDIA proprietary encoding
- **`CPWR` method:** 3-stage power sequencing:
  1. Sensor power (LDO rails)
  2. Autofocus motor power
  3. Flash LED power
- **I2C bus:** I2C5 (0x7000D000), 1.4 MHz Fast Mode Plus

### Camera GPIO pins

Decoded from SSDT GpioIo resource descriptors:

| ACPI Field | Function | Tegra GPIO | Pin # |
|-----------|----------|-----------|-------|
| `FCRS` | Front camera / flash reset | BB3 | 219 |
| `RCRS` | Rear camera reset | BB7 | 223 |
| `RAFO` | Rear autofocus control | R4 | 140 |
| `RAFN` | Rear autofocus enable | EE1 | 241 |
| `FLED` | Flash LED control | S1 | 145 |

### Camera power rails

Controlled via Palmas PMIC (TPS65913) LDOs on I2C5 @ 0x58:

- **LDO1, LDO2, LDO5** — rear camera sensor power
- **LDO7, LDO9** — front camera sensor power
- **FET1, FET4, FET6** — switched power domains

### Board ID conditionals

The `CPWR` method checks `\_SB.BDID` (Board ID) to vary behavior:

| Condition | Effect |
|-----------|--------|
| BDID ≤ 1 | Autofocus via RAFO + RAFN GPIOs |
| BDID > 1 | Alternate autofocus path |
| BDID ≤ 4 | Flash LED (`FLED`) disabled |
| BDID > 4 | Flash LED enabled |

### I2C5 device addresses (from PMUD _CRS)

The PMUD device (`NVDAF242`) manages all power for I2C5 peripherals:

| I2C Address (7-bit) | Device |
|---------------------|--------|
| 0x58–0x5B | TPS65913 Palmas PMIC (4 register pages) |
| **0x12** | **Camera sensor** (probable — matches `_ADR` encoding) |
| **0x43** | Unknown — possibly VCM driver or flash controller |
| 0x48 | TPS65090 charger (probable) |

### Sensor identification — still needed

The sensor model is **not named** anywhere in the ACPI tables. NVIDIA's proprietary `NvCamera` Windows RT driver handles sensor init opaquely.

**To identify the sensor chip:**
1. Run `scripts/winrt-device-discovery.ps1` on Windows RT — look for I2C devices at address **0x12**
2. Or boot Linux and run `i2cdetect -y 4` on I2C5, then read the chip ID register
3. Check Windows driver INF files in `C:\Windows\System32\DriverStore\`

**Common 2013-era candidates:**
- Front (3.5 MP): OV2722, OV3640, OV2680, MT9M114
- Rear (5.0 MP): OV5693, OV5640, OV5648, AR0543

---

## SSDT — Other Devices

### Bluetooth — BTH0

- **HID:** `NVDAF000`
- **Bus:** UART-C (0x70006200, NVDA0100 instance 2)
- **WinRT driver:** `mbtu97w8` (Marvell AVASTAR Bluetooth Radio Enumerator)
- **Linux driver:** `hci_uart` with Marvell protocol (`CONFIG_BT_HCIUART_MARVELL`)
- **Note:** BT uses **UART** transport, not SDIO (despite being a combo chip with 88W8797 Wi-Fi)

### Sensor Hub — SNMU

- **HID:** `MSHW0102` (Microsoft Surface Hardware), **REV 100C92C**
- **CID:** `PNP0C50` (HID-over-I2C)
- **Bus:** I2C1 @ address **0x3D** (confirmed from live registry; DSDT listed 0x28 which was a descriptor index)
- **Parent:** NVDA0101 instance 1 (I2C1)
- **Contains:** Accelerometer, gyroscope (via HID sensor protocol)
- **Linux driver:** `hid-sensor-hub` + `i2c-hid-of`
- **D3Cold** supported

### GPS/Location — GPSD

- **HID:** `MSHW0010` (Microsoft Surface Hardware)
- **Bus:** UART3 + GPIO
- **Note:** Likely a virtual device / location service, not actual GPS hardware

### LCD Panel — LCD0

- **Scope:** Under I2C5
- **Power:** Uses `PRTC` (Palmas RTC power reference)
- **Interface:** Dual DSI (DSIB present in ACPI)
- **Backlight:** `BKLG` table with 7 brightness levels, `BKSA` secondary table
- **Backlight control:** `DSLG` DSI-based backlight commands

---

## USB — Known Issues

### USB2 (EHCI + HSIC) — 0x7D004000

The ACPI tables contain **debug logging** inside USB2's `_STA` method:

```
"USB2 _STA forced off"
"USB2 _STA on"
"USB2 _STA on (initial)"
"USB2 _STA controller is off"
```

USB2 uses **HSIC** (High-Speed Inter-Chip) mode — this is an internal-only interface, not the external USB port. The HSIC initialization involves complex register writes (`WRF_`/`WRR_` methods) with multiple PHY configuration steps.

**Key detail:** USB2 has a `STAF` variable that can force the controller off (value `0xF0`). When `STAF != 0xF0`, the controller is enabled only if `^^US2E` (parent scope enable flag) is set.

### USB3 (EHCI + HSIC) — 0x7D008000

USB3 has `INIT` and `MRIN` (modem reset init) methods, plus `BBEN` (baseband enable). This suggests USB3's HSIC port connects to an internal modem or baseband chip (possibly unused on the Wi-Fi-only Surface 2).

USB3 also contains extensive debug output during initialization, with register read/write sequences via `MRIN`.

### USB1 (EHCI) — 0x7D000000

USB1 is the **external** USB port. It uses standard EHCI mode with `UMOD` (USB mode) register at offset 0x1A4. The `UMOD` field controls host vs. device mode.

### XUSB (xHCI) — 0x70090000

xHCI controller (`NVDA0214`/`PNP0D10`). Known to be unreliable. Connected to the PHY at `0x50041000`.

### Live registry status

| Controller | Registry Instance | Status |
|------------|------------------|--------|
| USB1 (EHCI) | `NVDA0203\0` | ✅ Enumerated, external port |
| USB2 (EHCI+HSIC) | `NVDA0203\1` | ⚠️ Enumerated but internal only |
| USB3 (EHCI+HSIC) | — | ❌ Not enumerated on live system |
| XUSB (xHCI) | `NVDA0214` | ⚠️ Enumerated but unreliable |

### Linux implications

- **For initial install:** USB1 (EHCI, external port) works for USB boot
- **USB2/USB3 HSIC:** Internal only — USB3 not even enumerated on live system. Disable both in DTS.
- **xHCI:** Unreliable — build as module (`=m`) so it can be loaded for testing but isn't critical path
- **DTS recommendation:** `&usb1 { status = "okay"; dr_mode = "host"; }` + disable USB2/USB3/XUSB

---

## Thermal Zones

Four thermal zones defined in the SSDT (but only TZ02–TZ04 appear in live registry; TZ01 absent).
Live registry shows 3 `NVDAF300` (NvidiaThml) instances: 0, 12021, 13010.

SSDT zones:

| Zone | Sensor | Source | Notes |
|------|--------|--------|-------|
| TZ01 | IR Thermal | THEM (tegra-soctherm) | CPU/GPU die temperature. Uses "Dev Kit thermal parameters" (debug comment) |
| TZ02 | — | THEM | Secondary zone |
| TZ03 | Backlight Thermal | I2C3 (`DHTH`) | Display backlight temperature monitoring |
| TZ04 | "LTE Thermal" | I2C3 | Present despite Surface 2 being Wi-Fi only. Uses `LCD0` notify |

Each zone defines:
- `_CRT` — critical temperature (shutdown threshold, default 90°C / 0x5A)
- `_PSV` — passive cooling threshold (default 65°C / 0x41)
- `_TC1`, `_TC2` — thermal coefficients
- `_TMP` — current temperature read method

**`HTMP` flag:** When `\_SB.HTMP == 1`, the thermal zones use "Dev Kit" parameters instead of production values. This is debug firmware behavior.

### Linux thermal implementation

- **Driver:** `tegra-soctherm` reads die temperature directly from TSENSOR registers
- **CPU cooling:** Requires `CONFIG_CPU_THERMAL=y` + `CONFIG_CPU_FREQ=y` + `CONFIG_ARM_TEGRA_CPUFREQ=y`
- **DTS:** Define `thermal-zones` node with trip points matching ACPI thresholds (65°C passive, 90°C critical)
- **Note:** TZ03/TZ04 use external I2C3 sensors (`DHTH`), which may need a separate temperature driver

---

## Battery & Power

### BAT0 — Primary Battery

- **HID:** PNP0C0A (standard ACPI battery)
- **Protocol:** I2C via `RSPB` (Response Buffer) method — reads battery registers over I2C
- **Supports:** `_BIX` (extended info), `_BST` (status), `_BTP` (trip point)
- **"Serviceable Battery"** flag present — battery is user-replaceable (technically)
- **Dual battery:** Code references `BT1` and `BT2` — possibly a dual-cell pack reporting as two batteries
- **Live registry:** `PNP0C0A\1`, driver `CmBatt`
- **Linux:** `CONFIG_BATTERY_SBS=m` is the closest standard I2C battery protocol. If SBS doesn't work, a custom driver may be needed for the RSPB protocol.

### PEPD — Power Engine Plugin

- **HID:** `NVDA0220` / `PNP0D80`
- Almost every device has `_DEP` on `\_SB.PEPD` — Windows uses this for connected standby power management
- Linux does not use PEPD — devices need explicit DTS power management instead
- `UPH1` variable tracks USB PHY state

### Power states

Most devices declare `_S0W = 3` and `_S4W = 3` (deepest power state in S0 idle and S4 hibernate). This is a Windows connected standby design — on Linux, standard `runtime_pm` handles per-device power.

---

## LID Sensor

- **HID:** PNP0C0D (standard ACPI lid)
- **GPIO:** H3 + R4 (via `GPH3` and `GPR4` GpioIo resources)
- **State variable:** `LIDB` (1 = open, 0 = closed)
- **Behavior:** LID events trigger `Notify(\_SB.LID_, 0x80)` and also notify `TOUC` (touchscreen — likely to disable touch when lid is closed, i.e. when the Type Cover is folded back)

---

## RTC

- **Device:** `RTCD` on I2C5
- **Driver:** Palmas RTC (`palmas-rtc`, built into TPS65913)
- **Register access:** Via `RTCF` (RTC field) using I2C5 operations
- **Functions:** SECDAT, MINSDAT, HOURDAT, DAYDAT — standard time registers
- **`RTCV` / `VALD`:** RTC valid flag — checks if the RTC has a valid time set

---

## I2C Bus Summary

| Bus | Address | IRQ | Devices |
|-----|---------|-----|---------|
| I2C1 | 0x7000C000 | 70 | Sensor hub (HID@0x28, tested) + Touch/Cover via hotplug. Registry: MSHW0100@**0x3B**, MSHW0102@**0x3D** |
| I2C2 | 0x7000C400 | 116 | Touchscreen (EFI: HID@0x4b, not yet working) |
| I2C3 | 0x7000C500 | 124 | Audio codec (WM8962@0x1a), Temp sensor (NCT1008@0x4c), Thermal `DHTH` |
| I2C4 | 0x7000C700 | 152 | HDMI DDC |
| I2C5 | 0x7000D000 | 85 | Palmas PMIC (0x58-0x5B), Camera (0x12), Charger (0x48), RTC, LCD0 |

---

## 3D GPU Support

The Tegra 4 GPU uses NVIDIA's **custom architecture** — it is NOT Kepler and is NOT supported by Nouveau.

The **[grate-driver](https://github.com/grate-driver)** project provides open-source support:

- **Kernel:** `drm-tegra` (in mainline + grate-linux fork)
- **User-space:** `libdrm` (opentegra) → Mesa (`tegra` Gallium) → `libvdpau-tegra`
- **Status:** Experimental. Basic OpenGL ES / GL works. Not production-grade.
- **Fallback:** `llvmpipe` software renderer

**Recommended approach:**
1. Boot with framebuffer only (`CONFIG_DRM_TEGRA=y`)
2. Add grate user-space after base system works
3. Use XFCE or Weston (lightweight)

---

## Live Registry Data (reg-acpi-enum.txt)

The following data was extracted from a live Windows RT 8.1 system via registry export of
`HKLM\SYSTEM\CurrentControlSet\Enum\ACPI`. This provides **ground-truth** device addresses
and driver mappings that supersede any DSDT/SSDT analysis where they conflict.

### Complete ACPI Device Inventory

| ACPI HID | Instance(s) | Description | WinRT Driver | Notes |
|----------|-------------|-------------|-------------|-------|
| `ACPI0003` | — | AC Adapter | `CmBatt` | Standard ACPI |
| `ACPI000C` | — | Processor Aggregator | `acpipagr` | |
| `ACPI000E` | — | Wake Alarm | `acpitime` | |
| `MSFT0101` | 1 | TPM 2.0 | `TPM` | HardwareType 0x14 |
| `MSHW0005` | — | Laptop/Slate Indicator | `msgpiowin32` | PNP0C60 compatible |
| `MSHW0006` | — | Surface Accessory Device | `SurfaceAccessoryDevice` | Type Cover connector |
| `MSHW0011` | 1 | Surface Platform Power | `SurfacePlatformPowerDriver` | 9+ GPIOs, complex resources |
| `MSHW0014` | — | Surface System Software | (none) | No service loaded |
| `MSHW0015` | — | Surface Integration Driver | `SurfaceIntegrationDriver` | |
| `MSHW0100` | — | Touch (HID-over-I2C) | `hidi2c` | **I2C @ 0x3B**, D3Cold, PNP0C50 |
| `MSHW0101` | — | Surface Home Button | `SurfaceHomeButton` | 4 GPIO blocks, 5 IRQs |
| `MSHW0102` | — | Sensor Hub (HID-over-I2C) | `hidi2c` | **I2C @ 0x3D**, rev 100C92C, D3Cold |
| `NVDA0008` | 0 | Tegra GPIO Controller | `tegra2gpio` | 8 banks (D0–D7) |
| `NVDA0009` | — | Tegra DMA HAL Extension | — | |
| `NVDA000A` | — | Tegra Timers HAL Extension | — | |
| `NVDA0100` | 0, 2, 3 | UART V2 | `UartClass` | UART-A, C, D only (B,E absent) |
| `NVDA0101` | 1–5 | Tegra I2C Controller | `tegrai2c` | Instances 1–5 confirmed |
| `NVDA0107` | — | Tegra Audio Controller | `nvaenum` | I2S + DMA |
| `NVDA010D` | — | Secure Engine | `nvse` | |
| `NVDA010F` | — | HD Audio Controller | `HDAudBus` | HDMI audio |
| `NVDA0110` | — | Secure Channel | `nvsc` | |
| `NVDA0203` | 0, 1 | EHCI USB | `usbehci` + `nvehcifilter` | 0=external, 1=internal HSIC |
| `NVDA0205` | — | NVIDIA Tegra 4 (GPU) | `nvlddmkm` | Display class 0003 |
| `NVDA020E` | — | Tegra Memory Controller | `nvmem` | MC + EMC registers |
| `NVDA0212` | 0, 2, 3 | SD Host Controller | `sdbus` | 0=SD, 2=Wi-Fi, 3=eMMC |
| `NVDA0214` | — | XHCI Host Controller | `USBXHCI` + `nvxhcifilter` | MSI supported |
| `NVDA0220` | — | Power Engine Plugin (PEP) | `nvpep` | PNP0D80 compatible |
| `NVDAF000` | — | BT Radio Enumerator | `mbtu97w8` | Marvell AVASTAR, **UART** transport |
| `NVDAF180` | — | GPIO Buttons | `msgpiowin32` | PNP0C40 (Vol+/−, Power) |
| `NVDAF242` | — | Tegra 4 PMU | `nvt40pmu` | Rev 3, 7 IRQs |
| `NVDAF300` | 0, 12021, 13010 | Tegra Thermal | `NvidiaThml` | 3 instances |
| `PNP0C0A` | 1 | Battery | `CmBatt` | Standard ACPI battery |
| `PNP0C0D` | — | ACPI Lid | — | No service |
| `PNP0C14` | 0, MTHD | WMI ACPI | `WmiAcpi` | 2 instances |
| `ThermalZone` | TZ02, TZ03, TZ04 | ACPI Thermal Zone | — | TZ01 not in registry |
| CPU (ARM) | 0–3 | NVIDIA Tegra 4 Quad Core | `FxPPM` | ARM Family 7, Model C0F, Rev 202 |

### Key Corrections from Live Data

| Item | DSDT/SSDT Value | Live Registry Value | Impact |
|------|----------------|--------------------|----|
| **Touch I2C address** | (not specified) | **0x3B** | Untested; upstream EFI DTS uses 0x4b on I2C2 (also doesn't work). Try 0x3B on I2C1 |
| **Sensor hub I2C address** | 0x28 | **0x3D** | ⚠️ 0x28 is correct — proven by grate-linux upstream, Andrew, and Surface RT. 0x3D is ACPI `_CRS` encoding, not the I2C slave address |
| **Active UARTs** | 5 (UAR1–UAR5) | 3 (A, C, D) | UART-B/E can be omitted from DTS |
| **Active SDIO slots** | 4 (SDM1–SDM4) | 3 (0, 2, 3) | SDM2 disabled/absent |
| **WiFi/SD slot mapping** | SDM1=SD, SDM3=WiFi (assumed) | **SDM1=WiFi, SDM3=SD** | Confirmed by Andrew's tested DTS. SDMMC3 disabled (UART-A pin conflict) |
| **I2C2 function** | Audio codec (assumed) | **Touchscreen** (EFI: HID@0x4b) | Andrew's EFI DTS; touch not yet working |
| **I2C3 function** | Misc | **Audio (WM8962@0x1a) + Temp (NCT1008@0x4c)** | Confirmed by Andrew's tested DTS |
| **I2C4 function** | Misc | **HDMI DDC** | Confirmed by Andrew's tested DTS |
| **BT transport** | assumed SDIO | **UART** (`mbtu97w8`) | Kernel config: use `BT_HCIUART_MARVELL` |
| **EHCI instances** | 3 (USB1–USB3) | 2 (0, 1) | USB3 may not be enumerated |
| **Thermal zones in registry** | 4 (TZ01–TZ04) | 3 (TZ02–TZ04) | TZ01 may be handled differently |
| **NVDAF300 instances** | 1 (THEM) | 3 (0, 12021, 13010) | Multiple thermal driver instances |

### CPU Details

```
FriendlyName: NVIDIA(R) TEGRA(R) 4 Quad Core CPU
Architecture: ARM Family 7, Model C0F, Revision 202
Cores: 4 (instances 0–3)
Driver: FxPPM (Framework Power Policy Manager)
Compatible: ACPI\Processor
```

---

## Windows RT Device Discovery

If you still have Windows RT running on the Surface 2, run the scripts in `scripts/` to dump device info:

- **`winrt-device-discovery.ps1`** — PowerShell, enumerates PnP devices, cameras, I2C, resources
- **`winrt-devinfo.bat`** — Batch, runs `pnputil`, `driverquery`, registry dumps

Key things to look for:
- Camera sensor Hardware IDs (I2C devices on bus 5)
- Battery driver details in `HKLM\SYSTEM\CurrentControlSet\Services`
- Sensor hub configuration

Output files are saved to `C:\Surface2DevInfo\`.

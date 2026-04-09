# winrt-device-discovery.ps1
# Run this on your jailbroken Surface 2 (Windows RT)
# Extracts all device/driver information needed for Linux DTB creation
#
# Usage: Open PowerShell as Administrator, then:
#   Set-ExecutionPolicy Bypass -Scope Process
#   .\winrt-device-discovery.ps1

$outDir = "C:\Surface2DevInfo"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "=== Surface 2 Device Discovery ===" -ForegroundColor Cyan
Write-Host "Output directory: $outDir"

# ─── 1. All PnP Devices ────────────────────────────────────────────
Write-Host "Enumerating all PnP devices ..." -ForegroundColor Yellow
$allDevices = Get-PnpDevice -ErrorAction SilentlyContinue
$allDevices | Format-List * | Out-File "$outDir\all-devices.txt" -Width 300
$allDevices | Select-Object Status, Class, FriendlyName, InstanceId, HardwareID |
    Sort-Object Class |
    Format-Table -AutoSize -Wrap |
    Out-File "$outDir\device-summary.txt" -Width 300

# ─── 2. Camera / Imaging devices ──────────────────────────────────
Write-Host "Looking for camera/imaging devices ..." -ForegroundColor Yellow
$cameras = $allDevices | Where-Object {
    $_.Class -eq 'Camera' -or
    $_.Class -eq 'Image' -or
    $_.Class -eq 'Imaging' -or
    $_.FriendlyName -like '*cam*' -or
    $_.FriendlyName -like '*video*' -or
    $_.FriendlyName -like '*sensor*'
}
if ($cameras) {
    $cameras | Format-List * | Out-File "$outDir\camera-devices.txt" -Width 300
    Write-Host "  Found $($cameras.Count) camera device(s)!" -ForegroundColor Green
} else {
    "No camera devices found by class filter. Check all-devices.txt manually." |
        Out-File "$outDir\camera-devices.txt"
    Write-Host "  No camera devices found by class filter" -ForegroundColor Red
}

# ─── 3. I2C devices ───────────────────────────────────────────────
Write-Host "Looking for I2C devices ..." -ForegroundColor Yellow
$i2c = $allDevices | Where-Object {
    $_.InstanceId -like '*I2C*' -or
    $_.HardwareID -like '*I2C*'
}
$i2c | Format-List * | Out-File "$outDir\i2c-devices.txt" -Width 300

# ─── 4. SPI devices ───────────────────────────────────────────────
Write-Host "Looking for SPI devices ..." -ForegroundColor Yellow
$spi = $allDevices | Where-Object {
    $_.InstanceId -like '*SPI*' -or
    $_.HardwareID -like '*SPI*'
}
$spi | Format-List * | Out-File "$outDir\spi-devices.txt" -Width 300

# ─── 5. ACPI devices ──────────────────────────────────────────────
Write-Host "Looking for ACPI devices ..." -ForegroundColor Yellow
$acpi = $allDevices | Where-Object { $_.InstanceId -like 'ACPI*' }
$acpi | Select-Object Status, FriendlyName, InstanceId, HardwareID |
    Format-Table -AutoSize -Wrap |
    Out-File "$outDir\acpi-devices.txt" -Width 300

# ─── 6. USB devices ───────────────────────────────────────────────
Write-Host "Looking for USB devices ..." -ForegroundColor Yellow
$usb = $allDevices | Where-Object { $_.InstanceId -like 'USB*' }
$usb | Select-Object Status, FriendlyName, InstanceId, HardwareID |
    Format-Table -AutoSize -Wrap |
    Out-File "$outDir\usb-devices.txt" -Width 300

# ─── 7. Driver details ────────────────────────────────────────────
Write-Host "Enumerating drivers ..." -ForegroundColor Yellow
Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Select-Object DeviceName, DriverVersion, Manufacturer, InfName, HardWareID, DeviceClass |
    Sort-Object DeviceClass |
    Format-Table -AutoSize -Wrap |
    Out-File "$outDir\driver-details.txt" -Width 300

# ─── 8. Device resources (IRQ, Memory, DMA) ───────────────────────
Write-Host "Enumerating device resources ..." -ForegroundColor Yellow
try {
    Get-CimInstance Win32_PnPAllocatedResource -ErrorAction SilentlyContinue |
        Format-List * |
        Out-File "$outDir\device-resources.txt" -Width 300
} catch {
    "Could not enumerate PnP resources" | Out-File "$outDir\device-resources.txt"
}

# ─── 9. Registry: enum ACPI (detailed hardware IDs) ───────────────
Write-Host "Reading ACPI device registry entries ..." -ForegroundColor Yellow
try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI"
    if (Test-Path $regPath) {
        Get-ChildItem -Path $regPath -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                $key = $_
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                if ($props.HardwareID -or $props.FriendlyName) {
                    [PSCustomObject]@{
                        Path         = $key.PSPath -replace 'Microsoft.PowerShell.Core\\Registry::',''
                        FriendlyName = $props.FriendlyName
                        HardwareID   = ($props.HardwareID -join '; ')
                        CompatibleID = ($props.CompatibleIDs -join '; ')
                        Driver       = $props.Driver
                        Service      = $props.Service
                    }
                }
            } | Format-List * | Out-File "$outDir\acpi-registry.txt" -Width 300
    }
} catch {
    "Could not read ACPI registry" | Out-File "$outDir\acpi-registry.txt"
}

# ─── 10. Specifically search for CSI / camera-related strings ──────
Write-Host "Searching for camera-related strings in registry ..." -ForegroundColor Yellow
try {
    $cameraReg = @()
    $searchPaths = @(
        "HKLM:\SYSTEM\CurrentControlSet\Enum",
        "HKLM:\SYSTEM\CurrentControlSet\Services"
    )
    foreach ($sp in $searchPaths) {
        if (Test-Path $sp) {
            Get-ChildItem -Path $sp -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $name = $_.Name
                    if ($name -match 'cam|csi|ov56|ov26|ov76|imx|s5k|video|sensor|vi_') {
                        $cameraReg += [PSCustomObject]@{
                            RegKey = $name
                        }
                    }
                }
        }
    }
    if ($cameraReg.Count -gt 0) {
        $cameraReg | Format-List * | Out-File "$outDir\camera-registry.txt" -Width 300
    } else {
        "No camera-related registry keys found" | Out-File "$outDir\camera-registry.txt"
    }
} catch {
    "Registry search failed" | Out-File "$outDir\camera-registry.txt"
}

# ─── Summary ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Discovery complete! ===" -ForegroundColor Green
Write-Host "Files saved to: $outDir"
Write-Host ""
Get-ChildItem $outDir | ForEach-Object {
    Write-Host "  $($_.Name) ($([math]::Round($_.Length/1024, 1)) KB)"
}
Write-Host ""
Write-Host "Copy the entire $outDir folder to your PC for analysis." -ForegroundColor Cyan
Write-Host "Key file to check first: camera-devices.txt and acpi-registry.txt" -ForegroundColor Cyan

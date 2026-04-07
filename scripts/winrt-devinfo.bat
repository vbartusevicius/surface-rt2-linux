@echo off
REM winrt-devinfo.bat
REM Run as Administrator on Surface 2 (Windows RT)
REM Dumps device and driver information for Linux DTB creation

set OUTDIR=C:\Surface2DevInfo
mkdir %OUTDIR% 2>nul

echo === Surface 2 Device Info Dump ===
echo Output: %OUTDIR%
echo.

echo [1/6] Enumerating connected devices ...
pnputil /enum-devices /connected > %OUTDIR%\pnputil-connected.txt 2>&1

echo [2/6] Enumerating all devices ...
pnputil /enum-devices > %OUTDIR%\pnputil-all.txt 2>&1

echo [3/6] Listing drivers ...
driverquery /v > %OUTDIR%\driverquery.txt 2>&1

echo [4/6] Listing driver files ...
driverquery /v /fo csv > %OUTDIR%\driverquery.csv 2>&1

echo [5/6] System info ...
systeminfo > %OUTDIR%\systeminfo.txt 2>&1

echo [6/6] Registry device enum ...
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI" /s > %OUTDIR%\reg-acpi-enum.txt 2>&1
reg query "HKLM\SYSTEM\CurrentControlSet\Services" /s > %OUTDIR%\reg-services.txt 2>&1

echo.
echo === Done! ===
echo Files saved to %OUTDIR%
echo.
echo Copy this folder to your PC.
echo Key files: pnputil-connected.txt, reg-acpi-enum.txt
pause

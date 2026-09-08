@echo off
title ExFAT Format Tool
color 0A

:: ============================================
:: USB Inference Key - Format to exFAT
:: ============================================
:: FAT32 has a 4GB file limit. Most GGUF models
:: are 5-16GB+. Reformat this USB to exFAT to
:: remove the limit. exFAT is supported natively
:: by Windows 10/11.
:: ============================================

set "USB_DRIVE=%~d0"

:: Guard: refuse to run from a network share (would target the wrong drive).
echo %~f0 | findstr /r "^\\\\" >nul && (
    echo  [!] Run this script FROM THE USB STICK, not from a network share.
    echo  [!] (Or just: Explorer - right-click the stick - Format - exFAT)
    pause
    exit /b 1
)

echo.
echo  USB Inference Key - Format to exFAT
echo.
echo  This will ERASE ALL DATA on %USB_DRIVE%
echo.
echo  The USB must remain plugged in during this process.
echo  After formatting: clone this repo onto the stick, run get-binaries.ps1,
  echo  then copy your models into models\ - or copy a finished kit folder wholesale.
echo.
pause

echo.
echo  Formatting %USB_DRIVE% to exFAT...
format %USB_DRIVE% /FS:exFAT /V:INFERENCE /Q /Y

echo.
echo  Format complete.
echo  Re-run setup to rebuild the directory structure.
echo.
pause

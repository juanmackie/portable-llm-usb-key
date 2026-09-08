@echo off
title Copy Models
color 0A

set "USB_DRIVE=%~d0"
set "MODELS_DIR=%USB_DRIVE%\models"

rem Put your own model share here if you have one; leave it blank if you do not.
set "MODELS_SRC="

echo.
echo  USB Inference Key - Model Copier
echo  Destination: %MODELS_DIR%
echo.
if defined MODELS_SRC (
  echo  Copy from your share:
echo    net use Z: %MODELS_SRC%
echo    xcopy Z:*.gguf %MODELS_DIR% /E /Y
echo    net use Z: /delete
echo.
echo  Or just drag-drop .gguf files into %MODELS_DIR%
) else (
  echo  No share configured. Edit MODELS_SRC in this file, or drag-drop .gguf files
echo  into %MODELS_DIR% - the stick picks the largest one the laptop can hold.
  echo  Fit guide and download hints: %MODELS_DIR%README.txt
)
echo.
pause

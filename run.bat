@echo off
title USB Inference Key
color 0A
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\serve.ps1" start
pause

@echo off
title USB Inference Key
color 0A
powershell -NoProfile -ExecutionPolicy Bypass -File "%~d0\scripts\serve.ps1" start -Visible

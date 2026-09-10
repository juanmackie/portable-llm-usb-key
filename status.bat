@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\serve.ps1" status
pause

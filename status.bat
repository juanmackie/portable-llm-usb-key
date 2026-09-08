@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~d0\scripts\serve.ps1" status
pause

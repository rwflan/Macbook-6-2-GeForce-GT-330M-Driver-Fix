@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process PowerShell -Verb RunAs -WorkingDirectory '%SCRIPT_DIR%' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%SCRIPT_DIR%Apply-GT330M-StabilityFix.ps1""'"

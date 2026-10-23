@echo off
chcp 65001 >nul 2>&1
title Nvidia Instant Replay Auto - Installer
cd /d "%~dp0"

echo.
echo ============================================
echo   NVIDIA Instant Replay Auto - Installer
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"

echo.
echo ============================================
if errorlevel 1 (
    echo   INSTALL FINISHED WITH ERRORS
    echo   Please check the messages above.
) else (
    echo   Done. Press any key to close.
)
echo ============================================
echo.
pause

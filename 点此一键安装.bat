@echo off
chcp 65001 >nul 2>&1
title NVIDIA Instant Replay Auto - Install
cd /d "%~dp0"

echo.
echo ============================================
echo   NVIDIA Instant Replay Auto
echo   One-click installer
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"

echo.
echo ============================================
if errorlevel 1 (
    echo   FINISHED WITH ERRORS - see messages above
) else (
    echo   Done. Press any key to close.
)
echo ============================================
echo.
pause

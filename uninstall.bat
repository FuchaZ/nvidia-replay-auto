@echo off
chcp 65001 >nul 2>&1
title Nvidia Instant Replay Auto - Uninstaller
cd /d "%~dp0"

echo.
echo ============================================
echo   NVIDIA Instant Replay Auto - Uninstaller
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall

echo.
echo ============================================
echo   Done. You can now delete this folder.
echo ============================================
echo.
pause

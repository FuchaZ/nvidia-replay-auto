@echo off
chcp 65001 >nul 2>&1
title NVIDIA Instant Replay Auto - Uninstall
cd /d "%~dp0"

echo.
echo ============================================
echo   NVIDIA Instant Replay Auto
echo   Uninstall
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall

echo.
echo ============================================
echo   Done. You can now delete this folder.
echo ============================================
echo.
pause

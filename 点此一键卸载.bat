@echo off
chcp 65001 >nul 2>&1
title NVIDIA 即时回放自动开关 - 卸载
cd /d "%~dp0"

echo.
echo ============================================
echo   NVIDIA 即时回放自动开关
echo   卸载
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall

echo.
echo ============================================
echo   卸载完成，现在可以把这个文件夹整个删掉了
echo ============================================
echo.
pause

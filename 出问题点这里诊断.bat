@echo off
chcp 65001 >nul 2>&1
title NVIDIA 即时回放自动开关 - 诊断
cd /d "%~dp0"

echo.
echo ============================================
echo   诊断工具
echo   如果自动开关没生效，运行这个看看原因
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"

echo.
echo ============================================
echo   把上面窗口截图发给开发者即可定位问题
echo ============================================
echo.
pause

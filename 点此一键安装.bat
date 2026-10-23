@echo off
chcp 65001 >nul 2>&1
title NVIDIA 即时回放自动开关 - 安装
cd /d "%~dp0"

echo.
echo ============================================
echo   NVIDIA 即时回放自动开关
echo   一键安装
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"

echo.
echo ============================================
if errorlevel 1 (
    echo   安装过程中出现问题
    echo   请查看上面的提示信息
) else (
    echo   安装完成，按任意键关闭
)
echo ============================================
echo.
pause

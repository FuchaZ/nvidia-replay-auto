@echo off
chcp 65001 >nul 2>&1
title NVIDIA 即时回放自动开关 - 游戏清单
cd /d "%~dp0"

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_list-games.ps1"

echo.
pause

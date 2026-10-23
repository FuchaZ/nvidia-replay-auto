@echo off
chcp 65001 >nul 2>&1
title Nvidia Instant Replay Auto - Game List
cd /d "%~dp0"

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_list-games.ps1"

echo.
pause

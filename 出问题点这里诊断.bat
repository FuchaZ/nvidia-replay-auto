@echo off
chcp 65001 >nul 2>&1
title NVIDIA Instant Replay Auto - Diagnose
cd /d "%~dp0"

echo.
echo ============================================
echo   Diagnose tool
echo   Run this if auto-switching does not work
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"

echo.
echo ============================================
echo   Send a screenshot of this window to the author
echo ============================================
echo.
pause

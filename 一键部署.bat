@echo off
chcp 65001 >nul
title ComfyUI + MOSS-Image 一键配置
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
pause >nul

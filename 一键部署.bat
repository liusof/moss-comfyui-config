@echo off
chcp 65001 >nul
title ComfyUI + MOSS-Image 一键配置
cd /d "%~dp0"
echo.
echo   ============================================================
echo    ComfyUI 0.42.0 + MOSS-Image 一键安装
echo   ============================================================
echo    首次约 40-110 分钟，主要花在下 12.1GB 权重上。
echo    中途断了直接重跑本文件，已完成的步骤会跳过，权重会续传。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo   安装完成。下一步：双击桌面的 ComfyUI-MOSS-Image.bat 启动。
  echo   想先自检环境：powershell -ExecutionPolicy Bypass -File "%~dp0verify_chain.ps1"
) else (
  echo   安装中断，退出码 %RC%。重跑本文件会从断点继续。
)
echo.
pause

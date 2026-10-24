@echo off
chcp 65001 >nul
cd /d "%~dp0"
".venv\Scripts\python.exe" main.py --listen 127.0.0.1 --port 8188
pause

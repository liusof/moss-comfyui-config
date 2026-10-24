@echo off
setlocal
cd /d "%~dp0"

rem 8 GB VRAM: if you hit OOM when encoding the prompt, add --lowvram (text encoder runs on CPU).
".venv\Scripts\python.exe" main.py --listen 127.0.0.1 --port 8188

pause

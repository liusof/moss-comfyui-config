param(
    [switch]$SkipModels,
    [switch]$NoDesktopShortcut,
    [string]$HfBase = 'https://hf-mirror.com/Comfy-Org/MOSS-Image/resolve/main'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $root

Write-Host '===== ComfyUI + MOSS-Image 一键配置 ====='
Write-Host ''

# 1. 虚拟环境
$venv = Join-Path $root '.venv'
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $python)) {
    Write-Host '[1/6] 创建 Python 3.11 虚拟环境'
    $made = $false
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3.11 -m venv $venv
        $made = ($LASTEXITCODE -eq 0)
    }
    if (-not $made -and (Get-Command python -ErrorAction SilentlyContinue)) {
        $v = (& python -c "import sys;print('%d.%d'%sys.version_info[:2])").Trim()
        if ($v -eq '3.11') { & python -m venv $venv; $made = ($LASTEXITCODE -eq 0) }
    }
    if (-not $made) {
        Write-Host ''
        Write-Host '未找到 Python 3.11。请安装后重新运行：'
        Write-Host '  https://www.python.org/downloads/release/python-3119/'
        Write-Host '安装时勾选 "Add python.exe to PATH"'
        exit 1
    }
} else {
    Write-Host '[1/6] 复用已有 .venv'
}

$ver = (& $python -c "import sys;print('%d.%d' % sys.version_info[:2])").Trim()
if ($ver -ne '3.11') { Write-Warning "虚拟环境是 Python $ver，快照验证版本为 3.11" }

# 2. pip
Write-Host '[2/6] 升级 pip'
& $python -m pip install --upgrade pip --timeout 60 --retries 10
if ($LASTEXITCODE -ne 0) { throw 'pip 升级失败，检查网络后重跑本脚本' }

# 3. PyTorch
Write-Host '[3/6] 安装 PyTorch 2.14.1 + CUDA 13.0（约 3GB，首次较慢）'
& $python -m pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu130 --timeout 120 --retries 20
if ($LASTEXITCODE -ne 0) { throw 'PyTorch 安装失败，重跑本脚本会复用已下载的缓存' }

# 4. ComfyUI 依赖
Write-Host '[4/6] 安装 ComfyUI 依赖'
& $python -m pip install -r requirements.txt --timeout 120 --retries 20
if ($LASTEXITCODE -ne 0) { throw '依赖安装失败，重跑本脚本会复用已下载的缓存' }

# 5. 模型
$models = @(
    @{ Path = 'models\diffusion_models\moss_image_sft_int8_convrot.safetensors'; Size = 5413698958 },
    @{ Path = 'models\text_encoders\qwen3.5_9b_w4a8_gptq.safetensors'; Size = 7343591088 },
    @{ Path = 'models\vae\flux2-vae_small.safetensors'; Size = 249521340 }
)

if ($SkipModels) {
    Write-Host '[5/6] 跳过模型下载（-SkipModels）'
} else {
    Write-Host '[5/6] 下载 MOSS-Image 量化权重，共约 12.1GB（Ctrl+C 中断后重跑会续传）'
    foreach ($m in $models) {
        $out = Join-Path $root $m.Path
        $dir = Split-Path -Parent $out
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path $out) -and ((Get-Item $out).Length -eq $m.Size)) {
            Write-Host "  已完整：$($m.Path)"
            continue
        }
        $url = $HfBase + '/' + ($m.Path -replace '\\', '/')
        Write-Host "  下载 $($m.Path)"
        & curl.exe -L -C - --retry 10 --retry-delay 5 --retry-all-errors --progress-bar -o $out $url
        if (-not (Test-Path $out) -or (Get-Item $out).Length -ne $m.Size) {
            throw "下载不完整：$($m.Path)，重跑本脚本可续传"
        }
    }
    Write-Host '  权重校验通过'
}

# 6. 桌面启动器
if ($NoDesktopShortcut) {
    Write-Host '[6/6] 跳过桌面启动器（-NoDesktopShortcut）'
} else {
    Write-Host '[6/6] 生成桌面启动器'
    $desktop = [Environment]::GetFolderPath('Desktop')
    $batPath = Join-Path $desktop 'ComfyUI-MOSS-Image.bat'
    $tpl = @'
@echo off
chcp 65001 >nul
title ComfyUI - MOSS-Image
cd /d "__ROOT__"

rem 服务已在运行：直接打开浏览器
powershell -NoProfile -Command "try{$null=Invoke-WebRequest 'http://127.0.0.1:8188/' -UseBasicParsing -TimeoutSec 2; exit 0}catch{exit 1}"
if not errorlevel 1 (
    start "" http://127.0.0.1:8188
    exit /b 0
)

rem 服务就绪后自动打开浏览器
start "" /min powershell -NoProfile -WindowStyle Hidden -Command "for($i=0;$i -lt 300;$i++){try{$null=Invoke-WebRequest 'http://127.0.0.1:8188/' -UseBasicParsing -TimeoutSec 2; Start-Process 'http://127.0.0.1:8188'; break}catch{}; Start-Sleep -Seconds 1}"

".venv\Scripts\python.exe" main.py --listen 127.0.0.1 --port 8188

echo.
echo ComfyUI stopped.
pause
'@
    $text = $tpl.Replace('__ROOT__', $root)
    [IO.File]::WriteAllText($batPath, ($text -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  $batPath"
}

Write-Host ''
Write-Host '===== 完成 ====='
Write-Host "启动：双击桌面 ComfyUI-MOSS-Image.bat"
Write-Host "  或   cd `"$root`"; .\.venv\Scripts\python.exe main.py --listen 127.0.0.1 --port 8188"
Write-Host '浏览器打开 http://127.0.0.1:8188 ，模板选 Text to Image (MOSS-Image)'

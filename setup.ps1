param(
    [switch]$SkipModels,
    [switch]$NoDesktopShortcut,
    [string]$ComfyCommit = 'bc5f880dbdd43e426077f42ccec53bb577ffee9f',
    [string]$SourceProxy = 'https://gh-proxy.com',
    [string]$HfBase = 'https://hf-mirror.com/Comfy-Org/MOSS-Image/resolve/main'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $root

Write-Host '===== ComfyUI + MOSS-Image 一键配置 ====='
Write-Host ''

# 1. 源码 + 配置
if (Test-Path (Join-Path $root 'main.py')) {
    Write-Host '[1/5] ComfyUI 源码已存在，跳过下载'
} else {
    Write-Host "[1/5] 下载 ComfyUI 源码（commit $($ComfyCommit.Substring(0,7))，约 25MB）"
    $tar = Join-Path $env:TEMP "comfyui-$($ComfyCommit.Substring(0,7)).tar.gz"
    $url = "$SourceProxy/https://github.com/comfyanonymous/ComfyUI/archive/$ComfyCommit.tar.gz"
    & curl.exe -L --retry 5 --retry-delay 3 --retry-all-errors --progress-bar -o $tar $url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tar)) {
        throw "源码下载失败：$url`n可手动执行：git clone https://github.com/comfyanonymous/ComfyUI.git"
    }
    $tmp = Join-Path $env:TEMP 'comfy_src_extract'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    & tar.exe -xzf $tar -C $tmp
    if ($LASTEXITCODE -ne 0) { throw '解压失败（需要 Windows 10 1803+ 自带的 tar.exe）' }
    $inner = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
    $innerReadme = Join-Path $inner 'README.md'
    if (Test-Path $innerReadme) {
        Copy-Item $innerReadme (Join-Path $root 'README.comfyui.md') -Force
        Remove-Item $innerReadme -Force
    }
    Get-ChildItem $inner -Force | Move-Item -Destination $root -Force
    Remove-Item $tmp -Recurse -Force
}

$userDir = Join-Path $root 'user\default'
New-Item -ItemType Directory -Path (Join-Path $userDir 'workflows') -Force | Out-Null
Copy-Item (Join-Path $root 'config\comfy-settings.json') (Join-Path $userDir 'comfy.settings.json') -Force
Copy-Item (Join-Path $root 'workflows\*.json') (Join-Path $userDir 'workflows') -Force
Write-Host '  配置与 5 个分辨率工作流已复制到 user/default/'

# 2. 虚拟环境
$venv = Join-Path $root '.venv'
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $python)) {
    Write-Host '[2/5] 创建 Python 3.11 虚拟环境'
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
    Write-Host '[2/5] 复用已有 .venv'
}

# 3. 依赖
Write-Host '[3/5] 安装 Python 依赖（torch 约 3GB，首次较慢）'
& $python -m pip install --upgrade pip --timeout 60 --retries 10
if ($LASTEXITCODE -ne 0) { throw 'pip 升级失败，检查网络后重跑本脚本' }
& $python -m pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu130 --timeout 120 --retries 20
if ($LASTEXITCODE -ne 0) { throw 'PyTorch 安装失败，重跑会复用已下载缓存' }
& $python -m pip install -r requirements.txt --timeout 120 --retries 20
if ($LASTEXITCODE -ne 0) { throw '依赖安装失败，重跑会复用已下载缓存' }

# 4. 模型
$models = @(
    @{ Path = 'models\diffusion_models\moss_image_sft_int8_convrot.safetensors'; Size = 5413698958 },
    @{ Path = 'models\text_encoders\qwen3.5_9b_w4a8_gptq.safetensors'; Size = 7343591088 },
    @{ Path = 'models\vae\flux2-vae_small.safetensors'; Size = 249521340 }
)
if ($SkipModels) {
    Write-Host '[4/5] 跳过模型下载（-SkipModels）'
} else {
    Write-Host '[4/5] 下载 MOSS-Image 量化权重，共约 12.1GB（Ctrl+C 后重跑会续传）'
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

# 5. 桌面启动器
if ($NoDesktopShortcut) {
    Write-Host '[5/5] 跳过桌面启动器（-NoDesktopShortcut）'
} else {
    Write-Host '[5/5] 生成桌面启动器'
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
Write-Host '启动：双击桌面 ComfyUI-MOSS-Image.bat'
Write-Host "  或   cd `"$root`"; .\.venv\Scripts\python.exe main.py --listen 127.0.0.1 --port 8188"
Write-Host '浏览器打开 http://127.0.0.1:8188 ，工作流选 workflows/ 下的预设'

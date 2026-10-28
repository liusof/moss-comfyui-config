param(
    [switch]$SkipModels,
    [switch]$NoDesktopShortcut,
    [switch]$UseFreeze,
    [string]$ComfyRepo   = 'Comfy-Org/ComfyUI',
    [string]$ComfyCommit = '355cd6b14c92c19ac3188fe528e47a3f21ef5178',   # v0.42.0 tag
    [string]$SourceProxy = 'https://gh-proxy.com',
    [string]$PythonExe   = '',
    [string]$HfBase      = 'https://hf-mirror.com/Comfy-Org/MOSS-Image/resolve/main'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $root

Write-Host '===== ComfyUI + MOSS-Image 一键配置 ====='
Write-Host ''

# ---------------------------------------------------------------- helpers
function Get-ComfySource {
    param([string]$Url, [string]$Tar)
    # GitHub archive 经代理下载常在中途断开：curl 会非 0 退出但文件已写一半。
    # 这里用 -C - 反复续传，直到 tar 自身能完整列出内容。
    for ($round = 1; $round -le 6; $round++) {
        Write-Host "  第 $round 轮拉取/续传（已下载 $(if (Test-Path $Tar) { (Get-Item $Tar).Length } else { 0 }) 字节）"
        & curl.exe -L -C - --retry 5 --retry-delay 3 --retry-all-errors --progress-bar -o $Tar $Url
        if (-not (Test-Path $Tar)) { Start-Sleep -Seconds 2; continue }
        $size = (Get-Item $Tar).Length
        $list = & tar.exe -tzf $Tar 2>&1 | Out-String
        if (($list -notmatch 'Truncated') -and ($list -match '/main\.py')) {
            Write-Host "  源码包完整：$size 字节"
            return $true
        }
        Write-Host "  包不完整（$size 字节），续传中…"
        Start-Sleep -Seconds 2
    }
    return $false
}

function Find-Python311 {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path $Explicit)) {
        $v = (& $Explicit -c "import sys;print('%d.%d'%sys.version_info[:2])").Trim()
        if ($v -eq '3.11') { return $Explicit }
        throw "指定的 -PythonExe 不是 3.11（实际 $v）：$Explicit"
    }
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $cand = (& py -3.11 -c "import sys;print(sys.executable)" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $cand) { return $cand.Trim() }
    }
    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        try { $v = (& $cmd.Source -c "import sys;print('%d.%d'%sys.version_info[:2])").Trim() } catch { continue }
        if ($v -eq '3.11') { return $cmd.Source }
    }
    return $null
}

# ---------------------------------------------------------------- 1. 源码
if (Test-Path (Join-Path $root 'main.py')) {
    Write-Host '[1/5] ComfyUI 源码已存在，跳过下载'
} else {
    Write-Host "[1/5] 拉取 ComfyUI 源码（$ComfyRepo @ $($ComfyCommit.Substring(0,7))，约 12.7MB）"
    $tar = Join-Path $env:TEMP "comfyui-$($ComfyCommit.Substring(0,7)).tar.gz"
    $url = "$SourceProxy/https://github.com/$ComfyRepo/archive/$ComfyCommit.tar.gz"
    if (-not (Get-ComfySource -Url $url -Tar $tar)) {
        throw "源码下载失败/不完整：$url`n可手动执行：git clone --depth 1 https://github.com/$ComfyRepo.git"
    }
    $tmp = Join-Path $env:TEMP 'comfy_src_extract'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    & tar.exe -xzf $tar -C $tmp
    if ($LASTEXITCODE -ne 0) { throw '解压失败（需要 Windows 10 1803+ 自带的 tar.exe）' }
    $inner = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
    if (-not (Test-Path (Join-Path $inner 'main.py'))) { throw "解压内容异常，未找到 main.py：$inner" }
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

# ---------------------------------------------------------------- 2. venv
$venv   = Join-Path $root '.venv'
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $python)) {
    Write-Host '[2/5] 创建 Python 3.11 虚拟环境'
    $base = Find-Python311 -Explicit $PythonExe
    if (-not $base) {
        Write-Host ''
        Write-Host '未找到 Python 3.11（ComfyUI 0.42 与 cu130 wheel 都锁 3.11）。请安装后重新运行：'
        Write-Host '  https://www.python.org/downloads/release/python-3119/'
        Write-Host '安装时勾选 "Add python.exe to PATH"，或用 -PythonExe 指定路径。'
        exit 1
    }
    Write-Host "  使用 $base"
    & $base -m venv $venv
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $python)) { throw '创建虚拟环境失败' }
} else {
    Write-Host '[2/5] 复用已有 .venv'
}

# ---------------------------------------------------------------- 3. 依赖
Write-Host '[3/5] 安装 Python 依赖（torch 约 3GB，首次较慢）'
& $python -m pip install --upgrade pip --timeout 60 --retries 10
if ($LASTEXITCODE -ne 0) { throw 'pip 升级失败，检查网络后重跑本脚本' }
& $python -m pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu130 --timeout 120 --retries 20
if ($LASTEXITCODE -ne 0) { throw 'PyTorch 安装失败，重跑会复用已下载缓存' }

$freeze = Join-Path $root 'config\pip-freeze.txt'
if ($UseFreeze -and (Test-Path $freeze)) {
    Write-Host '  使用 config/pip-freeze.txt 精确复现版本'
    & $python -m pip install -r $freeze --timeout 120 --retries 20
} else {
    & $python -m pip install -r requirements.txt --timeout 120 --retries 20
}
if ($LASTEXITCODE -ne 0) { throw '依赖安装失败，重跑会复用已下载缓存' }

# ---------------------------------------------------------------- 4. 权重
$models = @(
    @{ Path = 'models\diffusion_models\moss_image_sft_int8_convrot.safetensors'; Size = 5413698958 },
    @{ Path = 'models\text_encoders\qwen3.5_9b_w4a8_gptq.safetensors';          Size = 7343591088 },
    @{ Path = 'models\vae\flux2-vae_small.safetensors';                          Size = 249521340 }
)
if ($SkipModels) {
    Write-Host '[4/5] 跳过模型下载（-SkipModels）'
} else {
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ramGB -lt 24) {
        Write-Host "  [警告] 本机内存 ${ramGB}GB：UNET 5.4GB + 文本编码器 7.3GB 需要 offload，建议 32GB 以上，否则易 OOM"
    }
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

# ---------------------------------------------------------------- 5. 启动器
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
Write-Host '链路自检：powershell -ExecutionPolicy Bypass -File .\verify_chain.ps1'

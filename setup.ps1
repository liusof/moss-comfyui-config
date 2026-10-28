param(
    [switch]$SkipModels,
    [switch]$NoDesktopShortcut,
    [switch]$UseFreeze,
    [string]$ComfyRepo   = 'Comfy-Org/ComfyUI',
    [string]$ComfyCommit = '355cd6b14c92c19ac3188fe528e47a3f21ef5178',   # v0.42.0 tag
    [string]$SourceProxy = 'https://gh-proxy.com',
    [string]$PythonExe   = '',
    [string]$HfBase      = 'https://hf-mirror.com/Comfy-Org/MOSS-Image/resolve/main',
    # HF 镜像按顺序回退（hf-mirror 偶发 connect timeout / connection reset）
    [string[]]$HfMirrors = @(
        'https://hf-mirror.com/Comfy-Org/MOSS-Image/resolve/main',
        'https://huggingface.co/Comfy-Org/MOSS-Image/resolve/main'
    ),
    [string]$TorchIndex  = 'https://download.pytorch.org/whl/cu130',
    # 国内镜像（实测 10.4 MB/s，官方 1.06 MB/s），按顺序回退
    [string[]]$TorchMirrors = @(
        'https://mirror.nju.edu.cn/pytorch/whl/cu130',
        'https://download.pytorch.org/whl/cu130'
    )
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $root

$PypiIndex  = 'https://pypi.org/simple'

Write-Host '===== ComfyUI + MOSS-Image 一键配置 ====='
Write-Host ''

# ---------------------------------------------------------------- helpers
function Invoke-Native {
    # 运行原生命令并把 stderr 并入 stdout，且不让 stderr 变成终止性错误。
    # 为什么需要它：$ErrorActionPreference='Stop' 时 native 命令写 stderr 会被 PowerShell
    # 判成 NativeCommandError 直接中断脚本——而"用 tar 校验包是否完整"这一步本来
    # 就需要读到 tar 的报错文本（Truncated / Error opening archive）。
    param([string]$Exe, [string[]]$ArgList)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @ArgList 2>&1 | ForEach-Object { [string]$_ }
    } finally {
        $ErrorActionPreference = $old
    }
    return , $out
}

function Invoke-Exe {
    # 跑一个外部命令，输出直接透传给用户，并返回它的 exit code。
    # 必须在 EAP='Stop' 下把 EAP 临时降成 'Continue'：Windows PowerShell 5.1 里，
    # native 命令只要往 stderr 写一行（哪怕只是一条 warning），PowerShell 就会
    # 抛 RemoteException 直接中断脚本。实测 pip 的 "WARNING: You are using pip
    # version ..." 和 curl 的 --progress-bar（进度条走 stderr）都会踩这个坑。
    #
    # 注意：输出必须写到真正的 stdout 句柄，不能留在 PowerShell 管道里。
    # 早先版本用 `& $Exe @ArgList` 直接输出，函数返回的是「输出行 + exit code」
    # 组成的数组，于是 `(Invoke-Exe ...) -ne 0` 拿数组跟 0 比、恒为真，
    # pip 明明 exit 0 却被判定成失败。这里用 ForEach-Object 把每行写进
    # [Console]::Out（管道本身不产生输出），函数就只返回 exit code。
    param([string]$Exe, [string[]]$ArgList)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 关键：`2>&1` 在 PowerShell 里把 stderr 变成 error record，
        # 只要有一行就可能触发 NativeCommandError 噪音。这里不走管道，
        # 而是让 native 命令自己写 stderr（进度条就靠它），
        # 只把 stdout 逐行透传。
        & $Exe @ArgList | ForEach-Object { [Console]::Out.WriteLine([string]$_) }
        return [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
}

function Test-Archive {
    # 用 tar 自己校验压缩包：必须能完整列出条目，且含关键文件。
    param([string]$Tar)
    if (-not (Test-Path $Tar)) { return $false }
    $len = (Get-Item $Tar).Length
    if ($len -lt 1000000) {
        Write-Host "  包太小（$len 字节），判为不完整"
        return $false
    }
    $out = Invoke-Native tar.exe @('-tzf', $Tar)
    $code = $LASTEXITCODE
    $text = ($out -join "`n")
    if ($code -ne 0 -or $text -match 'Truncated|truncated|unexpected end|Error opening archive') {
        Write-Host "  tar 校验未通过（exit=$code）"
        return $false
    }
    foreach ($need in @('main.py', 'requirements.txt', 'nodes.py')) {
        if ($text -notmatch [regex]::Escape($need)) {
            Write-Host "  包内缺少 $need"
            return $false
        }
    }
    return $true
}

function Get-ComfySource {
    # GitHub archive 经代理下载常在中途断开，而 curl 对"HTTP 200 但流被切断"不报错。
    # 关键：gh-proxy 与 codeload 都不支持 HTTP Range（-r 被忽略，-C - 直接报
    # curl: (33) HTTP server does not seem to support byte ranges），所以"续传"这条路
    # 在 GitHub archive 上走不通。正确做法是：多源轮询 + 每次全新下载 + tar 完整性校验。
    param([string]$Tar, [string[]]$Urls, [int]$MaxRounds = 6)
    for ($round = 1; $round -le $MaxRounds; $round++) {
        foreach ($u in $Urls) {
            # 两个 curl 变体：正常版，以及带 --ssl-no-revoke 的兜底版
            # （Windows Schannel 在吊销服务器不可达时会整片失败）
            foreach ($variant in @(0, 1)) {
                if (Test-Path $Tar) { Remove-Item $Tar -Force }
                $curlArgs = @('-L', '--retry', '5', '--retry-delay', '3', '--retry-all-errors',
                              '--connect-timeout', '30', '--max-time', '900', '-sS')
                if ($variant -eq 1) { $curlArgs += '--ssl-no-revoke' }
                $curlArgs += @('-o', $Tar, $u)
                Write-Host "  第 $round 轮：$u$(if ($variant -eq 1) { '（--ssl-no-revoke）' })"
                $null = Invoke-Native curl.exe $curlArgs
                if (Test-Path $Tar) {
                    $sz = (Get-Item $Tar).Length
                    if (Test-Archive $Tar) {
                        Write-Host "  源码包完整：$sz 字节"
                        return $true
                    }
                    Write-Host "  包不完整（$sz 字节），换源重试…"
                } else {
                    Write-Host '  未产生文件，换源重试…'
                }
            }
        }
    }
    return $false
}

function Find-Python311 {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path $Explicit)) {
        $v = (Invoke-Native $Explicit @('-c', "import sys;print('%d.%d'%sys.version_info[:2])")) -join ''
        $v = $v.Trim()
        if ($v -eq '3.11') { return $Explicit }
        throw "指定的 -PythonExe 不是 3.11（实际 $v）：$Explicit"
    }
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $cand = (Invoke-Native py @('-3.11', '-c', 'import sys;print(sys.executable)')) -join ''
        if ($LASTEXITCODE -eq 0 -and $cand.Trim()) { return $cand.Trim() }
    }
    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $v = (Invoke-Native $cmd.Source @('-c', "import sys;print('%d.%d'%sys.version_info[:2])")) -join ''
        $v = $v.Trim()
        if ($v -eq '3.11') { return $cmd.Source }
    }
    return $null
}

function Merge-GitIgnore {
    # ComfyUI 自带的 .gitignore 正好忽略 /models/ /output/ /input/ /user/ .venv/ /custom_nodes/
    # 等我们会在部署时生成的大目录。直接覆盖会丢掉仓库自己的规则，所以做"并集合并"。
    param([string]$Src, [string]$Dst)
    $existing = @()
    if (Test-Path $Dst) { $existing = @(Get-Content $Dst -ErrorAction SilentlyContinue) }
    $incoming = @(Get-Content $Src -ErrorAction SilentlyContinue)
    $merged = @()
    foreach ($line in ($existing + $incoming)) {
        if ($null -eq $line) { continue }
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($merged -notcontains $t) { $merged += $t }
    }
    $head = @('# ComfyUI + MOSS-Image 部署目录忽略规则')
    [IO.File]::WriteAllText($Dst, (($head + $merged) -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Wheel {
    # 用 curl 把 wheel 拉到本地（多镜像回退 + 断点续传 + 字节数校验），
    # 再交给 pip 从本地文件装。
    # 为什么不用 pip 直接下载：pip 从 download.pytorch.org 拉 1990MB 的
    # torch wheel 实测只有 1.06 MB/s（≈31 分钟），而 mirror.nju.edu.cn
    # 是 10.4 MB/s（≈3 分钟），同一个 wheel（sha256 一致）。
    param(
        [string]$FileName,   # URL 里的名字，例如 torch-2.14.1%2Bcu130-cp311-cp311-win_amd64.whl
        [long]$Size,         # 预期字节数
        [string]$DestDir,
        [string]$Sha256      # 可选：预期 sha256
    )
    # URL 里的 %2B 是 '+' 的百分号编码，但 pip 要求磁盘上的文件名里是字面量 '+'，
    # 否则报 "Invalid wheel filename (invalid version): torch-2.14.1%2Bcu130-..."
    $localName = [System.Uri]::UnescapeDataString($FileName)
    $dest = Join-Path $DestDir $localName
    if (Test-Path $dest) {
        $cur = (Get-Item $dest).Length
        if ($cur -eq $Size) {
            Write-Host "  已存在且完整：$localName"
            return $dest
        }
        if ($cur -gt $Size) { Remove-Item $dest -Force }
    }
    foreach ($m in $TorchMirrors) {
        $url = "$m/$FileName"
        Write-Host "  下载 $localName ← $m"
        # -C - 断点续传；--retry-all-errors 让断流也重试
        $null = Invoke-Exe curl.exe @('-L', '-C', '-', '--retry', '20', '--retry-delay', '3',
            '--retry-all-errors', '--connect-timeout', '30', '--max-time', '3600',
            '--progress-bar', '-o', $dest, $url)
        if (Test-Path $dest) {
            $cur = (Get-Item $dest).Length
            if ($cur -eq $Size) {
                if ($Sha256) {
                    $got = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
                    if ($got -ne $Sha256.ToLower()) {
                        Write-Host "  sha256 不匹配（期望 $($Sha256.ToLower())，实际 $got），换下一个镜像"
                        Remove-Item $dest -Force
                        continue
                    }
                    Write-Host "  sha256 校验通过"
                }
                return $dest
            }
            Write-Host "  字节数不符（$cur / $Size），换下一个镜像"
        } else {
            Write-Host '  下载失败，换下一个镜像'
        }
    }
    throw "wheel 下载失败：$localName（预期 $Size 字节），可重跑本脚本续传"
}

function Set-FrontendVersion {
    # Comfy.InstalledVersion = "首次安装时运行的前端版本"，前端用它做版本化默认值
    # （defaultsByInstallVersion）。仓库里原本硬编码 1.57.1，但默认 requirements.txt
    # 装的是 comfyui-frontend-package 1.55.18，两者不一致。这里按实际装到的版本写回。
    param([string]$SettingsFile, [string]$Python)
    if (-not (Test-Path $SettingsFile)) { return }
    try {
        $ver = (Invoke-Native $Python @('-c', "import importlib.metadata as m;print(m.version('comfyui-frontend-package'))")) -join ''
        $ver = $ver.Trim()
        if (-not $ver) { return }
        $json = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if ($json.'Comfy.InstalledVersion' -eq $ver) { return }
        $json.'Comfy.InstalledVersion' = $ver
        # 必须写成无 BOM 的 UTF-8：ComfyUI 用 json.load(open(f)) 读这个文件，
        # 带 BOM 会直接抛 "Expecting value: line 1 column 1"。
        $out = ($json | ConvertTo-Json -Depth 5) -replace "`r?`n", "`r`n"
        [IO.File]::WriteAllText($SettingsFile, $out, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  已同步 Comfy.InstalledVersion = $ver"
    } catch {
        Write-Host "  [提示] 同步前端版本失败（不影响使用）：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- 1. 源码
if (Test-Path (Join-Path $root 'main.py')) {
    Write-Host '[1/5] ComfyUI 源码已存在，跳过下载'
} else {
    Write-Host "[1/5] 拉取 ComfyUI 源码（$ComfyRepo @ $($ComfyCommit.Substring(0,7))，约 12.7MB）"
    $tar = Join-Path $env:TEMP "comfyui-$($ComfyCommit.Substring(0,7)).tar.gz"
    # 备选源：代理 → codeload 直连 → github 直连（会 302 到 codeload）
    $urls = @(
        "$SourceProxy/https://github.com/$ComfyRepo/archive/$ComfyCommit.tar.gz",
        "https://codeload.github.com/$ComfyRepo/tar.gz/$ComfyCommit",
        "https://github.com/$ComfyRepo/archive/$ComfyCommit.tar.gz"
    )
    if (-not (Get-ComfySource -Tar $tar -Urls $urls)) {
        throw "源码下载失败/不完整。`n可手动执行：git clone --depth 1 https://github.com/$ComfyRepo.git`n再把内容拷到本目录。"
    }
    $tmp = Join-Path $env:TEMP "comfy_src_extract_$PID"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $null = Invoke-Native tar.exe @('-xzf', $tar, '-C', $tmp, '--strip-components', '1')
    if ($LASTEXITCODE -ne 0) { throw '解压失败（需要 Windows 10 1803+ 自带的 tar.exe）' }
    if (-not (Test-Path (Join-Path $tmp 'main.py'))) { throw "解压内容异常，未找到 main.py：$tmp" }

    # ComfyUI 自带的 README.md 改名保存，别盖掉本仓库的 README
    if (Test-Path (Join-Path $tmp 'README.md')) {
        Move-Item (Join-Path $tmp 'README.md') (Join-Path $root 'README.comfyui.md') -Force
    }
    # 上游 CI 配置与本仓库无关，去掉
    if (Test-Path (Join-Path $tmp '.github')) { Remove-Item (Join-Path $tmp '.github') -Recurse -Force }
    # .gitignore 做并集合并（保留仓库自己的规则 + ComfyUI 的 models/user/.venv 等）
    if (Test-Path (Join-Path $tmp '.gitignore')) {
        Merge-GitIgnore -Src (Join-Path $tmp '.gitignore') -Dst (Join-Path $root '.gitignore')
        Remove-Item (Join-Path $tmp '.gitignore') -Force
    }
    # 用"合并"而不是"整体搬运"：models/ 等目录若已有权重文件，Copy-Item 会保留已有文件
    # （Move-Item 在目标同名目录已存在时会直接报错 "Cannot create a file when that file already exists"）
    Get-ChildItem $tmp -Force | Copy-Item -Destination $root -Recurse -Force
    Remove-Item $tmp -Recurse -Force
    Write-Host '  源码已解包到当前目录'
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
    if ((Invoke-Exe $base @('-m', 'venv', $venv)) -ne 0 -or -not (Test-Path $python)) { throw '创建虚拟环境失败' }
} else {
    Write-Host '[2/5] 复用已有 .venv'
}

# ---------------------------------------------------------------- 3. 依赖
Write-Host '[3/5] 安装 Python 依赖（torch 约 2GB，首次较慢）'
if ((Invoke-Exe $python @('-m', 'pip', 'install', '--upgrade', 'pip', '--timeout', '60', '--retries', '10')) -ne 0) {
    throw 'pip 升级失败，检查网络后重跑本脚本'
}

# torch/torchvision 的 cu130 本地版本号（+cu130）在 PyPI 上不存在，只能从
# pytorch 索引拿。这里先自己用 curl 把 wheel 拉到本地（镜像回退 + 续传），
# 再让 pip 从本地文件装 —— 因为 pip 直接从官方索引拉 1990MB 只有 1MB/s。
$wheelDir = Join-Path $root '.wheels'
if (-not (Test-Path $wheelDir)) { New-Item -ItemType Directory -Path $wheelDir -Force | Out-Null }
$torchWheel       = Get-Wheel -FileName 'torch-2.14.1%2Bcu130-cp311-cp311-win_amd64.whl'     -Size 1990594787 -DestDir $wheelDir -Sha256 'e98711737150b5a6451cbbfdb425abd5d1bea77f4a1a5d29c48d5ec41cd54949'
$torchvisionWheel = Get-Wheel -FileName 'torchvision-0.29.1%2Bcu130-cp311-cp311-win_amd64.whl' -Size 6566156   -DestDir $wheelDir -Sha256 '08f02295d26ccb2054cafc8c21feacf9022384d5a0cd006fbbf1d59623af7522'

# torch 的传递依赖（filelock/sympy/networkx/jinja2/fsspec/typing-extensions/setuptools）
# 在 pytorch 索引里都有对应条目，所以不需要额外加 PyPI 索引。
if ((Invoke-Exe $python @('-m', 'pip', 'install', $torchWheel, $torchvisionWheel,
                       '--index-url', $TorchIndex, '--timeout', '120', '--retries', '20')) -ne 0) {
    throw 'PyTorch 安装失败，重跑会复用已下载的 wheel'
}

$freeze = Join-Path $root 'config\pip-freeze.txt'
if ($UseFreeze -and (Test-Path $freeze)) {
    Write-Host '  使用 config/pip-freeze.txt 精确复现版本'
    # freeze 里写的是 torch==2.14.1+cu130，这个版本只在 pytorch 索引里有，
    # 所以要同时给出 pytorch 索引与 PyPI 索引（其余包在 PyPI 上）。
    $rc = Invoke-Exe $python @('-m', 'pip', 'install', '-r', $freeze,
                               '--index-url', $TorchIndex, '--extra-index-url', $PypiIndex,
                               '--timeout', '120', '--retries', '20')
} else {
    $rc = Invoke-Exe $python @('-m', 'pip', 'install', '-r', 'requirements.txt', '--timeout', '120', '--retries', '20')
}
if ($rc -ne 0) { throw '依赖安装失败，重跑会复用已下载缓存' }

Set-FrontendVersion -SettingsFile (Join-Path $userDir 'comfy.settings.json') -Python $python

# ---------------------------------------------------------------- 4. 权重
# Path  = 落到 ComfyUI 目录里的位置（本地路径，含 models\ 前缀）
# HfPath= HuggingFace 仓库里的相对路径（HF 仓库根下没有 models\ 这一层！）
$models = @(
    @{ Path = 'models\diffusion_models\moss_image_sft_int8_convrot.safetensors'; HfPath = 'diffusion_models/moss_image_sft_int8_convrot.safetensors'; Size = 5413698958 },
    @{ Path = 'models\text_encoders\qwen3.5_9b_w4a8_gptq.safetensors';          HfPath = 'text_encoders/qwen3.5_9b_w4a8_gptq.safetensors';          Size = 7343591088 },
    @{ Path = 'models\vae\flux2-vae_small.safetensors';                          HfPath = 'vae/flux2-vae_small.safetensors';                          Size = 249521340 }
)
if ($SkipModels) {
    Write-Host '[4/5] 跳过模型下载（-SkipModels）'
} else {
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ramGB -lt 24) {
        Write-Host "  [警告] 本机内存 ${ramGB}GB：UNET 5.4GB + 文本编码器 7.3GB 需要 offload，建议 32GB 以上，否则易 OOM"
    }
    Write-Host '[4/5] 下载 MOSS-Image 量化权重，共约 12.1GB（Ctrl+C 后重跑会续传）'
    # -HfBase 指定的镜像排在最前，其余备用镜像依次回退
    $mirrorList = @($HfBase) + @($HfMirrors | Where-Object { $_ -ne $HfBase })
    foreach ($m in $models) {
        $out = Join-Path $root $m.Path
        $dir = Split-Path -Parent $out
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path $out) {
            $cur = (Get-Item $out).Length
            if ($cur -eq $m.Size) {
                Write-Host "  已完整：$($m.Path)"
                continue
            }
            # 小于 1MB 的残片基本是错误页/代理占位，不能拿来续传
            if ($cur -lt 1MB -or $cur -gt $m.Size) {
                Write-Host "  移除异常文件（$cur 字节，预期 $($m.Size)）"
                Remove-Item $out -Force
            }
        }
        Write-Host "  下载 $($m.Path)"
        $ok = $false
        foreach ($base in $mirrorList) {
            $url = $base + '/' + $m.HfPath
            Write-Host "    源：$base"
            # hf-mirror 支持 HTTP Range，所以权重可以用 -C - 续传（与 GitHub archive 不同）
            # 注意 curl 的 --progress-bar 把进度条写进 stderr，必须走 Invoke-Exe。
            $null = Invoke-Exe curl.exe @('-L', '-C', '-', '--retry', '10', '--retry-delay', '5',
                        '--retry-all-errors', '--connect-timeout', '30', '--max-time', '7200',
                        '--progress-bar', '-o', $out, $url)
            if (-not (Test-Path $out) -or (Get-Item $out).Length -ne $m.Size) {
                Write-Host '    第一次下载不完整，用 --ssl-no-revoke 再试一次…'
                # 残片若是 HF 的 404 错误页（15 字节 "Entry not found"），必须删掉再下，
                # 否则 -C - 会从 15 字节处续传，产出永远不完整的坏文件。
                if ((Test-Path $out) -and (Get-Item $out).Length -lt 1MB) {
                    Remove-Item $out -Force
                }
                $null = Invoke-Exe curl.exe @('-L', '-C', '-', '--retry', '10', '--retry-delay', '5',
                            '--retry-all-errors', '--connect-timeout', '30', '--max-time', '7200',
                            '--ssl-no-revoke', '--progress-bar', '-o', $out, $url)
            }
            if ((Test-Path $out) -and (Get-Item $out).Length -eq $m.Size) {
                $ok = $true
                break
            }
            Write-Host '    该源未完成，尝试下一个镜像…'
        }
        if (-not $ok) {
            throw "下载不完整：$($m.Path)（期望 $($m.Size) 字节），重跑本脚本可续传"
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

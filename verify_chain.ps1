param(
    [switch]$CheckOnly,
    [string]$Root = '',
    [int]$Steps = 30,
    [double]$Cfg = 4.0,
    [int]$Port = 8188
)

# ComfyUI + MOSS-Image 链路自检
#   -CheckOnly   只做体检（节点/模型/版本），不出图
#   不带参数      体检 + 真实跑一张 1024x1024（30 steps / CFG 4 / er_sde+simple / SLG 22 0->0.5）
#   服务已在跑就直接复用；没跑则由本脚本拉起，跑完再关掉。

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
Set-Location $Root

$base = "http://127.0.0.1:$Port"
$fail = 0
$warn = 0

function Say([string]$tag, [string]$msg) {
    switch ($tag) {
        'OK'   { Write-Host "  [ OK ] $msg" }
        'FAIL' { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
        'WARN' { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
        default { Write-Host "  ...    $msg" }
    }
}

function Test-Up {
    try { $null = Invoke-RestMethod "$base/system_stats" -TimeoutSec 3; return $true } catch { return $false }
}

Write-Host '===== MOSS-Image 链路自检 ====='
Write-Host "工作目录: $Root"

# ---------------------------------------------------------------- 0. 服务
$owned = $false
$proc = $null
if (Test-Up) {
    Say INFO "8188 已有服务在跑，直接复用"
} else {
    $py = Join-Path $Root '.venv\Scripts\python.exe'
    if (-not (Test-Path (Join-Path $Root 'main.py'))) { Say FAIL "找不到 main.py：$Root（先跑 setup.ps1，或用 -Root 指定安装目录）"; exit 1 }
    if (-not (Test-Path $py)) { Say FAIL "找不到 .venv\Scripts\python.exe：$Root"; exit 1 }
    Say INFO '拉 ComfyUI 服务…'
    # 把服务输出落到日志文件：启动失败时只有日志能说明原因
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logOut = Join-Path $Root "comfyui-$stamp.out.log"
    $logErr = Join-Path $Root "comfyui-$stamp.err.log"
    $proc = Start-Process -FilePath $py -ArgumentList 'main.py', '--listen', '127.0.0.1', '--port', $Port -WorkingDirectory $Root -PassThru -RedirectStandardOutput $logOut -RedirectStandardError $logErr
    $owned = $true
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 300) {
        if ($proc.HasExited) {
            Say FAIL "服务启动即退出，rc=$($proc.ExitCode)"
            Say INFO "日志：$logErr"
            if (Test-Path $logErr) { Get-Content $logErr -Tail 30 | ForEach-Object { Say INFO "  $_" } }
            exit 1
        }
        if (Test-Up) { break }
        Start-Sleep -Seconds 2
    }
    if (-not (Test-Up)) {
        Say FAIL '300s 内服务未就绪'
        Say INFO "日志：$logErr"
        if (Test-Path $logErr) { Get-Content $logErr -Tail 30 | ForEach-Object { Say INFO "  $_" } }
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
        exit 1
    }
    Say OK ("服务就绪，用时 {0:N0}s" -f ((Get-Date) - $t0).TotalSeconds)
}

try {
    # ------------------------------------------------------------ 1. 运行时
    $st = Invoke-RestMethod "$base/system_stats" -TimeoutSec 10
    $sys = $st.system
    Say INFO "ComfyUI $($sys.comfyui_version) / Python $($sys.python_version.Split(' ')[0]) / torch $($sys.pytorch_version)"
    Say INFO "$($st.devices[0].name) / vram_total $([math]::Round($st.devices[0].vram_total/1MB)) MB / vram_free $([math]::Round($st.devices[0].vram_free/1MB)) MB"
    if ($sys.pytorch_version -notmatch 'cu\d+') { Say WARN 'torch 不是 CUDA 版本，会在 CPU 上跑' ; $warn++ }

    # ------------------------------------------------------------ 2. 节点
    Say INFO '拉 /object_info…'
    $oi = Invoke-RestMethod "$base/object_info" -TimeoutSec 120
    $critical = @('UNETLoader','CLIPLoader','VAELoader','CLIPTextEncode','EmptyFlux2LatentImage','KSampler','VAEDecode','SaveImage','ResolutionSelector','SkipLayerGuidanceDiTSimple','TextGenerate','ComfySwitchNode')
    $optional = @('PrimitiveStringMultiline','PreviewAny','MOSSImageLayoutPrompt')
    foreach ($n in $critical) {
        if ($oi.PSObject.Properties.Name -contains $n) { Say OK "节点 $n" } else { Say FAIL "缺节点 $n"; $fail++ }
    }
    foreach ($n in $optional) {
        if ($oi.PSObject.Properties.Name -contains $n) { Say OK "节点 $n（可选）" } else { Say WARN "缺可选节点 $n"; $warn++ }
    }

    # ------------------------------------------------------------ 3. 权重索引
    $want = @{
        'UNETLoader' = @('unet_name', 'moss_image_sft_int8_convrot.safetensors')
        'CLIPLoader' = @('clip_name',    'qwen3.5_9b_w4a8_gptq.safetensors')
        'VAELoader'  = @('vae_name',              'flux2-vae_small.safetensors')
    }
    foreach ($k in $want.Keys) {
        $field = $want[$k][0]; $file = $want[$k][1]
        $nodeProp = $oi.PSObject.Properties[$k]
        $flat = @()
        if ($nodeProp) {
            $reqProp = $nodeProp.Value.input.required
            if ($reqProp) {
                $fieldProp = $reqProp.PSObject.Properties[$field]
                if ($fieldProp) { $flat = @($fieldProp.Value[0]) }
            }
        }
        if ($flat -contains $file) { Say OK "$k 已索引 $file" } else { Say FAIL "$k 下拉里没有 $file（候选 $($flat.Count) 项）"; $fail++ }
    }
    $clipTypes = @($oi.PSObject.Properties['CLIPLoader'].Value.input.required.PSObject.Properties['type'].Value[0])
    if ($clipTypes -contains 'moss_image') { Say OK 'CLIPLoader 支持 type=moss_image' } else { Say FAIL 'CLIPLoader 不支持 moss_image'; $fail++ }

    # 文件级核对
    $sizes = @{
        'models\diffusion_models\moss_image_sft_int8_convrot.safetensors' = 5413698958
        'models\text_encoders\qwen3.5_9b_w4a8_gptq.safetensors'           = 7343591088
        'models\vae\flux2-vae_small.safetensors'                          = 249521340
    }
    foreach ($rel in $sizes.Keys) {
        $p = Join-Path $Root $rel
        if (-not (Test-Path $p)) { Say FAIL "缺权重 $rel"; $fail++; continue }
        $len = (Get-Item $p).Length
        if ($len -eq $sizes[$rel]) { Say OK "权重 $([IO.Path]::GetFileName($rel)) $len 字节" }
        else { Say FAIL "权重大小不符 $([IO.Path]::GetFileName($rel))：$len ≠ $($sizes[$rel])"; $fail++ }
    }

    if ($CheckOnly) {
        Write-Host ''
        Write-Host "===== 体检结果：FAIL=$fail WARN=$warn ====="
        exit ([int]($fail -gt 0))
    }

    # ------------------------------------------------------------ 4. 真跑一张
    $prompt = 'Cinematic night street photograph: a model in an oversized white wool coat walking toward camera under a huge illuminated theatre marquee, the marquee bulbs spelling MOSS in tall capital letters, wet asphalt with long reflections, warm tungsten glow against cold blue night, anamorphic flare, 35mm film grain, low angle'
    $neg = 'nsfw, worst quality, bad anatomy, watermark, jpeg artifact'
    $g = [ordered]@{
        '1'  = [ordered]@{ class_type = 'UNETLoader'; inputs = [ordered]@{ unet_name = 'moss_image_sft_int8_convrot.safetensors'; weight_dtype = 'default' } }
        '2'  = [ordered]@{ class_type = 'CLIPLoader'; inputs = [ordered]@{ clip_name = 'qwen3.5_9b_w4a8_gptq.safetensors'; type = 'moss_image'; device = 'default' } }
        '3'  = [ordered]@{ class_type = 'VAELoader'; inputs = [ordered]@{ vae_name = 'flux2-vae_small.safetensors' } }
        '19' = [ordered]@{ class_type = 'ResolutionSelector'; inputs = [ordered]@{ aspect_ratio = '1:1 (Square)'; megapixels = 1.0; multiple = 16 } }
        '6'  = [ordered]@{ class_type = 'EmptyFlux2LatentImage'; inputs = [ordered]@{ width = @('19', 0); height = @('19', 1); batch_size = 1 } }
        '4'  = [ordered]@{ class_type = 'CLIPTextEncode'; inputs = [ordered]@{ clip = @('2', 0); text = $prompt } }
        '5'  = [ordered]@{ class_type = 'CLIPTextEncode'; inputs = [ordered]@{ clip = @('2', 0); text = $neg } }
        '15' = [ordered]@{ class_type = 'SkipLayerGuidanceDiTSimple'; inputs = [ordered]@{ model = @('1', 0); double_layers = ''; single_layers = '22'; start_percent = 0.0; end_percent = 0.5 } }
        '7'  = [ordered]@{ class_type = 'KSampler'; inputs = [ordered]@{ model = @('15', 0); seed = 438829726369282; steps = $Steps; cfg = $Cfg; sampler_name = 'er_sde'; scheduler = 'simple'; positive = @('4', 0); negative = @('5', 0); latent_image = @('6', 0); denoise = 1.0 } }
        '8'  = [ordered]@{ class_type = 'VAEDecode'; inputs = [ordered]@{ samples = @('7', 0); vae = @('3', 0) } }
        '9'  = [ordered]@{ class_type = 'SaveImage'; inputs = [ordered]@{ images = @('8', 0); filename_prefix = 'moss_chain_check' } }
    }
    $body = @{ prompt = $g; client_id = 'chain-check' } | ConvertTo-Json -Depth 25 -Compress
    Say INFO "提交采样：1024x1024 / $Steps steps / CFG $Cfg / er_sde+simple / SLG single_layers=22 0->0.5"
    $t1 = Get-Date
    try {
        $res = Invoke-RestMethod "$base/prompt" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
    } catch {
        $detail = ''
        if ($_.ErrorDetails) { $detail = $_.ErrorDetails.Message }
        Say FAIL "提交被拒：$($_.Exception.Message) $detail"
        exit 1
    }
    $qid = $res.prompt_id
    Say OK "已排队 prompt_id=$qid"
    $done = $null
    while (((Get-Date) - $t1).TotalSeconds -lt 1800) {
        Start-Sleep -Seconds 5
        # 服务中途死掉时必须立刻报出来，否则会在轮询里空转到 30 分钟
        if ($owned -and $proc -and $proc.HasExited) {
            Say FAIL "服务在采样过程中退出，rc=$($proc.ExitCode)（已跑 $([math]::Round(((Get-Date) - $t1).TotalSeconds))s）"
            if (Test-Path $logErr) {
                Say INFO "日志尾部：$logErr"
                Get-Content $logErr -Tail 25 | ForEach-Object { Say INFO "  $_" }
            }
            exit 1
        }
        try { $h = Invoke-RestMethod "$base/history/$qid" -TimeoutSec 20 } catch { continue }
        if ($h.PSObject.Properties.Name -contains $qid) { $done = $h.$qid; break }
        $el = [math]::Round(((Get-Date) - $t1).TotalSeconds)
        if ($el % 60 -lt 6) { Say INFO "运行中… ${el}s" }
    }
    if (-not $done) {
        Say FAIL '30 分钟未完成（可能 OOM 或卡在加载）'
        exit 1
    }
    $secs = [math]::Round(((Get-Date) - $t1).TotalSeconds, 1)
    if ($done.status.status_str -eq 'success') {
        Say OK "采样完成，总耗时 ${secs}s"
        $imgs = @($done.outputs.'9'.images)
        foreach ($im in $imgs) {
            $p = Join-Path $Root "output\$($im.subfolder)\$($im.filename)".Replace('\\', '\')
            if (Test-Path $p) {
                $len = (Get-Item $p).Length
                Add-Type -AssemblyName System.Drawing
                $bmp = [System.Drawing.Image]::FromFile($p)
                Say OK "出图 $($im.filename) $($bmp.Width)x$($bmp.Height) $len 字节"
                $bmp.Dispose()
            } else {
                Say WARN "历史里有 $($im.filename)，但磁盘找不到 $p"
                $warn++
            }
        }
    } else {
        Say FAIL "执行失败：$($done.status | ConvertTo-Json -Depth 6 -Compress)"
        $fail++
    }
}
finally {
    if ($owned -and $proc -and -not $proc.HasExited) {
        Say INFO '关闭本脚本拉起的服务'
        Stop-Process -Id $proc.Id -Force
    }
}

Write-Host ''
Write-Host "===== 结论：FAIL=$fail WARN=$warn ====="
if ($fail -eq 0) { Write-Host '链路可用。' } else { Write-Host '链路存在阻断项，见上面 [FAIL]。' }
exit ([int]($fail -gt 0))

# ComfyUI + MOSS-Image 快照（开箱即用）

ComfyUI `0.42.0`（commit `bc5f880`）+ MOSS-Image 量化权重配置，适配 8GB 显存笔记本。
解压后跑一条命令即可完成环境安装与模型下载，无需手工改任何配置。

## 三步搞定

**1. 下载**（把 `<TOKEN>` 换成你的 GitHub PAT）

```powershell
Invoke-WebRequest -Uri "https://api.github.com/repos/liusof/moss-comfyui-config/contents/ComfyUI-MOSS-Image-snapshot.zip" `
  -Headers @{ Authorization = "token <TOKEN>"; Accept = "application/vnd.github.raw" } `
  -OutFile ComfyUI-MOSS-Image-snapshot.zip
```

```bash
curl -L -H "Authorization: token <TOKEN>" -H "Accept: application/vnd.github.raw" \
  -o ComfyUI-MOSS-Image-snapshot.zip \
  https://api.github.com/repos/liusof/moss-comfyui-config/contents/ComfyUI-MOSS-Image-snapshot.zip
```

**2. 解压**

```powershell
Expand-Archive .\ComfyUI-MOSS-Image-snapshot.zip -DestinationPath D:\Programs\ComfyUI
```

**3. 一键部署**

```powershell
cd D:\Programs\ComfyUI
.\一键部署.bat
```

等价命令行：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

脚本会自动：建 Python 3.11 虚拟环境 → 装 PyTorch 2.14.1+cu130 → 装 `requirements.txt` → 从 hf-mirror 下载三个权重（12.1GB，断点续传，可中断重跑）。

- 只要环境和代码、暂不下模型：`.\一键部署.bat` 无法传参，改用 `powershell -ExecutionPolicy Bypass -File .\setup.ps1 -SkipModels`
- 前置条件：本机已装 Python 3.11（安装时勾选 Add to PATH），Windows 10 1803+ 自带的 `curl.exe`

## 启动

双击 `start_comfyui.bat`，浏览器打开 http://127.0.0.1:8188
工作流模板选 **Text to Image (MOSS-Image)**。提示词上采样器需要精确文字时 bypass。

## 快照内容

- ComfyUI 源码（1324 个文件，与本机一致，未改动）
- `user/default/comfy.settings.json` 用户配置
- `start_comfyui.bat`、`setup.ps1`、`一键部署.bat`
- `pip-freeze.txt`（84 个包的确切版本）
- `models/` 占位结构与 configs，不含 12.1GB 权重
- 不含 `.venv/`、`output/`、`temp/`、`.git/`

## 实测参数（RTX 5070 Laptop 8GB，seed 42，batch 1）

| 场景 | 分辨率 | steps | CFG | 采样器/调度 | 耗时 | 峰值显存 |
|---|---|---|---|---|---|---|
| 日常 | 1024×1024 | 25 | 2.5 | er_sde / simple | 24.6s | 6832 MB |
| 高质量 | 1024×1024 | 50 | 3.0 | euler / simple | 48.1s | 6674 MB |

SLG：`single_layers=22`、`start=0`、`end=0.5`，`double_layers` 留空；
负面提示词 `nsfw, worst quality, bad anatomy, watermark, jpeg artifact`；
分辨率不超过 1536×1536；显存不足时给 `main.py` 加 `--lowvram`（文本编码器走 CPU）。

## 模型来源

`https://hf-mirror.com/Comfy-Org/MOSS-Image`（上游 `huggingface.co/Comfy-Org/MOSS-Image`）：

| 路径 | 字节数 |
|---|---|
| `models/diffusion_models/moss_image_sft_int8_convrot.safetensors` | 5413698958 |
| `models/text_encoders/qwen3.5_9b_w4a8_gptq.safetensors` | 7343591088 |
| `models/vae/flux2-vae_small.safetensors` | 249521340 |

## 许可

ComfyUI 源码遵循 GPL-3.0；MOSS-Image 权重与代码版权归 OpenMOSS 团队，请遵守上游许可。

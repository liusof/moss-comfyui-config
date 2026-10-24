# moss-comfyui-config

本机 `D:\Programs\ComfyUI` 的只读打包快照：ComfyUI `0.42.0`（commit `bc5f880`）+ MOSS-Image 量化权重配置（8GB 显存可跑）。
因 `github.com:443` 不可达，改用 GitHub REST API 上传，仓库内以 **快照压缩包** 形式托管。

## 下载

文件：`ComfyUI-MOSS-Image-snapshot.zip`
SHA-256：`4CC4B51FC0FC36139FF24DF05ADBBD9E8842AA7BEE5BB10FBFB497678CD67912`

私有库需带 token，以下任选一条（把 `<TOKEN>` 换成你的 GitHub PAT）：

```powershell
# PowerShell
Invoke-WebRequest -Uri "https://api.github.com/repos/liusof/moss-comfyui-config/contents/ComfyUI-MOSS-Image-snapshot.zip" `
  -Headers @{ Authorization = "token <TOKEN>"; Accept = "application/vnd.github.raw" } `
  -OutFile ComfyUI-MOSS-Image-snapshot.zip
```

```bash
# curl / Git Bash / WSL
curl -L -H "Authorization: token <TOKEN>" -H "Accept: application/vnd.github.raw" \
  -o ComfyUI-MOSS-Image-snapshot.zip \
  https://api.github.com/repos/liusof/moss-comfyui-config/contents/ComfyUI-MOSS-Image-snapshot.zip
```

网络允许直连 github.com 时也可以克隆：

```bash
git clone https://github.com/liusof/moss-comfyui-config.git
```

## 解压后恢复

```powershell
Expand-Archive .\ComfyUI-MOSS-Image-snapshot.zip -DestinationPath D:\Programs\ComfyUI-snapshot
cd D:\Programs\ComfyUI-snapshot
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.ps1` 会：创建 Python 3.11 虚拟环境 → 安装 torch 2.14.1+cu130 与 `requirements.txt` → 从 hf-mirror 下载三个 MOSS-Image 权重（约 12.1GB，支持断点续传）。

只要代码和配置：`setup.ps1 -SkipModels`。

启动：双击 `start_comfyui.bat`，或

```powershell
.\.venv\Scripts\python.exe main.py --listen 127.0.0.1 --port 8188
```

## 快照内容

- ComfyUI 源码（1323 个文件，与本机完全一致，未改动）
- `user/default/comfy.settings.json` 用户配置
- `start_comfyui.bat`、`setup.ps1`
- `pip-freeze.txt`（84 个包的确切版本）
- `models/` 占位结构与 configs yaml，不含 12.1GB 权重
- 不含 `.venv/`、`output/`、`temp/`、`.git/`

## 实测参数（RTX 5070 Laptop 8GB）

| 场景 | 分辨率 | steps | CFG | 采样器/调度 | 耗时 | 峰值显存 |
|---|---|---|---|---|---|---|
| 日常 | 1024×1024 | 25 | 2.5 | er_sde / simple | 24.6s | 6832 MB |
| 高质量 | 1024×1024 | 50 | 3.0 | euler / simple | 48.1s | 6674 MB |

SLG：`single_layers=22`、`start=0`、`end=0.5`，`double_layers` 留空；负面提示词 `nsfw, worst quality, bad anatomy, watermark, jpeg artifact`；分辨率不超过 1536×1536，OOM 时加 `--lowvram`。

## 模型来源

`https://hf-mirror.com/Comfy-Org/MOSS-Image`（上游 `huggingface.co/Comfy-Org/MOSS-Image`）：

| 路径 | 字节数 |
|---|---|
| `models/diffusion_models/moss_image_sft_int8_convrot.safetensors` | 5413698958 |
| `models/text_encoders/qwen3.5_9b_w4a8_gptq.safetensors` | 7343591088 |
| `models/vae/flux2-vae_small.safetensors` | 249521340 |

## 许可

ComfyUI 源码遵循 GPL-3.0；MOSS-Image 权重与代码版权归 OpenMOSS 团队，请遵守上游许可。

# moss-comfyui-config

ComfyUI `0.42.0`（commit `bc5f880`）+ MOSS-Image 量化权重的完整配置仓库，8GB 显存笔记本实测可用。
`git clone` 下来就是完整源码树，跑一条命令完成环境与模型，最后双击桌面图标启动。

## 三行命令

```powershell
git clone https://github.com/liusof/moss-comfyui-config.git
cd moss-comfyui-config
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

私有库需要认证：把 URL 换成 `https://<用户名>:<PAT>@github.com/liusof/moss-comfyui-config.git`，或先加为协作者。

执行完会：

1. 建 Python 3.11 虚拟环境（`.venv`）
2. 装 PyTorch 2.14.1+cu130（约 3GB）
3. 装 `requirements.txt` 全部依赖
4. 从 hf-mirror 下载三个 MOSS-Image 权重（12.1GB，断点续传）
5. 在桌面生成 `ComfyUI-MOSS-Image.bat`

之后**双击桌面那个 bat** 就能启动，浏览器自动打开 http://127.0.0.1:8188，工作流模板选 **Text to Image (MOSS-Image)**。

## 分步执行（可选）

只要环境不要模型：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -SkipModels
```

只下模型（在仓库根目录，三条命令，`-C -` 断点续传，中断后重跑继续）：

```powershell
curl.exe -L -C - --retry 10 --retry-delay 5 --retry-all-errors `
  -o models\diffusion_models\moss_image_sft_int8_convrot.safetensors `
  https://hf-mirror.com/Comfy-Org/MOSS-Image/resolve/main/diffusion_models/moss_image_sft_int8_convrot.safetensors

curl.exe -L -C - --retry 10 --retry-delay 5 --retry-all-errors `
  -o models\text_encoders\qwen3.5_9b_w4a8_gptq.safetensors `
  https://hf-mirror.com/Comfy-Org/MOSS-Image/resolve/main/text_encoders/qwen3.5_9b_w4a8_gptq.safetensors

curl.exe -L -C - --retry 10 --retry-delay 5 --retry-all-errors `
  -o models\vae\flux2-vae_small.safetensors `
  https://hf-mirror.com/Comfy-Org/MOSS-Image/resolve/main/vae/flux2-vae_small.safetensors
```

核对大小（必须完全一致）：5413698958 / 7343591088 / 249521340。

## 仓库内容

- ComfyUI 源码（1323 个文件，与本机一致，未改动；上游 README 见 `README.comfyui.md`）
- `user/default/comfy.settings.json`：当前用户配置
- `setup.ps1`：一键部署脚本；`一键部署.bat`：双击版；`start_comfyui.bat`：前台启动
- `pip-freeze.txt`：本机 84 个包的确切版本
- `models/`：目录结构与 configs，不含 12.1GB 权重（由脚本或上面命令下载）
- 不含 `.venv/`、`output/`、`temp/`、`.git/`

## 实测参数（RTX 5070 Laptop 8GB，seed 42，batch 1）

| 场景 | 分辨率 | steps | CFG | 采样器/调度 | 耗时 | 峰值显存 |
|---|---|---|---|---|---|---|
| 日常 | 1024×1024 | 25 | 2.5 | er_sde / simple | 24.6s | 6832 MB |
| 高质量 | 1024×1024 | 50 | 3.0 | euler / simple | 48.1s | 6674 MB |

SLG：`single_layers=22`、`start=0`、`end=0.5`，`double_layers` 留空；
负面提示词 `nsfw, worst quality, bad anatomy, watermark, jpeg artifact`；
分辨率不超过 1536×1536；OOM 时给 `main.py` 加 `--lowvram`（文本编码器走 CPU）。

## 模型来源

`https://hf-mirror.com/Comfy-Org/MOSS-Image`（上游 `huggingface.co/Comfy-Org/MOSS-Image`）。

## 许可

ComfyUI 源码遵循 GPL-3.0（见 `LICENSE`）；MOSS-Image 权重与代码版权归 OpenMOSS 团队，请遵守上游许可。

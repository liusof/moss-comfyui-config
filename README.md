# moss-comfyui-config

ComfyUI `0.42.0`（commit `bc5f880`）+ MOSS-Image 量化权重的**配置仓库**：仓库里只有脚本、配置和 5 个分辨率工作流，ComfyUI 源码由 `setup.ps1` 按固定 commit 拉取，clone 完跑一条命令就完成环境与模型。

## 三行命令

```powershell
git clone https://github.com/liusof/moss-comfyui-config.git
cd moss-comfyui-config
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

私有库需认证：`https://<用户名>:<PAT>@github.com/liusof/moss-comfyui-config.git`。

`setup.ps1` 依次完成：拉取 ComfyUI 源码（经 `gh-proxy.com`，可用 `-SourceProxy` 换镜像）→ 复制配置与工作流 → 建 `.venv` → 装 torch 2.14.1+cu130 与依赖 → 下载 12.1GB 权重 → 在桌面生成 `ComfyUI-MOSS-Image.bat`。

之后**双击桌面 bat** 启动，浏览器自动开 http://127.0.0.1:8188。

## 分辨率预设

`workflows/` 下有 5 个预设，`setup.ps1` 会自动复制到 `user/default/workflows/`，启动后在 ComfyUI 左侧 **Workflows** 里选。分辨率由工作流里的 `ResolutionSelector` 控制，采样固定 **30 steps / CFG 4**、er_sde + simple、SLG 22（0→0.5）、batch 1，想改就直接改对应控件。

| 文件 | 画幅 | 实际分辨率 | 30 steps 耗时 | 峰值显存 |
|---|---|---|---|---|
| `1-square-1024` | 1:1 | 1024×1024 | 约 30s（首跑 34.8s） | 6798 MB |
| `2-landscape-1536x864` | 横屏 16:9 | 1536×864 | 38.5s | 6792 MB |
| `3-portrait-864x1536` | 竖屏 9:16 | 864×1536 | 约 39s | 6792 MB |
| `4-landscape-2k-2048x1152` | 2K 横屏 16:9 | 2048×1152 | 77.7s | 6984 MB |
| `5-portrait-2k-1152x2048` | 2K 竖屏 9:16 | 1152×2048 | 约 78s | 6984 MB |

实测环境：RTX 5070 Laptop 8GB。首跑多出的几秒是模型加载/编译缓存。2K 在 8GB 上实测可跑（峰值 6.98GB），1536×1536 以上大概率 OOM。

## 分步执行（可选）

只装环境不下模型：`setup.ps1 -SkipModels`；不生成桌面启动器：`-NoDesktopShortcut`。

只下模型（仓库根目录，断点续传）：

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

核对大小：5413698958 / 7343591088 / 249521340。

## 仓库内容

```
README.md                    本说明
setup.ps1                    一键配置
一键部署.bat                  双击版 setup
start_comfyui.bat            前台启动
config/comfy-settings.json   本机 ComfyUI 用户设置
config/pip-freeze.txt        本机 84 个包的确切版本
workflows/*.json             5 个分辨率预设（含 MOSS-Image 完整子图）
```

ComfyUI 源码（1323 个文件）、模型权重、`.venv` 都不入仓库：源码按 commit 拉取，权重按需下载。

## 生成参数

| 场景 | steps | CFG | 采样器/调度 | 耗时 |
|---|---|---|---|---|
| 日常 | 30 | 4.0 | er_sde / simple | 见上表 |

SLG：`single_layers=22`、`start_percent=0`、`end_percent=0.5`，`double_layers` 留空；
负面提示词 `nsfw, worst quality, bad anatomy, watermark, jpeg artifact`。
想更快可降到 25 steps / CFG 2.5，1024² 约 25s；要更高细节再加 steps。

## 模型来源

`https://hf-mirror.com/Comfy-Org/MOSS-Image`（上游 `huggingface.co/Comfy-Org/MOSS-Image`）。

## 许可

ComfyUI 源码遵循 GPL-3.0；MOSS-Image 权重与代码版权归 OpenMOSS 团队，请遵守上游许可。

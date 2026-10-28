# moss-comfyui-config

ComfyUI `0.42.0`（tag `v0.42.0` / commit `355cd6b1`）+ MOSS-Image 量化权重的**配置仓库**：仓库里只有脚本、配置和 5 个分辨率工作流，ComfyUI 源码由 `setup.ps1` 按固定 commit 拉取，clone 完跑一条命令就完成环境与模型。

## 前置要求

| 项 | 要求 | 说明 |
|---|---|---|
| Python | **3.11**（硬要求） | ComfyUI 0.42 与 cu130 的 torch wheel 都锁 cp311；脚本检测不到会直接退出 |
| 内存 | **建议 32GB** | UNET 5.4GB + Qwen3.5-9B 文本编码器 7.3GB，8GB 显卡必须靠 offload 到内存；16GB 内存大概率 OOM |
| 显卡 | 8GB VRAM 起 | 实测 RTX 5070 Laptop 8GB 可跑 2K（峰值 6.98GB） |
| 驱动 | 支持 CUDA 13 | torch 2.14.1+cu130 |
| 磁盘 | 约 20GB | 源码 + .venv（含 torch）+ 权重 12.1GB |

## 三行命令

```powershell
git clone https://github.com/liusof/moss-comfyui-config.git
cd moss-comfyui-config
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

私有库需认证：`https://<用户名>:<PAT>@github.com/liusof/moss-comfyui-config.git`。

`setup.ps1` 依次完成：拉取 ComfyUI 源码（`Comfy-Org/ComfyUI@355cd6b1`，多源轮询 `gh-proxy.com` → `codeload.github.com` → `github.com`）→ 复制配置与工作流 → 建 `.venv` → 装 torch 2.14.1+cu130 与依赖 → 下载 12.1GB 权重 → 在桌面生成 `ComfyUI-MOSS-Image.bat`。

源码下载这一步有三个坑，脚本已经处理掉：

- GitHub archive **不支持 HTTP Range**（`-r` 被忽略，`curl -C -` 直接报 `curl: (33) HTTP server does not seem to support byte ranges`）。所以源码**不能续传**，只能每轮删掉残留、全新下载，再用 `tar -tzf` 校验完整性，不完整就换源重试。
- ComfyUI 源码目录里带 `models/`、`output/`、`user/` 等目录。若目标已存在同名目录，**`Move-Item` 会直接报 `Cannot create a file when that file already exists`**——脚本改用 `Copy-Item` 合并式落盘，已有的权重文件不会被覆盖。
- `tar` 校验包完整性时必然会把报错写进 stderr，而 PowerShell 在 `$ErrorActionPreference='Stop'` 下会把 native 命令的 stderr 判成 `NativeCommandError` 直接中断脚本。脚本用 `Invoke-Native` 把 stderr 降级成普通输出再判断。

权重下载还有两个坑：

- **HuggingFace 仓库根下没有 `models/` 这一层**。权重在本地落到 `models\vae\...`，但在 HF 上是 `vae/...`。URL 拼错会拿到 **HTTP 404 + 15 字节纯文本 `Entry not found`**，而 `curl` 对 404 仍然 exit 0——脚本会因为"下载成功"留下一个 15 字节的垃圾文件，ComfyUI 加载时才报模型损坏。脚本把本地路径和 HF 路径分成 `Path` / `HfPath` 两个字段，并按字节数校验。
- 权重走 `hf-mirror` **支持 Range**，所以可以续传；但**小于 1MB 的残片一定是错误页**（`Entry not found` 只有 15 字节），拿它续传只会产出永远不完整的坏文件。脚本见到这种残片先删掉再下。镜像按 `hf-mirror.com` → `huggingface.co` 顺序回退，用 `-HfBase` 可换。

之后**双击桌面 bat** 启动，浏览器自动开 http://127.0.0.1:8188 。

## 链路自检

装完（或怀疑环境坏了）先跑体检，约 40 秒，不加载模型、不出图：

```powershell
powershell -ExecutionPolicy Bypass -File .\verify_chain.ps1 -CheckOnly
```

它会逐项核对：服务能否起来 / ComfyUI 与 torch 版本 / 显卡与 VRAM / 12 个关键节点是否存在（含 `ResolutionSelector`、`SkipLayerGuidanceDiTSimple`、`TextGenerate`、`ComfySwitchNode`、`EmptyFlux2LatentImage`）/ 三个权重是否被 loader 下拉索引到 / 三个权重文件字节数。全 OK 时输出 `FAIL=0 WARN=0`。

去掉 `-CheckOnly` 就是全链路实跑：真跑一张 1024×1024（30 steps / CFG 4 / er_sde+simple / SLG 22 0→0.5），跑完打印出图文件名、尺寸、总耗时。

```powershell
powershell -ExecutionPolicy Bypass -File .\verify_chain.ps1
```

服务已经在跑时会直接复用；没跑则由脚本拉起，跑完关掉。

## 分辨率预设

`workflows/` 下有 5 个预设，`setup.ps1` 会自动复制到 `user/default/workflows/`，启动后在 ComfyUI 左侧 **Workflows** 里选。分辨率由工作流里的 `ResolutionSelector` 控制，采样固定 **30 steps / CFG 4**、er_sde + simple、SLG 22（0→0.5）、batch 1，想改就直接改对应控件。

| 文件 | 画幅 | 实际分辨率 | 30 steps 耗时 | 峰值显存 |
|---|---|---|---|---|
| `1-square-1024` | 1:1 | 1024×1024 | 约 30s（首跑 34.8s） | 6798 MB |
| `2-landscape-1536x864` | 横屏 16:9 | 1536×864 | 38.5s | 6792 MB |
| `3-portrait-864x1536` | 竖屏 9:16 | 864×1536 | 约 39s | 6792 MB |
| `4-landscape-2k-2048x1152` | 2K 横屏 16:9 | 2048×1152 | 77.7s | 6984 MB |
| `5-portrait-2k-1152x2048` | 2K 竖屏 9:16 | 1152×2048 | 约 78s | 6984 MB |

实测环境：RTX 5070 Laptop 8GB / 32GB RAM。首跑多出的几秒是模型加载/编译缓存。2K 在 8GB 上实测可跑（峰值 6.98GB），1536×1536 以上大概率 OOM。

## 分步执行（可选）

只装环境不下模型：`setup.ps1 -SkipModels`；不生成桌面启动器：`-NoDesktopShortcut`；用精确版本复现（`config/pip-freeze.txt`）：`-UseFreeze`；Python 不在 PATH 或路径特殊：`-PythonExe 'D:\Python311\python.exe'`；换源码镜像：`-SourceProxy 'https://ghfast.top'`；换权重镜像：`-HfBase 'https://huggingface.co/Comfy-Org/MOSS-Image/resolve/main'`；换 torch 镜像顺序：`-TorchMirrors 'https://mirror.nju.edu.cn/pytorch/whl/cu130','https://download.pytorch.org/whl/cu130'`。

`-UseFreeze` 会用 `pip install -r config/pip-freeze.txt --index-url https://download.pytorch.org/whl/cu130 --extra-index-url https://pypi.org/simple`。两个索引都要给：freeze 里写的是 `torch==2.14.1+cu130`，这个带本地版本号的包只在 pytorch 索引里有（PyPI 上没有），而其余 80 多个包只在 PyPI 上。

`setup.ps1` 会在装完依赖后，按**实际装到的** `comfyui-frontend-package` 版本回写 `user/default/comfy.settings.json` 里的 `Comfy.InstalledVersion`（这个值是"首次安装时运行的前端版本"，前端用它做版本化默认值）。默认走 `requirements.txt` 装的是前端 `1.55.18`，走 `-UseFreeze` 是 `1.57.1`，仓库里原本硬编码的 `1.57.1` 与默认路径对不上。

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
verify_chain.ps1             链路自检（体检 / 实跑出图）
一键部署.bat                  双击版 setup
start_comfyui.bat            前台启动
config/comfy-settings.json   本机 ComfyUI 用户设置
config/pip-freeze.txt        本机 84 个包的确切版本（配合 -UseFreeze）
workflows/*.json             5 个分辨率预设（含 MOSS-Image 完整子图）
```

ComfyUI 源码（1302 个文件）、模型权重、`.venv` 都不入仓库：源码按 commit 拉取，权重按需下载。部署后目录里会多出 `README.comfyui.md`（上游 README 改名保存，避免盖掉本仓库的）、合并后的 `.gitignore`、`user/default/`（配置与工作流的落地位置）。

## 生成参数

| 场景 | steps | CFG | 采样器/调度 | 耗时 |
|---|---|---|---|---|
| 日常 | 30 | 4.0 | er_sde / simple | 见上表 |

SLG：`single_layers=22`、`start_percent=0`、`end_percent=0.5`，`double_layers` 留空；
负面提示词 `nsfw, worst quality, bad anatomy, watermark, jpeg artifact`。
想更快可降到 25 steps / CFG 2.5，1024² 约 25s；要更高细节再加 steps。

工作流里有两处容易误会：

- `TextGenerate` + `PrimitiveStringMultiline` 是**提示词增强**支路（用 Qwen3.5-9B 把短 prompt 扩写成结构化长描述），`ComfySwitchNode` 控制走不走它。
- 子图里的 `ref_image` 只喂给这条 LLM 支路，**MOSS-Image 本身不支持图生图**。想纯 T2I 就把开关关掉。

## 源码固定点

ComfyUI 源码 pin 在 `Comfy-Org/ComfyUI@355cd6b14c92c19ac3188fe528e47a3f21ef5178`（= `v0.42.0` tag）。这个 commit 已逐个核对过工作流需要的节点与参数位：

`ResolutionSelector`（含 `multiple`，默认 8）、`SkipLayerGuidanceDiTSimple`（4 个输入、无 scale）、`TextGenerate`（13 个 widget）、`ComfySwitchNode`、`EmptyFlux2LatentImage`、`CLIPLoader` 的 `type` 含 `moss_image`、`model_base.MOSSImage` / `sd.CLIPType.MOSS_IMAGE=38`。

注意 GitHub 上的 ComfyUI 仓库已从 `comfyanonymous/ComfyUI` 迁到 `Comfy-Org/ComfyUI`，老 commit sha 在现仓库查不到（API 返回 422）。用 `-ComfyCommit` 换版本时请从 `Comfy-Org` 取 sha。

## 常见问题

**源码下载失败 / 解压失败**：GitHub archive 经代理经常传到一半就断，而 `curl` 对"HTTP 200 但流被切断"不报错。脚本按 `gh-proxy.com` → `codeload.github.com` → `github.com` 三个源轮询，每轮删除残留、全新下载（**archive 不支持 Range，续传无效**），用 `tar -tzf` 校验完整性，不完整则重试（最多 6 轮）。若仍失败，手动 `git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git` 后把内容拷到本目录，或用 `-SourceProxy` 换镜像。

**`.gitignore` 被 ComfyUI 覆盖**：脚本把上游 `.gitignore`（含 `/models/`、`/output/`、`/input/`、`/user/`、`.venv/`、`/custom_nodes/`）与仓库自己的规则做**并集合并**后再落盘，不会覆盖掉仓库侧的规则。

**提示编码乱码 / 中文变问号**：脚本是 UTF-8 with BOM；若被编辑器改成无 BOM，Windows PowerShell 5.1 会按 ANSI 解析中文。用 VS Code 另存为 "UTF-8 with BOM"。

**跑起来 OOM**：给启动命令加 `--lowvram`（编辑桌面 `ComfyUI-MOSS-Image.bat`，在 `main.py` 后追加），或先用 `-CheckOnly` 确认不是权重损坏。

**权重下载到一半就停了 / 报"下载不完整"**：多半是镜像连接被重置（`curl: (56) Recv failure: Connection was reset`）。直接重跑 `setup.ps1` 即可续传；想换源加 `-HfBase`。脚本也会自动在 `hf-mirror.com` 和 `huggingface.co` 之间回退。

**模型加载报文件损坏**：检查 `models\vae\flux2-vae_small.safetensors` 是不是 15 字节——那是 HF 的 404 错误页（`Entry not found`），不是权重。删掉重跑脚本即可。

## 模型来源

`https://hf-mirror.com/Comfy-Org/MOSS-Image`（上游 `huggingface.co/Comfy-Org/MOSS-Image`）。

## 许可

ComfyUI 源码遵循 GPL-3.0；MOSS-Image 权重与代码版权归 OpenMOSS 团队，请遵守上游许可。

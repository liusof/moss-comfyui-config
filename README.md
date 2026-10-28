# moss-comfyui-config

ComfyUI `0.42.0`（tag `v0.42.0` / commit `355cd6b1`）+ MOSS-Image 量化权重的**配置仓库**。

仓库里只有脚本、配置和 5 个分辨率工作流；ComfyUI 源码、虚拟环境、12.1GB 权重全部由 `setup.ps1` 按固定版本拉取。**32GB 内存 / 8GB 显存**即可跑 1024²，2K 也能跑。

---

## 一、部署：三步

### 0. 先确认前置

| 项 | 要求 | 不满足会怎样 |
|---|---|---|
| Python | **3.11** | 脚本检测不到就直接退出（cu130 的 torch wheel 只锁 cp311） |
| 内存 | **32GB 建议** | 16GB 大概率 OOM：8GB 显卡靠内存 offload |
| 显卡 | 8GB VRAM 起 | — |
| 驱动 | 支持 CUDA 13 | torch 2.14.1+cu130 |
| 磁盘 | 约 20GB | 源码 + .venv(含 torch) + 权重 12.1GB |

### 1. 拿代码

```powershell
git clone https://github.com/liusof/moss-comfyui-config.git
cd moss-comfyui-config
```

### 2. 装

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

或者不碰命令行：**双击 `一键部署.bat`**。

这一步做完五件事，中途不需要任何输入：

| 步骤 | 做什么 | 耗时（100M 宽带） |
|---|---|---|
| 1/5 | 拉 ComfyUI 源码 `Comfy-Org/ComfyUI@355cd6b1`（12.7MB，三镜像轮询） | 约 1 分钟 |
| 2/5 | 建 `.venv` | 约 20 秒 |
| 3/5 | 装 torch 2.14.1+cu130 + 依赖（torch wheel 2GB，走南大镜像） | 约 5 分钟 |
| 4/5 | 下 12.1GB 权重（hf-mirror，支持续传） | 30–100 分钟 |
| 5/5 | 在桌面生成 `ComfyUI-MOSS-Image.bat` | 1 秒 |

**中断了直接重跑同一条命令**，已完成的步骤会跳过，权重会续传。

### 3. 启动

**双击桌面的 `ComfyUI-MOSS-Image.bat`**，浏览器会自动打开 http://127.0.0.1:8188 。

在工作流面板左侧 **Workflows** 里选预设（如 `1-square-1024`），点 Run。

---

## 二、装完先自检

一行命令，40 秒，确认环境真的能用：

```powershell
powershell -ExecutionPolicy Bypass -File .\verify_chain.ps1
```

它会真跑一张 1024×1024（30 steps / CFG 4 / er_sde+simple / SLG 22 0→0.5），打印出图文件名、尺寸、耗时，最后一行是结论：

```
===== 结论：FAIL=0 WARN=0 ===== 链路可用。
```

只体检、不出图（约 40 秒，不加载模型）：加 `-CheckOnly`。

```powershell
powershell -ExecutionPolicy Bypass -File .\verify_chain.ps1 -CheckOnly
```

体检项：服务能否起来 / ComfyUI 与 torch 版本 / 显卡与 VRAM / 12 个关键节点 / 3 个权重是否被 loader 索引到 / 3 个权重文件字节数。服务已在本机跑着会直接复用，没跑则由脚本拉起、跑完关掉。

---

## 三、分辨率预设

`workflows/` 下 5 个，`setup.ps1` 自动复制到 `user/default/workflows/`。分辨率由工作流里的 `ResolutionSelector` 控制，采样固定 **30 steps / CFG 4**、er_sde + simple、SLG 22（0→0.5）、batch 1。

| 文件 | 画幅 | 分辨率 | 30 steps 耗时 | 峰值显存 |
|---|---|---|---|---|
| `1-square-1024` | 1:1 | 1024×1024 | 约 30s（首跑 34.8s） | 6798 MB |
| `2-landscape-1536x864` | 横屏 16:9 | 1536×864 | 38.5s | 6792 MB |
| `3-portrait-864x1536` | 竖屏 9:16 | 864×1536 | 约 39s | 6792 MB |
| `4-landscape-2k-2048x1152` | 2K 横 16:9 | 2048×1152 | 77.7s | 6984 MB |
| `5-portrait-2k-1152x2048` | 2K 竖 9:16 | 1152×2048 | 约 78s | 6984 MB |

实测：RTX 5070 Laptop 8GB / 32GB RAM。首跑多几秒是模型加载。2K 在 8GB 上实测可跑，1536×1536 以上大概率 OOM。

想更快：降到 25 steps / CFG 2.5，1024² 约 25s。

工作流里两处容易误会：

- `TextGenerate` + `PrimitiveStringMultiline` 是**提示词增强**支路（用 Qwen3.5-9B 把短 prompt 扩写成结构化长描述），`ComfySwitchNode` 控制走不走它。
- 子图里的 `ref_image` 只喂给这条 LLM 支路，**MOSS-Image 本身不支持图生图**。想纯 T2I 就把开关关掉。

---

## 四、可选参数

全部都有默认值，**一般不用加**。只有出问题或想改路径时用：

| 参数 | 用途 |
|---|---|
| `-SkipModels` | 只装环境、不下权重 |
| `-NoDesktopShortcut` | 不生成桌面 bat |
| `-UseFreeze` | 用 `config/pip-freeze.txt` 的 84 个确切版本复现 |
| `-PythonExe 'D:\Python311\python.exe'` | Python 不在 PATH |
| `-SourceProxy 'https://ghfast.top'` | 换源码镜像 |
| `-HfBase 'https://huggingface.co/Comfy-Org/MOSS-Image/resolve/main'` | 换权重镜像 |
| `-TorchMirrors 'https://mirror.nju.edu.cn/pytorch/whl/cu130'` | 换 torch 镜像顺序 |

`-UseFreeze` 用的是 `pip install -r config/pip-freeze.txt --index-url https://download.pytorch.org/whl/cu130 --extra-index-url https://pypi.org/simple`：两个索引都要给，因为 `torch==2.14.1+cu130` 只存在于 pytorch 索引，其余 80 多个包只在 PyPI。

装完依赖后脚本会按**实际装到的** `comfyui-frontend-package` 版本回写 `user/default/comfy.settings.json` 里的 `Comfy.InstalledVersion`（这个值是"首次安装时运行的前端版本"，前端拿它选版本化默认值）。默认走 `requirements.txt` 得到前端 `1.55.18`，`-UseFreeze` 是 `1.57.1`。

---

## 五、仓库内容

```
README.md                    本说明
setup.ps1                    一键配置（五步）
verify_chain.ps1             链路自检（体检 / 实跑出图）
一键部署.bat                  双击版 setup
start_comfyui.bat            前台启动
config/comfy-settings.json   本机 ComfyUI 用户设置
config/pip-freeze.txt        本机 84 个包的确切版本（配合 -UseFreeze）
workflows/*.json             5 个分辨率预设（含 MOSS-Image 完整子图）
```

ComfyUI 源码（1302 个文件）、权重、`.venv` 都不入仓库。部署后目录里会多出 `README.comfyui.md`（上游 README 改名保存）、合并后的 `.gitignore`、`user/default/`（配置与工作流的落地位置）。

---

## 六、脚本替你处理的坑

部署链路上有五处会直接让脚本失败的地方，都已经在 `setup.ps1` 里处理掉了。记在这里是为了改脚本时别踩回去。

**源码下载：GitHub archive 不支持 HTTP Range。** `-r` 被忽略，`curl -C -` 直接报 `curl: (33) HTTP server does not seem to support byte ranges`。所以源码**不能续传**，只能每轮删掉残留、全新下载，再用 `tar -tzf` 校验完整性，不完整就换源（`gh-proxy.com` → `codeload.github.com` → `github.com`）。

**源码解包：`Move-Item` 会撞已存在目录。** ComfyUI 源码自带 `models/`、`output/`、`user/`，目标已存在同名目录时 `Move-Item -Force` 报 `Cannot create a file when that file already exists`。改用 `tar --strip-components 1` 解开后 `Copy-Item` 合并落盘，已有权重不被覆盖。

**原生命令的 stderr 被当成致命错误。** `$ErrorActionPreference='Stop'` 下，native 命令写 stderr（pip 的 WARNING、curl 的进度条、tar 的报错）会抛 `NativeCommandError` 直接中断。脚本用 `Invoke-Native` / `Invoke-Exe` 临时降级并透传输出。

**权重 URL 多一层 `models/`。** HF 仓库根下没有 `models/`：本地落 `models\vae\...`，线上是 `vae/...`。拼错拿到的不是报错而是 **HTTP 404 + 15 字节纯文本 `Entry not found`**，而 `curl` 对 404 仍 exit 0，于是留下垃圾文件、直到加载模型才报损坏。脚本把本地路径与 HF 路径分成 `Path` / `HfPath`，按字节数校验。

**15 字节残片会被拿去续传。** 权重走 `hf-mirror` 支持 Range，但 `<1MB` 的残片一定是错误页。脚本见到 `<1MB` 或 `>预期` 的残片先删掉再下，并在 `hf-mirror.com` → `huggingface.co` 之间回退。

---

## 七、常见问题

**源码下载失败 / 解压失败**：脚本已按三源轮询 + 6 轮重试 + `tar -tzf` 校验。仍失败就手动 `git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git` 再把内容拷到本目录，或用 `-SourceProxy` 换镜像。

**提示编码乱码 / 中文变问号**：脚本是 UTF-8 with BOM。若被编辑器改成无 BOM，Windows PowerShell 5.1 会按 ANSI 解析中文。用 VS Code 另存为 "UTF-8 with BOM"。

**跑起来 OOM**：给启动命令加 `--lowvram`（编辑桌面 `ComfyUI-MOSS-Image.bat`，在 `main.py` 后追加），或先用 `-CheckOnly` 确认不是权重损坏。

**权重下载到一半停了**：多半是镜像连接被重置（`curl: (56) Recv failure: Connection was reset`）。重跑 `setup.ps1` 会续传；想换源加 `-HfBase`。

**模型加载报文件损坏**：检查 `models\vae\flux2-vae_small.safetensors` 是不是 15 字节——那是 HF 的 404 错误页，不是权重。删掉重跑即可。

**`.gitignore` 会不会被 ComfyUI 覆盖**：不会。脚本把上游 `.gitignore` 与仓库自己的规则做并集合并后再落盘。

---

## 八、源码固定点

ComfyUI 源码 pin 在 `Comfy-Org/ComfyUI@355cd6b14c92c19ac3188fe528e47a3f21ef5178`（= `v0.42.0` tag）。已逐个核对工作流需要的节点与参数位：

`ResolutionSelector`（含 `multiple`，默认 8）、`SkipLayerGuidanceDiTSimple`（4 个输入、无 scale）、`TextGenerate`（13 个 widget）、`ComfySwitchNode`、`EmptyFlux2LatentImage`、`CLIPLoader` 的 `type` 含 `moss_image`、`model_base.MOSSImage` / `sd.CLIPType.MOSS_IMAGE=38`。

注意 GitHub 上的 ComfyUI 仓库已从 `comfyanonymous/ComfyUI` 迁到 `Comfy-Org/ComfyUI`，老 commit sha 在现仓库查不到（API 返回 422）。用 `-ComfyCommit` 换版本时请从 `Comfy-Org` 取 sha。

## 模型来源

`https://hf-mirror.com/Comfy-Org/MOSS-Image`（上游 `huggingface.co/Comfy-Org/MOSS-Image`）。

## 许可

ComfyUI 源码遵循 GPL-3.0；MOSS-Image 权重与代码版权归 OpenMOSS 团队，请遵守上游许可。

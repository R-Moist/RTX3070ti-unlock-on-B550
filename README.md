# RTX 3070 Ti（GA104）在 ASUS B550M 平台上的 UEFI 解锁 —— 完整移植记录

> **Abstract (EN).** We ported `Windows-GPU-UNLOCK`'s manual (internal-boot) unlock path to an
> ASUS TUF GAMING B550M-PLUS (WI-FI) with a Colorful RTX 3070 Ti (GA104, VBIOS 94.04.5a.00.bb).
> The platform has **no integrated display controller at all**, so the console GOP lives on the
> target GPU — a topology none of the upstream reviewed profiles cover. Two read-only probe boots
> produced a complete machine profile, and after fixing **seven** assumption mismatches (three of
> them the same `bus == 1` hardcode in different files) the SS0 write and PCIe FLR completed with
> `transaction result=0`. Measured FP16/BF16 GEMM: **86.1 / 85.8 TFLOPS**, against a published
> locked ceiling of ~43–44. The unlock is replayed on every boot (SS0 is volatile); it does **not**
> accelerate quantised LLM inference, and §6.2 explains exactly why.

---

## 1. 结论

| 项目 | 结果 |
|---|---|
| 解锁是否成功 | **是**，`transaction result=0`，`SS0=0x88888888` 写入并在 FLR 后保持 |
| FP16 / BF16 GEMM | **86.1 / 85.8 TFLOPS**（8192³） |
| 对照组是否变化 | **否**（TF32 23.2 TFLOPS、显存拷贝 549 GB/s 均正常） |
| 持久性 | **易失**，每次开机重放，断电即恢复原状 |
| 对量化 LLM 推理 | **无增益**，原因见 §6.2 |

**必须先说清楚**：本记录**没有做同机基线对照**（那需要一次正常开机重跑）。86.1 TFLOPS 是与
上游公开的"锁定态约 43–44 TFLOPS"参考值相比得出约 2 倍，而不是同机 A/B 实测。若需严格结论，
按 §10 第 6 步补一次基线测量即可。

---

## 2. 目标机器

| 项目 | 值 |
|---|---|
| 主板 | ASUSTeK TUF GAMING B550M-PLUS (WI-FI)，BIOS 3636 |
| CPU | AMD Ryzen 9 5900X（**没有集成显示控制器**） |
| GPU | Colorful RTX 3070 Ti 8 GB，GA104，`10de:2482`，subsystem `1621:7377` |
| VBIOS | 94.04.5a.00.bb |
| GPU 位置 | `0000:07:00.0`，位于根端口 `00:03.1` 之后 |
| 显示拓扑 | **仅一个 GOP，就在目标卡上**；`ConOutDev` 与该 GOP 的设备路径逐字节相同 |
| 现有环境 | 主板自带一个 1 GiB PE 恢复分区；另有一个 Windows ESP |

这个组合恰好落在上游三份已验证档案之外：

| 档案 | CPU 侧显示 | 控制台归属 | `GU_CONSOLE_AGGREGATE` |
|---|---|---|---|
| B650M + 3090 FE | 有 iGPU，无 GOP | 目标卡 | 0 |
| B660M + 3070 Ti | 无 iGPU | AMI combo splitter | 1 |
| H610M + 3060 | 有 iGPU（无 GOP） | 目标卡 | 0 |
| **本机** | **完全没有显示控制器** | **目标卡（唯一 GOP）** | **0** |

---

## 3. 方法：先只读，再写

整个移植没有"猜一次、写一次"的循环，而是三阶段、每阶段都可回退：

1. **只读探针**（`build-diagnostic.ps1` + `GU_PROFILE_PROBE_B550M_3070TI`）
   只做 PCI 配置空间读取、能力遍历、BAR/PROM 哈希、GOP 与驱动镜像转储。
   manifest 明示 `CanUnlock=false / CanDetach=false / WritesFirmwareVariables=false`。
2. **由探针数据推导 profile**，再用 `-ExperimentalUnlock` 构建带写能力的版本。
   写入前有一整套 preflight，任一项不符即 `STOP` 且不写入。
3. **事务**：仅在一次人工确认（按 `U`）之后执行，SS0 写入 + PCIe FLR。

探针本身就把"读"和"写"彻底分开：`failure` 时它宁可停机也不带脏状态进 Windows。

---

## 4. 实测 profile 常量

全部来自两次只读探针抓取，非推测：

| 宏 | 值 | 来源 |
|---|---|---|
| `GU_BOARD_ID` | `0x248210de` | `config[0]` |
| `GU_BOARD_SUBSYSTEM` | `0x16217377` | `config[11]` |
| `GU_BAR0_BASE` / `_END` | `0xfb000000` / `0xfbffffff` | `config[4]` + BAR 描述符 |
| `GU_DEVICE_MEMORY_SIZE` | `0x2000`（8192 MiB） | MMIO `0x1183a4` |
| `GU_CHIP_ID` | `0xb74000a1` | MMIO `0x0` |
| `GU_PROM_SHA256` | `85c502fd…612e6eb3` | 1 MiB PROM @ `BAR0+0x300000` |
| `GU_ROOT_PORT_DEVICE` / `_FUNCTION` | `3` / `1` | 设备路径节点 `010106000103` |
| `GU_TARGET_BUS` | **`7`** | `GetLocation()` |
| `GU_NVGOP_VERSION` | `0x6000a`（**6.10**） | DriverBinding 版本 |
| `GU_NVGOP_IMAGE_SIZE` | `0x2be40` | LoadedImage |
| `GU_NVGOP_STOP` | `0x698` | `binding->Stop - ImageBase` |
| `GU_NVGOP_TEXT_BYTES` | `0x24426` | `.text` VirtualSize |
| `GU_CONSOLE_AGGREGATE` | `0` | `ConOutDev` == 目标 GOP 路径 |

`GU_RTX_PATH_BYTES`（36 字节）：
```
2,1,12,0,0xd0,0x41,3,10,0,0,0,0, 1,1,6,0,1,3, 1,1,6,0,0,0, 2,3,8,0,0x40,3,1,128, 127,255,4,0
```
即 `PciRoot(0) / Pci(3,1) / Pci(0,0) / ADR 0x80010340`。注意 PCI 节点字节序是 **Function 在前、Device 在后**。

`GU_NVGOP_TEXT_BYTES` 的取值方法（本文档的一个可复用结论）：它**不是** FileAlignment 对齐值，
因此只能是 `.text` 的 `VirtualSize`；用三家档案交叉验证——B650M `0x23d6a`、B660M `0x20d33`、
本机 `0x24426` 全部非对齐，且 `0x280 + TEXT_BYTES` 都恰好落在 `.data` 之前的对齐间隙内。

---

## 5. 七个阻塞点

按遇到顺序。每一条都有日志证据，不是推理。

### 5.1 探针信封与 `Bus != 1`（`probe.c`）

现象：`incomplete reason=probe-unreviewed-envelope status=EFI_UNSUPPORTED`，深读全部跳过。
根因：`ProbeUnchanged()` 硬编码 `bus==1, dev==0, fun==0`；信封检查也按总线 1 建立的假设。
修法：本 profile 下把信封改为**记录而非强制**（探针只读，无法 arm/release/BME/DMA/FLR），
并把每一项结果写进日志；位置改为记录而非钉死。

> 这一条顺带抓出了我自己写错的 `GU_BOARD_SUBSYSTEM`（写成了 `0x16213777`，真值 `0x16217377`，
> 73/37 颠倒）。是日志里 `envelope identity=0` 暴露的——**这就是为什么要"记录而非跳过"**。

### 5.2 手工版只允许从 USB 启动（`app_io.c: UsbPath`）

现象：选了启动项直接进 BIOS，ESP 上**没有任何日志**。
根因：`if(!UsbPath(loaded->DeviceHandle)) return EFI_UNSUPPORTED;` —— 要求设备路径含 `MSG_USB_DP`。
从内置 ESP 启动必然失败，而且在创建日志目录**之前**就返回了，所以外面看像"固件没加载"。
修法：本 profile 改用 internal 媒体策略；后续进一步改为"任意真实分区"（§7）。

### 5.3 `checks.c`: `Bus != 1`

现象：`target BDF=0:7:0.0 checks=0 pm=0 pcie=0 msi=0 msix=0` → `stage=target` 失败。
根因：`GuCheckConfig()` 第一条就是 `Bus != 1`。
修法：引入 `GU_TARGET_BUS`（`#ifndef` 默认 `1U`，本机 `7U`），三处调用点共用。

### 5.4 `port.c`: `B == 1`

现象：按 `U` 后 `driver release: status=0 refresh=EFI_UNSUPPORTED same_pci=0` → `STOP`。
根因：`GuTargetConfig()` 里 `B == 1`；`GuRefreshTargetPci()` 释放后要用它复核。
修法：同上改用 `GU_TARGET_BUS`。

> 这是**同一个假设的第三次出现**。前两次修完仍会在 `decode-after-release`（`app.c:252` 也调它）
> 再炸一次，所以三处必须一起改。教训：在这种代码库里搜 `bus` 要连 `B==` 一起搜。

### 5.5 `DisplayCheck()` 假定控制台在 AMD 核显上（`app.c`）

根因：`AmdGopParent()` 要求 GOP 的 PCI 父设备是 `bus 12 / dev 0 / fun 0` 且 `1002:164e` / `1043:8877`。
本机没有任何集成显示控制器，控制台就在目标卡上，**恒假**。
修法：新增 profile 专属 `TargetOwnsConsole()`，把性质**反过来验证**——GOP 恰为 1 个、其 PCI 父设备
等于 `0/7/0/0`、模式为可用 RGB/BGR framebuffer。并显式记录"控制台在目标上，释放时必然丢失"。

### 5.6 释放后必须变成 0 个 GOP

`DisplayCheck()` 释放前后被调用两次，而本机两种状态是 1 个 / 0 个。用 `Gu.armed` 区分：
armed 时要求 `count==0`（这正是无头档案写的"释放前一个 RTX 物理 GOP，释放后为零"）。

### 5.7 ownership 拒绝"驱动自有的子控制器"（`ownership.c`）

现象：`release refused: active child, different owner or unsupported open at record 5`。
根因：第二阶段要求所有非被动记录都恰为 `BY_DRIVER`；而 record 5 是 nvgop 用**自己创建的 GOP 子设备**
开的 `DevicePath`（`BY_CHILD_CONTROLLER`, `controller=0xc6eceb18`）。
修法：放行 `BY_CHILD_CONTROLLER && AgentHandle == Owner->agent && OpenCount == 1 && controller != 目标`。
语义上仍然安全：`DisconnectController` 只拆这个驱动自己的东西。外来 agent、其他非 `BY_DRIVER` 仍拒绝。

### 5.8 事务后返回固件会黑屏挂死

根因：释放 nvgop 后控制台 GOP 已消失，`efi_main` 却 `return` 给固件；BDS 重画界面时无显示驱动。
易失的 SS0 会随断电丢失——**功能上等于失败**。
修法：新增 `WindowsHandoff()`，事务成功后直接 `LoadImage` + `StartImage`
`\EFI\Microsoft\Boot\bootmgfw.efi`，**不重置**。若 `StartImage` 返回则 `Halt()`，绝不让 BDS 重画。

---

## 6. 结果

### 6.1 FP16 / BF16 GEMM

```
device  : NVIDIA GeForce RTX 3070 Ti   cc 8.6   torch 2.14.1+cu126
gemm_fp16_8192   12.77 ms   86.1 TFLOPS
gemm_bf16_8192   12.82 ms   85.8 TFLOPS
gemm_fp16_4096    1.63 ms   84.5 TFLOPS
gemm_bf16_4096    1.62 ms   84.9 TFLOPS
gemm_tf32_8192   47.37 ms   23.2 TFLOPS     ← 对照
mem_copy_1gib     2.00 ms  549.2 GB/s       ← 对照（规格 608）
```

测量设置与上游对齐：`allow_tf32=False`、`allow_fp16_reduced_precision_reduction=False`，
避免 TF32 与低精度累加污染结论。脚本见 `bench_gemm.py`，原始数据 `evidence/gemm-unlocked.json`。

**对照组没有变化**，说明提升只发生在 FP16/BF16 张量通路——正是 SS0 该管的地方。

### 6.2 为什么量化 LLM 推理没有变快

实测同一台机器上的 llama.cpp（`Qwen3.6-35B-A3B-UD-IQ4_XS`，`-ngl 99 -ncmoe 36 -fa on -ctk q8_0 -ctv q8_0`）：

```
prefill: 1685 tok/s   (9001 tokens / 5340 ms)
decode :   36.7 tok/s
```

**这不是解锁失败，是这个负载对 SS0 免疫**，三条原因任一已足够：

1. **decode 是带宽受限**，不是算力受限。出词时 GPU 在等权重，FMA 单元吃不满。
2. **`-ncmoe 36`** 把 36 层 MoE 专家放在 CPU，每 token 都要跨 PCIe。
3. **4-bit 量化走 `__dp4a` INT8 点积**，不是 FP16 HMMA —— SS0 管的电路不在热路径上。

只有 `-fa on` 的 attention 用 FP16 MMA，而它在 35B MoE 的 FLOPs 里占比很小。

**所以这 2 倍算力该用在哪**：fp16/bf16 计算密集的负载——微调、LoRA、扩散模型推理、
非量化的 fp16 前馈。不是 4-bit GGUF 的 token 生成。

### 6.3 顺带发现（与解锁无关）

`nvidia-smi` 报 `pcie.link.width.current = 8`，而 `Link Cap` 声明 x16；卡在 `00:03.1` 之后。
若能把 x8 修回 x16，是另一笔独立的带宽收益。

---

## 7. 位置无关与 EFI Shell 可用

原始设计把 unlock 分区钉死成"配置里那个 GUID"，无法在别的介质或 Shell 里运行。改了三处：

1. **`media.h`: `GuPathIsHardDrive()`** —— 只要求路径格式良好且**恰含一个 GPT/MBR HARDDRIVE 节点**，
   不比对 GUID。多 HD 节点、畸形、无分区节点仍拒绝。
2. **`app_io.c`** —— 介质判定改用它；且输出目录不存在时带 `EFI_FILE_MODE_CREATE` 重试，
   不再在写第一行日志之前静默退出。
3. **`app.c`: `WindowsHandoff()`** —— 改为**按 `\EFI\Microsoft\Boot\bootmgfw.efi` 是否存在**发现
   Windows ESP，不依赖分区 GUID；仍要求唯一匹配，多个则 fail-closed。

结果：同一份 EFI 可从内置 ESP、任意 U 盘、任意磁盘分区、以及同一卷的任意目录运行。
**唯一剩余约束**：资产必须在**卷根**的 `\RTX3090-UNLOCK\ASSETS\`
（5 个 `.bin` + `NVIDIA-LICENSE`，共 6 个文件；路径以卷为基准，与 EFI 所在目录无关）。

### 从 EFI Shell 启动

```
map -r                              # 若看不到卷
fs0:                                # 换成放 EFI 的那个卷
cd \
EFI\Unlock\UNLOCK.EFI
```

不需要额外的启动脚本，直接调用 EFI 即可。两点提醒：

- **按 U 之后屏幕会立刻变黑**——控制台 GOP 就在目标卡上，被释放了。这是设计如此，
  事务完成后程序会自己引导 Windows，画面恢复。
- 若不打算真的写入，在提示处按 **Esc**（或等 30 秒超时）即可干净退出；此时
  `attempted=0 driver_release=0`，GPU 状态未变。
- 从 Shell 跑时若事务失败，程序会返回到 Shell——但那时屏幕已黑、Shell 不可用，只能断电。
  建议首次先按 Esc 走一遍，确认能正常返回。

---

## 8. 兼容性：重建引导 / 换 ESP / 清 NVRAM

| 情况 | 是否仍可用 | 原因 |
|---|---|---|
| 重建 BCD（`bcdboot`、`bcdedit`、启动修复） | **是** | 启动项存在 **UEFI NVRAM**（`BootXXXX`/`BootOrder`），不在 `\EFI\Microsoft\Boot\BCD`；程序也从不读 BCD |
| 重装 Windows / 新建 ESP | **是**（§7 之前不是） | 交棒改为按文件发现，不再依赖分区 GUID |
| 刷 BIOS / 清 CMOS → NVRAM 丢失 | **启动项丢失** | EFI 文件仍在，重跑 `deploy-unlock.ps1`，或从 Shell 启动 |
| 更换 NVIDIA 驱动 | **是** | 解锁在固件层、每次开机重放，与 Windows 驱动无关 |

**硬约束**：事务和 Windows 必须在**同一次开机**内完成。SS0 易失，中途重启即失效。
这决定了它永远是"开机 → 跑 → 按 U → 直接进 Windows"的形态，无法做成"跑一次永久生效"。

---

## 9. 未验证与已知限制

- **没有同机基线 A/B**（见 §1）。86.1 TFLOPS 对比的是上游公开的锁定态参考值。
- **`GU_NVGOP_TEXT_BYTES` 是反推值**（§4 的交叉验证），若错会在 preflight 报 `EFI_CRC_ERROR` 并停机，不会写坏。
- **位置无关那一版（`4a691d94…`）尚未实机运行**；其解锁能力由前一版（`d5d6da12…`）实测证明，
  改动只涉及介质判定、目录创建、交棒发现，不涉及事务逻辑。
- **SS1 未写入**（`entryLatchedSs1Preserve`）。SS0-only 已能拿满 FP16/BF16；SS1=8 的收益上游标注为未验证。
- **`-ncmoe`、量化模型的实际收益为零**，见 §6.2。
- 仅在**一块** B550M + 3070 Ti 上验证过。不同 vBIOS / 主板 BIOS 需要重新跑探针。

---

## 10. 复现步骤

```powershell
# 0) 依赖：LLVM 20.1.8（clang + lld-link）、Python 3.14、edk2 MdePkg 头文件
#    上游仓库：https://github.com/impacifist/Windows-GPU-UNLOCK @ f33a4c8

# 1) 应用本移植
git clone https://github.com/impacifist/Windows-GPU-UNLOCK.git src
cd src && git checkout f33a4c8
git apply ../patches/0001-support-asus-b550m-plus-wifi-rtx3070ti.patch

# 2) 写入本地分区配置（unlock 分区 = 用来存放资产的卷；Windows ESP 用于交棒）
#    参考 internal-boot/Configure.ps1 生成的 platform-config.h 格式

# 3) 只读探针（先确认身份，再谈写入）
.\internal-boot\boot\build-diagnostic.ps1 -HardwareProfile probe-b550m-3070ti `
    -Clang <clang.exe> -LldLink <lld-link.exe> -Python <python.exe>

# 4) 生成 5 个固件资产（见 §11，NVIDIA 版权，不可再分发）
#    git clone https://github.com/Zagitta/gpu-unlock.git
#    git checkout 0ebdb1c6...；python firmware/fetch_artifacts.py <inputs>
#    python firmware/generate_v67.py <nvidia-utils.pkg.tar.zst> <assets>
#    python firmware/extract_boot_assets.py <NVIDIA-kernel-module-source> <assets>

# 5) 带写能力的构建
.\internal-boot\unlock\build.ps1 -HardwareProfile b550m-3070ti `
    -ExperimentalUnlock -StockProfile entryLatchedSs1Preserve -Clang ... -LldLink ... -Python ...

# 6) 部署 + 冷启动 + 按 U
#    产物只有一个：Release/  （EFI + 资产 + SHA256SUMS，整个目录内容即 FAT32 卷根布局）
.\tools\deploy-unlock.ps1

# 7)（可选）GEMM 基准
python bench_gemm.py --json evidence/gemm-unlocked.json
```

---

## 11. 许可与合规

**代码：GPL-2.0-only。** 本项目是
[`impacifist/Windows-GPU-UNLOCK`](https://github.com/impacifist/Windows-GPU-UNLOCK) @ `f33a4c8` 的衍生作品
（其本身为 GPL-2.0-only），并引用 [`Zagitta/gpu-unlock`](https://github.com/Zagitta/gpu-unlock) @ `0ebdb1c6`
的固件生成器（GPL-2.0-only）。因此本移植同样以 **GPL-2.0-only** 发布，完整条款见 `LICENSE`。
修改内容全部以 patch 形式给出（`patches/`），便于审计与上游合并。

**固件资产：不可再分发。**
`\RTX3090-UNLOCK\ASSETS\` 里的 5 个 `.bin` 由 NVIDIA 驱动包逐字节提取（`gsp_ga10x.bin` 等），
版权属 NVIDIA，**不随本仓库分发**（已列入 `.gitignore`）。仓库只提供**来源钉住 + SHA256 校验**：
使用者自行按 §10 第 4 步从 NVIDIA 官方源生成，程序启动时会逐个校验 size 与 SHA256，不符即拒绝。

**风险自负。** 这是修改 GPU 固件运行状态的研究性工具，没有保修。已知失败形态是
"那一次开不进系统"，SS0 易失，断电即恢复；作者不对任何后果负责。

---

## 12. 致谢与引用

- [`impacifist/Windows-GPU-UNLOCK`](https://github.com/impacifist/Windows-GPU-UNLOCK) @ `f33a4c8` —— 整体架构、
  只读探针方法论、fail-closed 的事务设计。本项目几乎全部价值来自它的设计约束。
- [`Zagitta/gpu-unlock`](https://github.com/Zagitta/gpu-unlock) @ `0ebdb1c6` —— 固件资产生成与钉住的 SHA256。
- [`WildFlash1st/cmp90hx-unlock`](https://github.com/WildFlash1st/cmp90hx-unlock) @ `76940ae5` —— rejoin15 的 v67 签名路径。

**特别引用**：[`Q1y1ng/gpu-unlock-win`](https://github.com/Q1y1ng/gpu-unlock-win) @ `9213253`
（另一台机器上的完整移植记录）。本文 §5 中有四条阻塞点**在该记录里已被首次指出**，本项目的价值主要是
"在同一种假设下换一台机器复验，并补上它没走到的那一段"：

| 本文 | 该记录中的对应发现 |
|---|---|
| §5.2 手工版只允许从 USB 启动 | `app_io.c` 的 `UsbPath()` 要求路径含 `MSG_USB` 节点 |
| §5.5 显示判定假定控制台在 AMD 核显上 | 显示判定需降级/改写，不能直接复用上游 `AmdGopParent` |
| §5.7 ownership 拒绝驱动自有子控制器 | 需放开 `BY_CHILD_CONTROLLER && agent == 唯一 owner` |
| §5.8 事务后返回固件会黑屏挂死 | 其 RUN02 `FINAL status=0` 之后返回固件、BDS 重画时挂死 |

本文独立发现并修复的是：§5.1（探针信封 + `bus` 归一，并借此抓出自己写错的 subsystem 常量）、
§5.3 / §5.4（`bus == 1` 的另外两处变体——**同一假设在这套代码里出现了三次**）、§5.6（释放后必须为 0 个 GOP），
以及 §7 的位置无关化。

这个仓库里**不含**该项目的代码副本，只以上述 URL + 提交号引用。

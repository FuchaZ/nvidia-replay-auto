# NvidiaInstantReplayAuto

> 游戏启动前自动确认 NVIDIA 即时回放（Instant Replay）已开启，游戏退出后自动关闭。
> 零依赖、零注入、不模拟按键 —— 走 NVIDIA App **官方本地 MCP 接口**。

---

## 为什么需要它

NVIDIA App 的「即时回放」只有一个全局开关：**要么一直开着，要么一直关着**。
没有「只在我玩游戏时开启」这个选项，结果是：

- 一直开着 → 平时也在后台缓冲，多占显存和磁盘写入，看视频/远程桌面时还会被强制关闭
- 一直关着 → 打出精彩操作时才发现没在录，精彩瞬间已经没了

本项目补上这个缺口：**按游戏进程自动开关**。

## 和别的项目有什么不同

| 项目 | 方式 | 局限 |
|---|---|---|
| [AlwaysShadow](https://github.com/Verpous/AlwaysShadow) | 模拟 `Alt+Shift+F10` 按键 | 只能「一直开着」；模拟按键可能干扰输入法 |
| [ShadowPlay_Patcher](https://github.com/furyzenblade/ShadowPlay_Patcher) | 内存注入破解 DRM 检测 | 是「防止被关闭」而非「按需开启」；每次重启要重打补丁 |
| **本项目** | NVIDIA App 官方 MCP HTTP 接口 | 需要 NVIDIA App 11.0.9.5xx 及以上 |

本项目的做法是直接调用 NVIDIA App 自带的本地 MCP 服务（`http://127.0.0.1:13508/mcp`）：

- ✅ **不注入任何进程**
- ✅ **不模拟任何按键**（不会干扰输入法）
- ✅ **不依赖任何 AI Agent**（只是走它暴露的 HTTP 接口，本机回环）

## 核心特性

### 1. 按安装路径识别游戏，不写死进程名

Steam 游戏读 `appmanifest_*.acf`，只认**真正已安装**的游戏：

- 自动跳过残留目录、未安装完的游戏
- 自动排除 OBS Studio、Wallpaper Engine、MyDockFinder、Lossless Scaling 等工具类程序

WeGame 扫描 `rail_apps`，并排除反作弊、启动器、性能采集等辅助程序：

- `AntiCheatExpert`（ACE 反作弊服务）
- `Metaperf`（性能采集）
- `WeGameLauncher`、`tinydl`
- `*卸载*`、`*setup*`、`*crashreport*` 等

> 这一步很关键。以《三角洲行动》为例，它的目录里有 20 多个辅助 exe。
> 如果不排除，游戏退出后反作弊服务还在跑，回放就永远不会关闭。

### 2. 手动操作永远优先

脚本的逻辑刻意做得很「克制」：

| 时机 | 行为 |
|---|---|
| 游戏启动 | 读一次状态，**关着才开**，已开着就什么都不做 |
| 游戏进行中 | **完全不干预**（零 MCP 调用） |
| 游戏退出 | **只有脚本自己开的**才关闭 |

也就是说：

- 你手动开着回放 → 脚本不碰它，游戏退出后也不关
- 你游戏中手动关掉 → 脚本全程不管，一局之内不会覆盖你的选择

### 3. 自动探测游戏库（拷过去就能用）

不需要改任何路径：

- Steam 库：读注册表 `HKCU\Software\Valve\Steam\SteamPath` + `libraryfolders.vdf`
  （**支持多硬盘多库**）
- WeGame：按盘符扫描 `WeGameApps\rail_apps`
- Epic（可选）：读 `%ProgramData%\Epic\...\Manifests\*.item`
- 其他平台：用 `-ExtraGameDirs` 手动补

### 4. 真正的无窗口运行

`powershell.exe` 是控制台程序，`-WindowStyle Hidden` 对它**无效**（依然会闪黑窗）。
本项目通过 `run-hidden.vbs` 以窗口样式 0 启动，实测完全无窗口。

## 环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11 |
| 显卡 | NVIDIA GeForce（驱动 551.52+） |
| NVIDIA App | **11.0.9.5xx 或更高版本** |
| PowerShell | 系统自带 5.1 即可（无需装 PowerShell 7） |
| AI Agent | **不需要** |

> ⚠️ **无需安装任何 AI 软件**。但需要在 NVIDIA App 设置里开启
> 「允许 AI 智能体控制（Control）NVIDIA App」——这只是让 NVIDIA App
> 在本机 `127.0.0.1:13508` 开一个接口，和我们装不装 Agent 无关。

## 安装

### 方法一：双击安装（推荐，给不熟悉命令行的朋友）

1. 到 [Releases](https://github.com/FuchaZ/nvidia-replay-auto/releases) 下载最新的 `.zip`
2. 解压到任意位置（**不要在压缩包里直接运行**，要先解压）
3. 双击 **`install.bat`**
4. 按提示确认即可

安装脚本会自动：

- 检查环境（PowerShell / NVIDIA App 接口连通性）
- 注册**登录时自启**的计划任务
- 立即启动一次，不用等下次开机
- **打印识别到的游戏清单**，让你确认哪些游戏会生效

> 安装完会看到类似这样的清单：
>
> ```
> 识别到 17 个游戏，它们启动时会自动开启即时回放：
>
>   [Steam] 共 16 个
>     · BeamNG.drive
>     · Black Myth: Wukong
>     · Counter-Strike 2
>     ...
>   [WeGame] 共 1 个
>     · DeltaForce
> ```

### 方法二：命令行

```powershell
git clone https://github.com/FuchaZ/nvidia-replay-auto.git
cd nvidia-replay-auto
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

### 卸载

双击 **`uninstall.bat`**，会：

- 删除开机自启的计划任务
- 结束正在运行的实例
- 之后可以整个文件夹删掉

> 卸载不会改动你的 NVIDIA App 设置。即时回放当前是什么状态，卸载后就保持什么状态。

### 只看识别到哪些游戏（不安装）

双击 `list-games.bat`，或：

```powershell
powershell -ExecutionPolicy Bypass -File .\_list-games.ps1
```

### 想先看看会监控哪些游戏（含路径与自检）

```powershell
powershell -ExecutionPolicy Bypass -File .\NvidiaInstantReplayAuto.ps1 -DryRun
```

输出示例：

```
Steam：已登记 16 个游戏目录（来源 d:\steam\steamapps）
WeGame：已登记 1 个游戏目录（来源 D:\WeGameApps\rail_apps）
[DryRun] 已解析 17 个游戏目录：
  --- Steam (16) ---
    Counter-Strike 2
      d:\steam\steamapps\common\Counter-Strike Global Offensive
    ...
  --- WeGame (1) ---
    DeltaForce
      D:\WeGameApps\rail_apps\DeltaForce(2001918)
[DryRun] 抽查结果：7/7 通过
```

## 命令行参数

```powershell
# 游戏退出后不关闭回放（只负责开）
.\NvidiaInstantReplayAuto.ps1 -NoAutoDisable

# 只检查一次，不做任何更改
.\NvidiaInstantReplayAuto.ps1 -DryRun

# 手动指定 Steam 库（默认自动探测）
.\NvidiaInstantReplayAuto.ps1 -SteamAppsDirs 'D:\SteamLibrary\steamapps'

# 纳入 Epic 游戏
.\NvidiaInstantReplayAuto.ps1 -IncludeEpic

# 补充其他平台的游戏目录
.\NvidiaInstantReplayAuto.ps1 -ExtraGameDirs 'E:\Games\SomeGame'

# 追加排除项
.\NvidiaInstantReplayAuto.ps1 -ExcludeTools 'MyTool'
```

## 工作日志

默认写在脚本同目录的 `replay-auto.log`，超过 1 MB 自动轮转为 `.old`。

```
2026-10-23 09:41:05 [INFO] 检测到游戏运行：cs2
2026-10-23 09:41:09 [INFO] 即时回放原本是关闭的 → 已自动开启
2026-10-23 10:15:33 [INFO] 游戏已退出：cs2 → 即时回放已关闭
```

## 技术细节

### MCP 接口的两个坑（都已绕开）

排查过程中的实测发现，供后来者参考：

**1. 会话槽位有限**

正常 MCP 流程要先 `initialize` 拿 `Mcp-Session-Id`。但 NVIDIA 的实现里会话槽位很少，
占满后返回 `503 Too many active sessions`，而且空闲会话**迟迟不回收**。

→ 解法：跳过 `initialize`，直接 `POST tools/call`（无状态调用）。实测功能完全正常。

**2. 调用频率限制**

连续调用会返回 `Rate limited: too many tool calls. Try again in 20s.`

→ 解法：全局节流（两次调用至少间隔 3 秒），并识别限流响应自动退避。

### 为什么「游戏进行中完全不干预」

早期版本会在回放被关掉时自动补开。但这会**覆盖用户的手动操作** ——
脚本无法区分「NVIDIA 把它踢了」和「用户主动关的」。

现在改成「只在游戏启动瞬间确认一次」，用 `$sessionHandled` 标志跟踪会话状态：

- 天然实现「手动优先」
- 顺带解决了「先开游戏、后开脚本」时永不触发的问题

### 关于 VBScript 弃用

用 `run-hidden.vbs` 隐藏窗口，但 VBScript 在 Windows 11 24H2+ 已被微软标记弃用。

`install.ps1` 会实际运行一次探针检测可用性；万一未来不可用，会**自动回退**为直接调用
`powershell.exe`（功能正常，只是黑窗会回来）。

## 已知限制

- 只支持 NVIDIA App **11.0.9.5xx+**（更早的 GeForce Experience 没有 MCP 接口）
- 需要 NVIDIA App 在运行。若它完全退出，日志会记录「读取回放状态失败」
- 远程控制/串流软件（如 GameViewer、ToDesk）运行时会触发 NVIDIA 的
  「受保护内容」检测，导致回放被系统强制关闭。这是 NVIDIA 的行为，脚本无法绕过
- 混合显卡笔记本上若回放不稳定，可尝试关闭 NVIDIA App 的「桌面捕获」

## 许可

MIT

<#
.SYNOPSIS
    游戏启动前自动确认 NVIDIA「即时回放」已开启，游戏退出后自动关闭。

.DESCRIPTION
    后台常驻，按「安装路径」识别游戏，而不是写死进程名：

      · Steam  → 读取 steamapps 下的 appmanifest_*.acf，只认真正已安装的游戏，
                 自动跳过 OBS Studio / Wallpaper Engine / MyDockFinder 等工具类程序
      · WeGame → 扫描 rail_apps 下每个游戏目录，排除反作弊、启动器、性能采集等辅助程序

    行为（刻意做得很少，避免覆盖你的手动操作）：
      1. 检测到游戏启动 → 读一次回放状态；关着就开，已开着就什么都不做
      2. 游戏进行中     → 完全不干预（不查询、不切换）
      3. 检测到游戏退出 → 只有当回放是「本脚本开启的」时才关闭

    第 3 条是关键：如果游戏启动前回放就已经开着（你自己开的），退出后脚本不会去关它，
    这样你的手动设置永远是最高优先级。

    通过 NVIDIA App 自带的本地 MCP 服务 (http://127.0.0.1:13508/mcp) 控制，不需要第三方 EXE。

.PARAMETER SteamAppsDirs
    Steam 的 steamapps 目录，可多个（多库场景）。默认 D:\Steam\steamapps。

.PARAMETER WeGameAppsDirs
    WeGame 的游戏根目录。默认 D:\WeGameApps\rail_apps。

.PARAMETER ExcludeTools
    Steam 目录里要额外排除的非游戏程序（按 installdir 名字比对）。

.PARAMETER PollSeconds
    进程扫描间隔（秒）。路径扫描约 100~150ms，默认 3 秒足够且几乎不占资源。

.PARAMETER NoAutoDisable
    游戏退出后不自动关闭回放。

.PARAMETER LogFile
    日志路径，默认脚本同目录 replay-auto.log。

.EXAMPLE
    pwsh -File .\NvidiaInstantReplayAuto.ps1

.EXAMPLE
    # 只观察不关闭，并额外排除某个程序
    pwsh -File .\NvidiaInstantReplayAuto.ps1 -NoAutoDisable -ExcludeTools 'Easy Cat Timer'
#>
[CmdletBinding()]
param(
    # 留空则自动探测。显式指定时以指定的为准。
    [string[]]$SteamAppsDirs = @(),
    [string[]]$WeGameAppsDirs = @(),
    [string[]]$ExtraGameDirs = @(),   # 其他平台的游戏目录，手动补充
    [switch]$IncludeEpic,             # 是否纳入 Epic 游戏
    [string[]]$ExcludeTools = @(
        'OBS Studio'          # 录屏工具，会和回放抢编码器
        'wallpaper_engine'    # 壁纸引擎，开机常驻
        'MyDockFinder'        # 桌面美化，开机常驻
        'Lossless Scaling'    # 补帧工具
        'Soundpad'            # 变声/音板
        'Easy Cat Timer'      # 番茄钟小工具
        'Steamworks Shared'   # 公共运行库，不是游戏
    ),
    [int]$PollSeconds = 3,
    [switch]$NoAutoDisable,
    [switch]$DryRun,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http | Out-Null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $LogFile) { $LogFile = Join-Path $ScriptDir 'replay-auto.log' }

# ---------------------------------------------------------------- 自动探测游戏库
# 参数留空时自动发现 Steam / WeGame（可选 Epic）的游戏目录，
# 这样整个文件夹拷到别的电脑也能直接用，不需要改路径。
$discovery = Join-Path $ScriptDir 'discovery.ps1'
$EpicGameDirs = @()

if (Test-Path $discovery) {
    . $discovery

    if (-not $SteamAppsDirs -or $SteamAppsDirs.Count -eq 0) {
        $SteamAppsDirs = @(Get-SteamLibraryDirs)
    }
    if (-not $WeGameAppsDirs -or $WeGameAppsDirs.Count -eq 0) {
        $WeGameAppsDirs = @(Get-WeGameGameDirs)
    }
    if ($IncludeEpic) {
        $EpicGameDirs = @(Get-EpicGameDirs)
    }
} else {
    Write-Information "未找到 discovery.ps1，跳过自动探测（需手动指定目录参数）" -InformationAction Continue
}

# ---------------------------------------------------------------- 单实例
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\NvidiaInstantReplayAuto')
    if (-not $mutex.WaitOne(0)) {
        Write-Information '另一个实例已在运行，退出。' -InformationAction Continue
        exit 0
    }
} catch {
    $mutex = $null
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    # 用 Write-Information 而不是 Write-Host / Write-Output：
    #   · Write-Host 在无控制台的计划任务里写到看不见的窗口，且无法重定向
    #   · Write-Output 会混进函数的返回值管道 —— 本函数被 Get-TargetRoots 等
    #     「有意返回数组」的函数调用，一旦用 Write-Output 就会把日志字符串
    #     一起塞进返回数组（曾导致游戏目录从 17 个变成 19 个）
    #   · Write-Information 走独立的信息流，既不污染返回值，也不会报错
    Write-Information $line -InformationAction Continue

    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding utf8
    } catch { }
}

# ---------------------------------------------------------------- MCP 客户端
# 走「无状态」调用：跳过 initialize，直接 POST tools/call。
#   - NVIDIA 的 initialize 会占会话槽位，槽位满后返回 503 "Too many active sessions"，
#     而且空闲会话很久不回收。常驻脚本绝不能那样用，否则会把自己和别的客户端一起锁死。
#   - 无状态调用对 status / toggle_instant_replay 均可正常读取状态与切换。
$McpUri = 'http://127.0.0.1:13508/mcp'
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(15)
$script:LastCallAt = [datetime]::MinValue
$script:MinCallGapSeconds = 3   # 两次 MCP 调用的最小间隔，避免触发 Rate limit

function Invoke-McpTool {
    param([string]$ToolName, [hashtable]$Arguments = @{})

    # NVIDIA 的 MCP 有频率限制（"Rate limited: too many tool calls. Try again in 20s."），
    # 所以这里做全局节流：任意两次调用之间至少间隔 MinCallGapSeconds。
    $since = ((Get-Date) - $script:LastCallAt).TotalSeconds
    if ($since -lt $script:MinCallGapSeconds) {
        Start-Sleep -Milliseconds ([int](($script:MinCallGapSeconds - $since) * 1000))
    }

    $body = @{
        jsonrpc = '2.0'
        id      = 2
        method  = 'tools/call'
        params  = @{ name = $ToolName; arguments = $Arguments }
    } | ConvertTo-Json -Depth 8 -Compress

    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $McpUri)
        $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
        $req.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream') | Out-Null

        $resp = $script:Http.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } catch {
        Write-Log "MCP 请求异常：$($_.Exception.Message)" 'WARN'
        return $null
    }
    finally {
        $script:LastCallAt = Get-Date
    }

    # 兼容 SSE 与纯 JSON 两种响应
    $payload = $null
    foreach ($ln in ($text -split "`n")) {
        if ($ln -match '^data:\s*(\{.*\})\s*$') { $payload = $Matches[1]; break }
    }
    if (-not $payload -and $text.TrimStart().StartsWith('{')) { $payload = $text }

    if (-not $payload) {
        Write-Log "MCP 响应无法解析：HTTP $([int]$resp.StatusCode) $text" 'WARN'
        return $null
    }

    $j = $payload | ConvertFrom-Json
    if ($j.error) {
        if ($j.error.message -match 'Rate limited.*?(\d+)\s*s') {
            $wait = [int]$Matches[1]
            Write-Log "MCP 被限流，休眠 ${wait}s" 'WARN'
            Start-Sleep -Seconds $wait
            return $null
        }
        Write-Log "MCP 工具报错 ($ToolName)：$($j.error.message)" 'WARN'
        return $null
    }
    return $j.result
}

function Get-ReplayState {
    $res = Invoke-McpTool -ToolName 'nvapp_overlay_get_status'
    if (-not $res -or -not $res.structuredContent) { return $null }
    return [pscustomobject]@{
        ReplayOk = [bool]$res.structuredContent.instantReplayEnabled
    }
}

function Set-Replay {
    param([bool]$Enable)
    $res = Invoke-McpTool -ToolName 'nvapp_overlay_capture' -Arguments @{
        action = 'toggle_instant_replay'
        enable = $Enable
    }
    return ($null -ne $res)
}

# ---------------------------------------------------------------- 目标路径
# 排除：路径中任意一级目录命中这些名字（游戏自带的辅助程序）
$ExcludeDirSegments = @(
    'AntiCheatExpert'   # ACE 反作弊，常驻服务
    'Metaperf'          # 性能采集
    'Redist'            # 运行库安装包
    'WeGameLauncher'    # WeGame 启动器
    'tinydl'            # WeGame 下载器
    '_CommonRedist'
    'Steamworks Shared'
)

# 排除：文件名命中这些模式（卸载/崩溃/安装/更新等辅助程序）
$ExcludeFilePatterns = @(
    '*卸载*', '*uninstall*', '*bugreport*', '*crashreport*', '*crashreportclient*',
    '*setup*', '*prereq*', '*vcredist*', '*dxsetup*', '*repair*',
    '*update*', '*helper*', '*service*', '*daemon*', '*download*'
)

function Get-TargetRoots {
    <#
        构建需要监控的游戏安装目录列表。
        Steam：只取 appmanifest 登记过的游戏，天然过滤掉残留目录和工具类程序
        WeGame：取 rail_apps 下每个游戏目录
        Epic  ：取清单里登记的安装目录（需 -IncludeEpic）
        其余 ：由 -ExtraGameDirs 手动补充
    #>
    $roots = @()

    foreach ($appsDir in $SteamAppsDirs) {
        if (-not (Test-Path $appsDir)) {
            Write-Log "Steam 目录不存在，跳过：$appsDir" 'WARN'
            continue
        }
        $commonDir = Join-Path $appsDir 'common'
        $count = 0
        foreach ($acf in Get-ChildItem $appsDir -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
            $raw = Get-Content $acf.FullName -Raw -ErrorAction SilentlyContinue
            if (-not ($raw -match '"installdir"\s+"([^"]+)"')) { continue }

            $installDir = $Matches[1]
            if ($ExcludeTools -contains $installDir) { continue }

            $full = Join-Path $commonDir $installDir
            if (Test-Path $full) {
                $roots += $full
                $count++
            }
        }
        Write-Log "Steam：已登记 $count 个游戏目录（来源 $appsDir）"
    }

    foreach ($wgDir in $WeGameAppsDirs) {
        if (-not (Test-Path $wgDir)) {
            Write-Log "WeGame 目录不存在，跳过：$wgDir" 'WARN'
            continue
        }
        $count = 0
        foreach ($g in Get-ChildItem $wgDir -Directory -ErrorAction SilentlyContinue) {
            $roots += $g.FullName
            $count++
        }
        Write-Log "WeGame：已登记 $count 个游戏目录（来源 $wgDir）"
    }

    if ($IncludeEpic -and $EpicGameDirs) {
        foreach ($ep in $EpicGameDirs) {
            if (Test-Path $ep) { $roots += $ep }
        }
        Write-Log "Epic：已登记 $(@($EpicGameDirs | Where-Object { Test-Path $_ }).Count) 个游戏目录"
    }

    foreach ($extra in $ExtraGameDirs) {
        if (Test-Path $extra) {
            $roots += $extra
        } else {
            Write-Log "额外目录不存在，跳过：$extra" 'WARN'
        }
    }

    # 统一成「小写 + 结尾不带反斜杠」，方便前缀匹配
    return @($roots | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() } | Select-Object -Unique)
}

function Test-TargetPath {
    param([string]$Path, [string[]]$Roots)

    if (-not $Path) { return $false }
    $lower = $Path.ToLowerInvariant()

    # 1) 必须落在某个游戏根目录下（用反斜杠边界，避免 Foo 匹配到 Foobar）
    $hit = $null
    foreach ($root in $Roots) {
        if ($lower.StartsWith($root + '\')) { $hit = $root; break }
    }
    if (-not $hit) { return $false }

    # 2) 相对路径里不能出现辅助程序目录
    $relative = $lower.Substring($hit.Length + 1)
    foreach ($seg in ($relative -split '\\')) {
        foreach ($ex in $ExcludeDirSegments) {
            if ($seg -eq $ex.ToLowerInvariant()) { return $false }
        }
    }

    # 3) 文件名不能命中辅助程序模式
    $leaf = Split-Path $lower -Leaf
    foreach ($pat in $ExcludeFilePatterns) {
        if ($leaf -like $pat) { return $false }
    }

    return $true
}

function Get-RunningGames {
    <#
        扫描当前进程，返回落在目标目录里的游戏进程。
        只枚举一次 Get-Process；读不到的 Path（系统进程无权限）直接跳过。
    #>
    param([string[]]$Roots)

    $found = @()
    foreach ($p in Get-Process) {
        $path = $null
        try { $path = $p.Path } catch { continue }
        if (-not $path) { continue }
        if (Test-TargetPath -Path $path -Roots $Roots) {
            $found += [pscustomobject]@{
                Name = $p.ProcessName
                Path = $path
            }
        }
    }
    return $found
}

# ---------------------------------------------------------------- 主循环
# 注意：用 @() 包裹，否则只有一个游戏目录时 PowerShell 会解包成字符串，
#       导致 $roots[0] 变成首字母。
$roots = @(Get-TargetRoots)
if ($roots.Count -eq 0) {
    Write-Log '没有找到任何可监控的游戏目录，退出。' 'ERROR'
    exit 1
}

if ($DryRun) {
    # 自检模式：只打印解析结果，不碰 NVIDIA、不进入循环
    Write-Log ("[DryRun] 已解析 {0} 个游戏目录：" -f $roots.Count)
    foreach ($r in $roots) { Write-Log "    $r" }

    Write-Log '[DryRun] 扫描当前进程的匹配结果：'
    $hit = @(Get-RunningGames -Roots $roots)
    if ($hit.Count -eq 0) {
        Write-Log '    （当前没有游戏在运行）'
    } else {
        foreach ($h in $hit) { Write-Log ("    ✓ {0}  <-  {1}" -f $h.Name, $h.Path) }
    }

    Write-Log '[DryRun] 抽查：确认辅助程序会被正确排除'
    # 基于实际 roots[0] 动态构造用例，这样在真实库和测试库都能验证
    $probe = @(
        @{ P = ($roots[0] + '\FakeGame.exe');                                                  Want = $true  ; D = '根目录下的主程序' }
        @{ P = ($roots[0] + '\Binaries\AntiCheatExpert\ACE-Service.exe');                      Want = $false ; D = '反作弊目录，应排除' }
        @{ P = ($roots[0] + '\game\bin\win64\cs2.exe');                                        Want = $true  ; D = '深层主程序' }
        @{ P = ($roots[0] + '\setup.exe');                                                     Want = $false ; D = '安装程序，应排除' }
        @{ P = ($roots[0] + '\CrashReportClient.exe');                                         Want = $false ; D = '崩溃上报，应排除' }
        @{ P = 'D:\Steam\steamapps\commonX\sneaky.exe';                                        Want = $false ; D = '前缀相同但并非其子目录' }
        @{ P = 'C:\Windows\explorer.exe';                                                      Want = $false ; D = '系统进程' }
    )
    $fail = 0
    foreach ($t in $probe) {
        $got = Test-TargetPath -Path $t.P -Roots $roots
        $ok = ($got -eq $t.Want)
        if (-not $ok) { $fail++ }
        Write-Log ("  [{0}] 期望={1,-5} 实际={2,-5}  {3}  ({4})" -f `
                $(if ($ok) { 'OK  ' } else { 'FAIL' }), $t.Want, $got, $t.D, (Split-Path $t.P -Leaf))
    }

    Write-Log ("[DryRun] 抽查结果：{0}/{1} 通过" -f ($probe.Count - $fail), $probe.Count)
    Write-Log '[DryRun] 完成，未做任何更改。'
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { } }
    exit $(if ($fail -eq 0) { 0 } else { 1 })
}

Write-Log ("准备就绪：{0} 个游戏目录，扫描间隔 {1}s，退出后{2}" -f `
        $roots.Count, $PollSeconds, $(if ($NoAutoDisable) { '保留回放' } else { '自动关闭' }))

$sessionAutoOpened = $false   # 本次游戏会话的回放是否是「本脚本开启的」
$sessionHandled = $false      # 本次游戏会话是否已做过「启动确认」
$lastNames = ''               # 用于退出日志

try {
    while ($true) {
        try {
            # @() 包裹：只有一个游戏进程时 PowerShell 会解包成单个对象，
            # 后面用到 .Count / 管道展开会出错。
            $games = @(Get-RunningGames -Roots $roots)
            $nowRunning = $games.Count -gt 0

            # 用「会话是否已处理」而不是「状态是否翻转」来判断，
            # 这样脚本后启动、游戏已经在跑时也能正确触发一次。
            if ($nowRunning -and -not $sessionHandled) {
                # ---------- 进入游戏会话：确认一次回放状态 ----------
                $names = ($games | Select-Object -ExpandProperty Name -Unique) -join ', '
                $lastNames = $names
                Write-Log "检测到游戏运行：$names"

                $state = Get-ReplayState
                if ($null -eq $state) {
                    Write-Log '读取回放状态失败（NVIDIA App 可能没在运行或 Overlay 未启用）' 'WARN'
                    $sessionAutoOpened = $false
                }
                elseif ($state.ReplayOk) {
                    Write-Log '即时回放已开启，保持原状'
                    $sessionAutoOpened = $false
                }
                else {
                    Set-Replay -Enable $true | Out-Null
                    $sessionAutoOpened = $true
                    Write-Log '即时回放原本是关闭的 → 已自动开启'
                }

                # 无论成功与否都标记为已处理：本局不再重复尝试，
                # 免得反复打 NVIDIA 接口，也免得覆盖你中途的手动操作。
                $sessionHandled = $true
            }
            elseif (-not $nowRunning -and $sessionHandled) {
                # ---------- 离开游戏会话：按约定决定是否关闭 ----------
                if ($NoAutoDisable) {
                    Write-Log "游戏已退出：$lastNames（-NoAutoDisable，保留回放）"
                }
                elseif (-not $sessionAutoOpened) {
                    # 回放是启动前就开着的（你手动开的），不碰它
                    Write-Log "游戏已退出：$lastNames（回放由你保持开启，不自动关闭）"
                }
                else {
                    $state = Get-ReplayState
                    if ($state -and $state.ReplayOk) {
                        Set-Replay -Enable $false | Out-Null
                        Write-Log "游戏已退出：$lastNames → 即时回放已关闭"
                    }
                    else {
                        Write-Log "游戏已退出：$lastNames（回放已不在开启状态）"
                    }
                }

                $sessionHandled = $false
                $sessionAutoOpened = $false
            }

            # 游戏进行中（$sessionHandled 已为 true）：什么都不做，控制权完全留给你
        } catch {
            Write-Log "循环异常：$($_.Exception.Message)" 'ERROR'
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
}

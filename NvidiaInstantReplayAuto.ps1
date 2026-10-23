<#
.SYNOPSIS
    游戏启动前自动确认 NVIDIA「即时回放」(Instant Replay) 已开启，游戏退出后自动关闭。

.DESCRIPTION
    按「安装路径」识别游戏，而不是写死进程名（Steam / WeGame / Epic / 独立安装）。
    运行参数全部来自同目录 settings.conf；游戏枚举由 discovery.ps1 的
    Get-GameRootItems 提供 —— 主程序、清单工具、诊断、安装器共用同一份实现，
    因此「安装时打印的清单」「诊断显示的清单」「运行时真正监控的集合」三者永远一致。

    行为（刻意做得很少，避免覆盖你的手动操作）：
      1. 检测到游戏启动 → 读一次回放状态；关着才开，已开着就什么都不做
      2. 游戏进行中     → 完全不干预（不查询、不切换）
      3. 检测到游戏退出 → 只有当回放是「本脚本确认开启成功的」时才关闭

    通过 NVIDIA App 自带的本地 MCP 服务 (http://127.0.0.1:13508/mcp) 控制，
    不需要第三方 EXE，不注入进程，也不模拟按键。

.PARAMETER NoAutoDisable
    强制游戏退出后不关闭回放（覆盖 settings.conf 的 AutoDisableOnExit）。

.PARAMETER DryRun
    自检模式：只打印解析结果与抽查用例，不碰 NVIDIA、不进入循环。

.PARAMETER LogFile
    日志路径，默认脚本同目录 replay-auto.log。

.EXAMPLE
    pwsh -File .\NvidiaInstantReplayAuto.ps1

.EXAMPLE
    # 先看会监控哪些游戏、有没有被误排除
    pwsh -File .\NvidiaInstantReplayAuto.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$NoAutoDisable,
    [switch]$DryRun,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http | Out-Null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $LogFile) { $LogFile = Join-Path $ScriptDir 'replay-auto.log' }

# ---------------------------------------------------------------- 共享工具 + 运行参数
$discovery = Join-Path $ScriptDir 'discovery.ps1'
if (-not (Test-Path $discovery)) {
    Write-Error "缺少 discovery.ps1（应与本脚本同目录），无法继续。"
    exit 1
}
. $discovery

$Settings = Get-Settings -Dir $ScriptDir

# ---------------------------------------------------------------- 单实例
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\NvidiaInstantReplayAuto')
    if (-not $mutex.WaitOne(0)) {
        Write-Information '另一个实例已在运行，退出。' -InformationAction Continue
        exit 0
    }
} catch {
    # 拿不到 Global\ 互斥体时降级为「无单实例保护」，但必须留下痕迹：
    # 否则两个实例并发会一个开一个关，互相打架且毫无日志可查。
    $mutex = $null
    Write-Information "[WARN] 无法创建全局互斥体（$($_.Exception.Message)），单实例保护失效" -InformationAction Continue
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    # 用 Write-Information：Write-Host 在无控制台计划任务里写进看不见的窗口，
    # Write-Output 会污染「有意返回数组」的函数返回值（曾导致游戏目录多出日志字符串）。
    Write-Information $line -InformationAction Continue

    Write-LogRaw $line
}

function Write-LogRaw {
    <#
        写日志到文件。永不抛异常 —— 目录不可写时改写到 %LOCALAPPDATA%，
        再失败就静默丢弃，总之不能拖垮监控循环。
    #>
    param([string]$Line)

    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length -gt 1MB)) {
            Move-Item $LogFile "$LogFile.old" -Force -ErrorAction SilentlyContinue
        }
    } catch { }

    try {
        Add-Content -Path $LogFile -Value $Line -Encoding utf8 -ErrorAction Stop
        return
    } catch { }

    if (-not $script:FallbackLog) {
        $dir = Join-Path $env:LOCALAPPDATA 'NvidiaInstantReplayAuto'
        try {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $script:FallbackLog = Join-Path $dir 'replay-auto.log'
        } catch {
            $script:FallbackLog = $null
        }
        if ($script:FallbackLog) {
            Write-Information "日志目录不可写，改用：$script:FallbackLog" -InformationAction Continue
        }
    }
    if ($script:FallbackLog) {
        try { Add-Content -Path $script:FallbackLog -Value $Line -Encoding utf8 -ErrorAction SilentlyContinue } catch { }
    }
}

# ---------------------------------------------------------------- MCP 客户端
# 走「无状态」调用：跳过 initialize，直接 POST tools/call。
#   - NVIDIA 的 initialize 会占会话槽位，槽位满后返回 503 "Too many active sessions"，
#     而且空闲会话很久不回收。常驻脚本绝不能那样用。
#   - 无状态调用对 status / toggle_instant_replay 均可正常读取与切换。
$McpUri = 'http://127.0.0.1:13508/mcp'
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(15)
$script:LastCallAt = [datetime]::MinValue
$script:MinCallGapSeconds = 3   # 两次 MCP 调用的最小间隔，避免触发 Rate limit
$script:LastScanNoPath = 0

function Invoke-McpTool {
    param([string]$ToolName, [hashtable]$Arguments = @{})

    # 全局节流：任意两次调用至少间隔 MinCallGapSeconds。
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

    $resp = $null
    $req = $null
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
        # 常驻进程必须及时释放请求/响应，否则 socket 缓慢堆积
        if ($resp) { try { $resp.Dispose() } catch { } }
        if ($req) { try { $req.Dispose() } catch { } }
        $script:LastCallAt = Get-Date
    }

    # 兼容 SSE 与纯 JSON 两种响应
    $payload = $null
    foreach ($ln in ($text -split "`n")) {
        if ($ln -match '^data:\s*(\{.*\})\s*$') { $payload = $Matches[1]; break }
    }
    if (-not $payload -and $text.TrimStart().StartsWith('{')) { $payload = $text }

    if (-not $payload) {
        Write-Log "MCP 响应无法解析：$text" 'WARN'
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
        Write-Log "MCP 协议错误 ($ToolName)：$($j.error.message)" 'WARN'
        return $null
    }
    return $j.result
}

function Get-ReplayState {
    $res = Invoke-McpTool -ToolName 'nvapp_overlay_get_status'
    if (-not $res -or $res.isError -or -not $res.structuredContent) { return $null }
    return [bool]$res.structuredContent.instantReplayEnabled
}

function Set-Replay {
    <#
        设置回放状态，并回读确认真的生效，返回是否成功。
        关键：实测发现 NVIDIA 的 MCP 业务失败时返回的是 result.isError=true
        （而不是 jsonrpc 层的 error），且有时返回 "turned on" 却并未真正开启。
        所以只看「有没有 result」是不可信的 —— 必须以「回读 == 目标」为唯一判据。
    #>
    param([bool]$Enable)

    $res = Invoke-McpTool -ToolName 'nvapp_overlay_capture' -Arguments @{
        action = 'toggle_instant_replay'
        enable = $Enable
    }

    if ($null -eq $res) { return $false }
    if ($res.isError) {
        $msg = ''
        if ($res.content) { $msg = (@($res.content) | ForEach-Object { $_.text }) -join ' ' }
        Write-Log "切换回放被拒绝：$msg" 'WARN'
        return $false
    }

    # 回读确认，对付「假成功」
    Start-Sleep -Milliseconds 1200
    $actual = Get-ReplayState
    if ($null -eq $actual) {
        Write-Log '切换后无法回读状态，按失败处理' 'WARN'
        return $false
    }
    if ($actual -ne $Enable) {
        Write-Log ("切换后回读为 {0}，与期望 {1} 不符，按失败处理" -f $actual, $Enable) 'WARN'
        return $false
    }
    return $true
}

# ---------------------------------------------------------------- 进程匹配
$ExcludeDirSegments = Get-ExcludedDirSegments
$ExcludeFilePatterns = Get-ExcludedFilePatterns

function Test-TargetPath {
    param([string]$Path, [string[]]$Roots)

    if (-not $Path) { return $false }
    $lower = $Path.ToLowerInvariant()

    # 1) 必须落在某个游戏根目录下（带反斜杠边界，避免 Foo 匹配到 Foobar）
    $hit = $null
    foreach ($root in $Roots) {
        if ($lower.StartsWith($root + '\')) { $hit = $root; break }
    }
    if (-not $hit) { return $false }

    # 2) 相对路径里不能出现辅助程序目录
    $relative = $lower.Substring($hit.Length + 1)
    foreach ($seg in ($relative -split '\\')) {
        foreach ($ex in $ExcludeDirSegments) {
            if ($seg -eq $ex) { return $false }
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
        读不到 Path 的进程（多为以管理员权限运行、而本脚本是普通权限）计入
        $script:LastScanNoPath —— 这是「开着游戏却没反应」最常见的原因。
    #>
    param([string[]]$Roots)

    $found = New-Object 'System.Collections.Generic.List[object]'
    $noPath = 0

    foreach ($p in Get-Process) {
        $path = $null
        try { $path = $p.Path } catch { $noPath++; continue }
        if (-not $path) { $noPath++; continue }
        if (Test-TargetPath -Path $path -Roots $Roots) {
            $found.Add([pscustomobject]@{ Name = $p.ProcessName; Path = $path })
        }
    }

    $script:LastScanNoPath = $noPath
    return $found.ToArray()
}

# ---------------------------------------------------------------- 主循环
# 与清单工具、诊断工具共用 Get-GameRootItems，保证看到的 == 监控的
$rootItems = @(Get-GameRootItems -Settings $Settings)
if ($rootItems.Count -eq 0) {
    Write-Log '没有找到任何可监控的游戏目录，退出。' 'ERROR'
    if ($script:Http) { try { $script:Http.Dispose() } catch { } }
    exit 1
}
$roots = @($rootItems | ForEach-Object { $_.Root })

if ($DryRun) {
    Write-Log ("[DryRun] 已解析 {0} 个游戏目录：" -f $rootItems.Count)
    foreach ($src in @('Steam', 'WeGame', 'Epic', 'Standalone', 'Extra')) {
        $group = @($rootItems | Where-Object { $_.Source -eq $src })
        if ($group.Count -eq 0) { continue }
        Write-Log ("  --- {0} ({1}) ---" -f $src, $group.Count)
        foreach ($r in $group) {
            Write-Log ("    {0}" -f $r.Name)
            Write-Log ("      {0}" -f $r.Path)
        }
    }

    Write-Log '[DryRun] 扫描当前进程的匹配结果：'
    $hit = @(Get-RunningGames -Roots $roots)
    if ($hit.Count -eq 0) {
        Write-Log '    （当前没有游戏在运行）'
    } else {
        foreach ($h in $hit) { Write-Log ("    [命中] {0}  <-  {1}" -f $h.Name, $h.Path) }
    }

    # 权限诊断
    $totalProc = @(Get-Process).Count
    Write-Log ("[DryRun] 权限检查：共 {0} 个进程，其中 {1} 个读不到可执行路径" -f $totalProc, $script:LastScanNoPath)
    if ($script:LastScanNoPath -gt ($totalProc * 0.4)) {
        Write-Log '    读不到路径的比例偏高 —— 若开着游戏却没识别，多半是权限问题。' 'WARN'
        Write-Log '    解决：右键「点此一键安装.bat」→ 以管理员身份运行。' 'WARN'
    }

    Write-Log '[DryRun] 抽查：确认辅助程序会被正确排除'
    # 全部用例基于实际 roots[0] 动态构造。
    # 之前这条 "前缀相同但并非子目录" 是写死的 D:\Steam\...，在 Steam 不在 D 盘的机器上
    # 会因为「压根不匹配任何 root」而蒙对结果，测不到真正想测的边界。
    $base = $roots[0]
    $probe = @(
        @{ P = ($base + '\FakeGame.exe');                             Want = $true;  D = '根目录下的主程序' }
        @{ P = ($base + '\Binaries\AntiCheatExpert\ACE-Service.exe'); Want = $false; D = '反作弊目录，应排除' }
        @{ P = ($base + '\game\bin\win64\cs2.exe');                   Want = $true;  D = '深层主程序' }
        @{ P = ($base + '\setup.exe');                                Want = $false; D = '安装程序，应排除' }
        @{ P = ($base + '\CrashReportClient.exe');                    Want = $false; D = '崩溃上报，应排除' }
        @{ P = ($base + 'X\sneaky.exe');                              Want = $false; D = '前缀相同但并非其子目录' }
        @{ P = 'C:\Windows\explorer.exe';                             Want = $false; D = '系统进程' }
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
    Write-Log "[DryRun] 配置：ScanStandalone=$($Settings['ScanStandalone']) IncludeEpic=$($Settings['IncludeEpic'])"
    Write-Log '[DryRun] 完成，未做任何更改。'
    if ($script:Http) { try { $script:Http.Dispose() } catch { } }
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { } }
    exit $(if ($fail -eq 0) { 0 } else { 1 })
}

$poll = [int]$Settings['PollSeconds']
$autoDisable = [bool]($Settings['AutoDisableOnExit'] -and -not $NoAutoDisable)

Write-Log ("准备就绪：{0} 个游戏目录，扫描间隔 {1}s，退出后{2}" -f `
        $roots.Count, $poll, $(if ($autoDisable) { '自动关闭' } else { '保留回放' }))

$sessionAutoOpened = $false   # 本次会话的回放是否由本脚本「确认开启成功」
$sessionHandled = $false       # 本次会话是否已做过启动确认
$lastNames = ''

try {
    while ($true) {
        try {
            $games = @(Get-RunningGames -Roots $roots)
            $nowRunning = $games.Count -gt 0

            # 用「会话是否已处理」而非「状态是否翻转」判断，
            # 这样脚本后启动、游戏已经在跑时也能正确触发一次。
            if ($nowRunning -and -not $sessionHandled) {
                $names = ($games | Select-Object -ExpandProperty Name -Unique) -join ', '
                $lastNames = $names
                Write-Log "检测到游戏运行：$names"

                $state = Get-ReplayState
                if ($null -eq $state) {
                    Write-Log '读取回放状态失败（NVIDIA App 可能没在运行或 Overlay 未启用）' 'WARN'
                    $sessionAutoOpened = $false
                }
                elseif ($state) {
                    # 本来就开着（多半是你手动开的）→ 不动，退出时也不关
                    Write-Log '即时回放已开启，保持原状'
                    $sessionAutoOpened = $false
                }
                else {
                    if (Set-Replay -Enable $true) {
                        $sessionAutoOpened = $true
                        Write-Log '即时回放原本是关闭的 → 已自动开启（回读确认生效）'
                    }
                    else {
                        # 没成功就绝不能标记为「本脚本开的」，否则退出时会去关
                        # 一个本不该由我们负责的回放，破坏「手动优先」
                        $sessionAutoOpened = $false
                        Write-Log '尝试开启即时回放未成功，本局不再干预' 'WARN'
                    }
                }

                $sessionHandled = $true
            }
            elseif (-not $nowRunning -and $sessionHandled) {
                if (-not $autoDisable) {
                    Write-Log "游戏已退出：$lastNames（配置为保留回放）"
                }
                elseif (-not $sessionAutoOpened) {
                    Write-Log "游戏已退出：$lastNames（回放非本工具开启，保持不动）"
                }
                else {
                    $state = Get-ReplayState
                    if ($state) {
                        if (Set-Replay -Enable $false) {
                            Write-Log "游戏已退出：$lastNames → 即时回放已关闭（回读确认生效）"
                        }
                        else {
                            Write-Log "游戏已退出：$lastNames → 尝试关闭回放未成功" 'WARN'
                        }
                    }
                    else {
                        Write-Log "游戏已退出：$lastNames（回放已不在开启状态）"
                    }
                }

                $sessionHandled = $false
                $sessionAutoOpened = $false
            }

            # 游戏进行中（$sessionHandled 为 true）：什么都不做，控制权完全留给你
        } catch {
            Write-Log "循环异常：$($_.Exception.Message)" 'ERROR'
        }

        Start-Sleep -Seconds $poll
    }
}
finally {
    if ($script:Http) { try { $script:Http.Dispose() } catch { } }
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { } }
}

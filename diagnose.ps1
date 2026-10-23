<#
.SYNOPSIS
    诊断工具：检查为什么没有自动开启即时回放。

.DESCRIPTION
    逐项检查每个环节，明确指出问题在哪。把输出截图发给开发者即可定位。
    游戏枚举调用 discovery.ps1 的 Get-GameRootItems，与主程序同一份实现、
    同一份 settings.conf，所以这里显示的清单就是运行时真正监控的集合。

.EXAMPLE
    双击「出问题点这里诊断.bat」
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Section($title) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}
function Pass($msg) { Write-Host "  [通过] $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "  [失败] $msg" -ForegroundColor Red }
function Warn($msg) { Write-Host "  [注意] $msg" -ForegroundColor Yellow }
function Info($msg) { Write-Host "  $msg" }

$problems = @()

# 同时匹配 powershell.exe 与 pwsh.exe —— README 教用户用 pwsh 跑脚本。
# 判据精确到「-File 指向的那份脚本」，避免把命令行里含同名子串的其他进程误判。
function Get-ScriptProcesses {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.Name -notin @('powershell.exe', 'pwsh.exe')) { return $false }
            if (-not $_.CommandLine) { return $false }
            if ($_.CommandLine -notmatch '-File\s+"?([^"]+?\.ps1)') { return $false }
            return ((Split-Path $Matches[1] -Leaf) -eq 'NvidiaInstantReplayAuto.ps1')
        })
}

# ============================================================ 1. 环境
Section '1. 运行环境'
Info ("PowerShell 版本 : " + $PSVersionTable.PSVersion)
Info ("操作系统       : " + (Get-CimInstance Win32_OperatingSystem).Caption)
Info ("当前用户       : $env:USERDOMAIN\$env:USERNAME")

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Info ("管理员权限     : $(if ($isAdmin) { '是' } else { '否' })")
Info ("脚本目录       : $here")

$need = @('NvidiaInstantReplayAuto.ps1', 'discovery.ps1', 'run-hidden.vbs', 'settings.conf')
$missing = @()
foreach ($f in $need) {
    if (-not (Test-Path (Join-Path $here $f))) { $missing += $f }
}
if ($missing.Count -eq 0) {
    Pass '脚本文件完整'
} else {
    Fail ("缺少文件：" + ($missing -join ', '))
    $problems += '脚本文件不完整'
}

# ============================================================ 2. 运行参数
Section '2. 运行参数（settings.conf）'
$settings = $null
$discovery = Join-Path $here 'discovery.ps1'
if (Test-Path $discovery) {
    . $discovery
    $settings = Get-Settings -Dir $here
    Pass '已读取 settings.conf'
    Info ("  ScanStandalone    : " + $settings['ScanStandalone'] + '   （是否扫描独立安装的游戏）')
    Info ("  IncludeEpic       : " + $settings['IncludeEpic'] + '   （是否纳入 Epic）')
    Info ("  PollSeconds       : " + $settings['PollSeconds'])
    Info ("  AutoDisableOnExit : " + $settings['AutoDisableOnExit'] + '   （退出后是否关闭回放）')
} else {
    Fail 'discovery.ps1 缺失，无法读取配置'
    $problems += 'discovery.ps1 缺失'
}

# ============================================================ 3. 计划任务
Section '3. 开机自启任务'
$taskName = 'NvidiaInstantReplayAuto'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) {
    Fail '计划任务不存在 → 没有安装成功，或被杀毒软件删除了'
    $problems += '计划任务不存在'
} else {
    Pass "计划任务已创建：$taskName"
    Info ("  状态       : " + $task.State)
    Info ("  动作       : " + $task.Actions[0].Execute)
    Info ("  参数       : " + $task.Actions[0].Arguments)
    Info ("  触发器     : " + $task.Triggers[0].CimClass.CimClassName)
    Info ("  运行权限   : " + $task.Principal.RunLevel)

    $info = Get-ScheduledTaskInfo -TaskName $taskName
    $resultText = switch ($info.LastTaskResult) {
        0 { ' (成功)' }
        267009 { ' (正在运行)' }
        267011 { ' (尚未运行)' }
        default { ' (异常!)' }
    }
    Info ("  上次运行   : " + $info.LastRunTime)
    Info ("  上次结果   : " + $info.LastTaskResult + $resultText)

    if ($info.LastTaskResult -notin @(0, 267009, 267011)) {
        Warn '任务运行结果异常，可能启动时就失败了'
        $problems += '计划任务执行异常'
    }
}

# ============================================================ 4. 脚本进程
Section '4. 后台脚本是否在运行'
$procs = Get-ScriptProcesses
if ($procs.Count -eq 0) {
    Fail '脚本没有在运行 → 这是没生效的直接原因'
    $problems += '脚本进程未运行'
} else {
    Pass "脚本正在运行（$($procs.Count) 个实例）"
    foreach ($p in $procs) { Info ("  pid=$($p.ProcessId)  ($($p.Name))") }

    # 关键校验：跑的是不是当前目录这份脚本
    #   计划任务用 IgnoreNew，若有旧实例（别的目录、旧版本）在跑，
    #   新装的配置完全不生效，但任务状态看起来一切正常 —— 极难排查。
    $expected = Join-Path $here 'NvidiaInstantReplayAuto.ps1'
    $mismatch = @()
    foreach ($p in $procs) {
        if (-not ($p.CommandLine -and $p.CommandLine -like "*$expected*")) { $mismatch += $p }
    }
    if ($mismatch.Count -gt 0) {
        Fail '运行中的实例来自其他位置，不是当前目录这份脚本！'
        foreach ($m in $mismatch) {
            Info ("  pid=$($m.ProcessId)")
            Info ("    实际: $($m.CommandLine)")
        }
        Info ("    期望: $expected")
        Info '  这会导致「装完了但行为没变」。解决办法：'
        Info '    1) 双击「点此一键卸载.bat」'
        Info '    2) 再双击「点此一键安装.bat」'
        $problems += '运行实例路径不一致'
    } else {
        Pass '运行实例路径正确（就是当前目录这份脚本）'
    }
}

# ============================================================ 5. NVIDIA App 接口
Section '5. NVIDIA App 接口'
$mcpOk = $false
try {
    $mcpOk = (Test-NetConnection -ComputerName 127.0.0.1 -Port 13508 -WarningAction SilentlyContinue).TcpTestSucceeded
} catch { }

if (-not $mcpOk) {
    Fail '连接不上 127.0.0.1:13508'
    Info '  请在 NVIDIA App → 设置 → 开启「允许 AI 智能体控制 NVIDIA App」'
    $problems += 'NVIDIA App 接口不通'
} else {
    Pass '端口 13508 可连接'
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        $http = New-Object System.Net.Http.HttpClient
        $http.Timeout = [TimeSpan]::FromSeconds(10)
        $body = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nvapp_overlay_get_status","arguments":{}}}'
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, 'http://127.0.0.1:13508/mcp')
        $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
        $req.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream') | Out-Null
        $resp = $http.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $resp.Dispose()
        $req.Dispose()
        $http.Dispose()

        $payload = $null
        foreach ($ln in ($text -split "`n")) {
            if ($ln -match '^data:\s*(\{.*\})\s*$') { $payload = $Matches[1]; break }
        }
        if (-not $payload -and $text.TrimStart().StartsWith('{')) { $payload = $text }

        if ($payload) {
            $j = $payload | ConvertFrom-Json
            if ($j.result -and $j.result.structuredContent) {
                Pass '能读取即时回放状态'
                Info ("  即时回放当前: " + $(if ($j.result.structuredContent.instantReplayEnabled) { '开启' } else { '关闭' }))
                Info ("  桌面捕获    : " + $(if ($j.result.structuredContent.desktopCapture) { '开启' } else { '关闭' }))
            } elseif ($j.error) {
                Fail ("接口返回错误：" + $j.error.message)
                $problems += 'NVIDIA 接口报错'
            } else {
                Warn '接口返回了无法识别的内容'
                Info ("  原始: " + $text.Substring(0, [Math]::Min(300, $text.Length)))
            }
        } else {
            Fail '接口无有效响应'
            $problems += 'NVIDIA 接口无响应'
        }
    } catch {
        Fail ("调用接口失败：" + $_.Exception.Message)
        $problems += 'NVIDIA 接口调用失败'
    }
}

# ============================================================ 6. 游戏目录识别
Section '6. 游戏目录识别'
$games = @()
if ($settings) {
    try {
        $games = @(Get-GameRootItems -Settings $settings)
    } catch {
        Fail ("枚举游戏失败：" + $_.Exception.Message)
    }
}

if ($games.Count -eq 0) {
    Fail '没有识别到任何游戏目录'
    $problems += '未识别到游戏'
} else {
    Pass "识别到 $($games.Count) 个游戏"
    foreach ($g in $games) {
        Info ("  · " + $g.Name)
        Info ("      " + $g.Path)
    }
}

# ============================================================ 7. 权限差异检测
Section '7. 权限差异检测（重点）'
Info '有些游戏以管理员权限运行时，普通权限的脚本读不到它的路径。'
Info '下面检查当前是否有「读不到路径」的进程。'
Write-Host ''

$allProcs = @(Get-Process)
$noPathCount = 0
foreach ($p in $allProcs) {
    try { $pth = $p.Path } catch { $pth = $null }
    if (-not $pth) { $noPathCount++ }
}

Info ("读不到路径的进程数: $noPathCount / $($allProcs.Count)")

$runningGames = @()
foreach ($p in $allProcs) {
    try { $pth = $p.Path } catch { $pth = $null }
    if (-not $pth) { continue }
    foreach ($g in $games) {
        if ($pth.ToLowerInvariant().StartsWith($g.Path.ToLowerInvariant() + '\')) {
            $runningGames += [pscustomobject]@{ Name = $p.ProcessName; Path = $pth }
            break
        }
    }
}

if ($runningGames.Count -gt 0) {
    Pass '当前正在运行的游戏（能被识别）：'
    foreach ($rg in $runningGames) { Info ("  · $($rg.Name)  ->  $($rg.Path)") }
} else {
    Warn '当前没有识别到正在运行的游戏'
    Info '  如果你现在就开着游戏，说明脚本读不到游戏路径 —— 这是权限问题。'
    Info '  解决办法：右键「点此一键安装.bat」→ 以管理员身份运行。'
    $problems += '可能读不到游戏路径'
}

# ============================================================ 8. 日志
Section '8. 日志文件'
# 必须包含兜底路径：安装目录不可写时主程序会改写到 %LOCALAPPDATA%，
# 漏掉这一项会让正好需要诊断的用户得到「从未成功启动过」的错误结论。
$logCandidates = @(
    (Join-Path $here 'replay-auto.log'),
    (Join-Path $here 'log\replay-auto.log'),
    (Join-Path $env:LOCALAPPDATA 'NvidiaInstantReplayAuto\replay-auto.log')
)
$foundLog = $false
foreach ($lc in $logCandidates) {
    if (Test-Path $lc) {
        $foundLog = $true
        $fi = Get-Item $lc
        Pass "找到日志：$lc"
        Info ("  大小: $($fi.Length) 字节，最后写入: $($fi.LastWriteTime)")
        Info '  最近 10 行：'
        Get-Content $lc -Tail 10 | ForEach-Object { Info "    $_" }
    }
}
if (-not $foundLog) {
    Warn '没有找到日志文件 → 脚本可能从未成功启动过'
    Info ("  已检查过：")
    foreach ($lc in $logCandidates) { Info "    $lc" }
    $problems += '无日志文件'
}

# ============================================================ 总结
Section '诊断结论'
if ($problems.Count -eq 0) {
    Write-Host '  没有发现明显问题。' -ForegroundColor Green
    Write-Host '  请开着游戏再运行一次本诊断，看第 7 项能否识别到游戏。' -ForegroundColor Green
} else {
    Write-Host '  发现以下问题：' -ForegroundColor Yellow
    $i = 1
    foreach ($p in $problems) {
        Write-Host "    $i. $p" -ForegroundColor Yellow
        $i++
    }
}

Write-Host ''
Write-Host '把本窗口的内容截图发给开发者即可定位问题。' -ForegroundColor White
Write-Host ''

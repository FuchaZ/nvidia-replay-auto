<#
.SYNOPSIS
    一键安装 / 卸载 NvidiaInstantReplayAuto 的开机自启。

.DESCRIPTION
    双击 install.bat   → 安装
    双击 uninstall.bat → 卸载

    安装后会注册一个「用户登录时自动启动」的计划任务，
    所以以后开机登录就会自动运行，不需要手动开。

.PARAMETER Uninstall
    卸载：删除计划任务并结束正在运行的实例。

.PARAMETER UseVbs
    强制使用 VBS 静默启动（默认自动探测 VBScript 是否可用）。

.PARAMETER TaskName
    计划任务名称，默认 NvidiaInstantReplayAuto。
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$UseVbs,
    [string]$TaskName = 'NvidiaInstantReplayAuto'
)

$ErrorActionPreference = 'Stop'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script  = Join-Path $here 'NvidiaInstantReplayAuto.ps1'
$vbs     = Join-Path $here 'run-hidden.vbs'
$ps      = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$wscript = "$env:SystemRoot\System32\wscript.exe"

function Write-Ok($msg)   { Write-Host "  [OK] $msg"   -ForegroundColor Green }
function Write-Info($msg) { Write-Host "  $msg" }
function Write-Warn($msg) { Write-Host "  [!] $msg"    -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [X] $msg"    -ForegroundColor Red }

function Stop-RunningInstances {
    $n = 0
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'NvidiaInstantReplayAuto' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $n++
        }
    return $n
}

# ============================================================ 卸载
if ($Uninstall) {
    Write-Host ''
    Write-Host '卸载 NVIDIA 即时回放自动开关' -ForegroundColor Cyan
    Write-Host '----------------------------------------'

    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Ok "已删除开机自启任务：$TaskName"
    } else {
        Write-Info "未找到计划任务（可能已经卸载过了）"
    }

    $killed = Stop-RunningInstances
    if ($killed -gt 0) {
        Write-Ok "已结束 $killed 个正在运行的实例"
    } else {
        Write-Info "没有正在运行的实例"
    }

    Write-Host ''
    Write-Host '卸载完成！' -ForegroundColor Green
    Write-Host '  现在可以把这个文件夹整个删掉了。'
    Write-Host ''
    Write-Host '  注意：本工具不会修改你的 NVIDIA App 设置。' -ForegroundColor Yellow
    Write-Host '        即时回放当前是什么状态，卸载后就保持什么状态。' -ForegroundColor Yellow
    Write-Host ''
    return
}

# ============================================================ 安装
Write-Host ''
Write-Host 'NVIDIA 即时回放自动开关 - 安装' -ForegroundColor Cyan
Write-Host '----------------------------------------'
Write-Host ''
Write-Host '这个工具会做一件事：' -ForegroundColor White
Write-Host '  你启动游戏时自动打开 NVIDIA 即时回放，退出游戏时自动关闭。'
Write-Host ''
Write-Host '检查环境...'
Write-Host ''

# --- 文件检查 ---
if (-not (Test-Path $script)) {
    Write-Err "找不到主脚本：$script"
    Write-Err '请确认整个文件夹是完整下载的，不要只拷单个文件。'
    throw '主脚本缺失'
}
Write-Ok "主程序       : NvidiaInstantReplayAuto.ps1"

if (-not (Test-Path $ps)) {
    Write-Err "找不到 PowerShell：$ps"
    throw 'PowerShell 缺失'
}
Write-Ok "PowerShell   : 系统自带 5.1"

$discovery = Join-Path $here 'discovery.ps1'
if (Test-Path $discovery) {
    Write-Ok "游戏库探测   : 已就绪（自动找 Steam / WeGame）"
} else {
    Write-Warn "游戏库探测   : discovery.ps1 缺失，需要手动指定游戏目录"
}

# --- 决定启动方式 ---
$useSilent = $false
if (-not (Test-Path $vbs)) {
    Write-Warn "静默启动器   : run-hidden.vbs 缺失，将使用会闪窗的方式"
}
elseif (-not (Test-Path $wscript)) {
    Write-Warn "静默启动器   : 系统缺少 wscript.exe，将使用会闪窗的方式"
}
else {
    $probe = Join-Path $env:TEMP "~nv_vbs_probe_$PID.vbs"
    try {
        Set-Content -Path $probe -Value 'WScript.Echo "OK"' -Encoding ASCII
        $r = & "$env:SystemRoot\System32\cscript.exe" //nologo $probe 2>&1
        $useSilent = ($r -match 'OK')
    } catch {
        $useSilent = $false
    } finally {
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
    }

    if ($useSilent) {
        Write-Ok "静默启动器   : 可用（运行时不显示窗口）"
    } else {
        Write-Warn "静默启动器   : VBScript 不可用，运行时会看到一个小黑窗（不影响功能）"
    }
}

# --- 检查 NVIDIA App ---
Write-Host ''
Write-Host '检查 NVIDIA App...'
$nvApp = Get-Process 'NVIDIA App' -ErrorAction SilentlyContinue
$mcpOk = $false
try {
    $mcpOk = (Test-NetConnection -ComputerName 127.0.0.1 -Port 13508 -WarningAction SilentlyContinue).TcpTestSucceeded
} catch { }

if ($mcpOk) {
    Write-Ok "NVIDIA App 接口 : 可连接 (127.0.0.1:13508)"
} else {
    Write-Warn "NVIDIA App 接口 : 连不上 127.0.0.1:13508"
    Write-Warn "  请打开 NVIDIA App → 设置 → 开启「允许 AI 智能体控制 NVIDIA App」"
    Write-Warn "  这一步是必须的，否则工具无法控制即时回放。"
    Write-Warn "  注意：这只是开一个本机接口，不需要你安装任何 AI 软件。"
}

# --- 构造计划任务 ---
if ($useSilent) {
    $action = New-ScheduledTaskAction -Execute $wscript -Argument "`"$vbs`"" -WorkingDirectory $here
} else {
    $action = New-ScheduledTaskAction -Execute $ps `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`"" `
        -WorkingDirectory $here
}

$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew
$settings.DisallowStartIfOnBatteries = $false
$settings.StopIfGoingOnBatteries     = $false
$settings.RestartInterval = 'PT1M'
$settings.RestartCount    = 999

# RunLevel Highest（最高权限）是必须的：
#   Steam / 反作弊游戏常以管理员权限启动，普通权限的脚本读不到它们的
#   可执行文件路径（Get-Process 的 .Path 返回 null），就会静默跳过、
#   表现为「启动游戏没反应」。
$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Highest

Write-Host ''
Write-Host '设置开机自动启动...'

$old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($old) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Info '（已覆盖旧的安装）'
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description '游戏启动前自动确认 NVIDIA 即时回放已开启，游戏退出后自动关闭（若回放由脚本开启）。' | Out-Null

Write-Ok "已创建计划任务：$TaskName"
Write-Info "  触发时机 : 你每次登录 Windows 时"
Write-Info "  电池模式 : 允许运行（笔记本也生效）"
Write-Info "  崩溃恢复 : 每分钟重试，最多 999 次"

# --- 立即启动一次 ---
Write-Host ''
Write-Host '立即启动一次（不用等下次开机）...'
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5

$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'NvidiaInstantReplayAuto' }
if ($running) {
    Write-Ok "已在后台运行 (pid=$($running[0].ProcessId))"
} else {
    Write-Warn '没有检测到运行中的实例，请查看同目录的 replay-auto.log'
}

# --- 列出识别到的游戏 ---
Write-Host ''
Write-Host '扫描你电脑上的游戏...' -ForegroundColor White
Write-Host ''

$gameList = @()
try {
    # 用独立进程跑一次枚举，避免和已启动的后台实例抢互斥锁
    $listScript = Join-Path $here '_list-games.ps1'
    if (Test-Path $listScript) {
        $raw = & $ps -NoProfile -ExecutionPolicy Bypass -File $listScript -Json -ScanStandalone 2>$null
        if ($raw) {
            $parsed = $raw | ConvertFrom-Json
            $gameList = @($parsed)
        }
    }
} catch {
    Write-Warn "扫描游戏时出错：$($_.Exception.Message)"
}

if ($gameList.Count -eq 0) {
    Write-Warn '没有识别到任何游戏目录。'
    Write-Warn '可能原因：Steam / WeGame 装在非标准位置，或还没安装游戏。'
    Write-Warn '可以用 -ExtraGameDirs 参数手动添加游戏目录。'
} else {
    Write-Host ("识别到 {0} 个游戏，它们启动时会自动开启即时回放：" -f $gameList.Count) -ForegroundColor Green
    Write-Host ''

    foreach ($src in @('Steam', 'WeGame', 'Epic', 'Standalone', 'Extra')) {
        $group = @($gameList | Where-Object { $_.Source -eq $src })
        if ($group.Count -eq 0) { continue }

        Write-Host ("  [{0}] 共 {1} 个" -f $src, $group.Count) -ForegroundColor Cyan
        foreach ($g in ($group | Sort-Object Name)) {
            Write-Host ("    · {0}" -f $g.Name)
        }
        Write-Host ''
    }

    Write-Host '  如果这里有你不希望被监控的程序，可以双击 uninstall.bat 卸载，' -ForegroundColor Yellow
    Write-Host '  或参考 README 用 -ExcludeTools 参数排除。' -ForegroundColor Yellow
    Write-Host ''
}

# --- 说明 ---
Write-Host ''
Write-Host '============================================' -ForegroundColor Green
Write-Host '  安装完成！' -ForegroundColor Green
Write-Host '============================================' -ForegroundColor Green
Write-Host ''
Write-Host '现在开始：' -ForegroundColor White
Write-Host '  · 你启动游戏 → 自动打开即时回放'
Write-Host '  · 你退出游戏 → 自动关闭即时回放'
Write-Host '  · 你自己手动开关的结果，工具不会覆盖'
Write-Host ''
Write-Host '后台会一直运行，开机自动启动，不需要你管。' -ForegroundColor White
Write-Host ''
Write-Host '常用操作：' -ForegroundColor White
Write-Host '  · 想卸载     → 双击「点此一键卸载.bat」'
Write-Host '  · 查看游戏清单 → 双击「查看游戏清单.bat」'
Write-Host '  · 出问题排查 → 双击「出问题点这里诊断.bat」'
Write-Host ''
Write-Host '日志文件位置：' -ForegroundColor White
Write-Host "  $here\replay-auto.log"
Write-Host '  （如果这个目录不可写，会自动改写到：）'
Write-Host "  $env:LOCALAPPDATA\NvidiaInstantReplayAuto\replay-auto.log"
Write-Host ''
Write-Host '日志里能看到：什么时候检测到哪个游戏、回放有没有被成功打开。' -ForegroundColor White
Write-Host ''

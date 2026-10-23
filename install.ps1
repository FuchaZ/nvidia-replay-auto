<#
.SYNOPSIS
    一键安装 / 卸载 NvidiaInstantReplayAuto 的登录自启计划任务。

.DESCRIPTION
    自动定位同目录下的 run-hidden.vbs，注册计划任务。
    因为路径全部相对脚本自身位置计算，整个文件夹拷到任何电脑都能直接用。

.PARAMETER Uninstall
    卸载计划任务。

.PARAMETER UseVbs
    强制使用 VBS 静默启动（默认自动探测 VBScript 是否可用）。

.PARAMETER TaskName
    计划任务名称，默认 NvidiaInstantReplayAuto。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$UseVbs,
    [string]$TaskName = 'NvidiaInstantReplayAuto'
)

$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'NvidiaInstantReplayAuto.ps1'
$vbs    = Join-Path $here 'run-hidden.vbs'
$ps     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$wscript = "$env:SystemRoot\System32\wscript.exe"

function Write-Step($msg) { Write-Host "  $msg" }

# ---------------------------------------------------------------- 卸载
if ($Uninstall) {
    Write-Host '卸载计划任务...'
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Step "已移除任务：$TaskName"
    } else {
        Write-Step "任务不存在：$TaskName"
    }
    # 结束残留实例
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'NvidiaInstantReplayAuto' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Step "已结束进程 pid=$($_.ProcessId)"
        }
    Write-Host '卸载完成。'
    return
}

# ---------------------------------------------------------------- 前置检查
Write-Host '检查环境...'

if (-not (Test-Path $script)) { throw "找不到主脚本：$script" }
Write-Step "主脚本     : $script"

if (-not (Test-Path $ps)) { throw "找不到 PowerShell：$ps" }
Write-Step "PowerShell : $ps"

$discovery = Join-Path $here 'discovery.ps1'
if (Test-Path $discovery) { Write-Step "自动探测   : 已就绪" }
else { Write-Step "自动探测   : 缺失（需手动指定目录参数）" }

# ---------------------------------------------------------------- 决定启动方式
$useSilent = $false
if ($UseVbs -or (Test-Path $vbs)) {
    if (-not (Test-Path $vbs)) {
        Write-Step "警告：指定了 -UseVbs 但找不到 run-hidden.vbs，将退回直调"
    }
    elseif (-not (Test-Path $wscript)) {
        Write-Step "警告：系统缺少 wscript.exe，将退回直调（会有窗口）"
    }
    else {
        # 真正跑一次探针，确认 VBScript 引擎可用
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
        if ($useSilent) { Write-Step "启动方式   : VBS 静默（无窗口）" }
        else { Write-Step "启动方式   : VBScript 不可用，退回直调（会有窗口）" }
    }
}

# ---------------------------------------------------------------- 构造动作
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

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

# ---------------------------------------------------------------- 注册
$old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($old) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Step '已移除旧的同名任务'
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description '游戏启动前自动确认 NVIDIA 即时回放已开启，游戏退出后自动关闭（若回放由脚本开启）。' | Out-Null

Write-Host ''
Write-Host '安装完成！' -ForegroundColor Green
Write-Step "任务名     : $TaskName"
Write-Step "触发器     : 用户登录时"
Write-Step "动作       : $($action.Execute)"

# 立即启动一次，省得等下次登录
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5

$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'NvidiaInstantReplayAuto' }
if ($running) {
    Write-Step "已启动     : pid=$($running[0].ProcessId)"
} else {
    Write-Step "提示       : 未检测到运行中的实例，可查看 replay-auto.log 排查"
}
Write-Host ''
Write-Host '提示：首次使用前，请在 NVIDIA App 设置里开启「允许 AI 智能体控制 NVIDIA App」' -ForegroundColor Yellow
Write-Host '      （这只开一个本机 127.0.0.1 接口，不需要任何 AI 软件）' -ForegroundColor Yellow
Write-Host '      想先看看会监控哪些游戏：powershell -File .\NvidiaInstantReplayAuto.ps1 -DryRun' -ForegroundColor Yellow

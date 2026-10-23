<#
.SYNOPSIS
    列出会触发自动开启即时回放的游戏。

.DESCRIPTION
    游戏枚举直接调用 discovery.ps1 的 Get-GameRootItems —— 和主程序、诊断工具
    用的是同一份实现与同一份 settings.conf，所以这里显示的清单
    就是运行时真正会监控的集合，不会再出现「清单 N 个、实际 M 个」。

.PARAMETER Json
    输出 JSON（供 install.ps1 / diagnose.ps1 消费）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\_list-games.ps1
#>
[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$discovery = Join-Path $here 'discovery.ps1'
if (-not (Test-Path $discovery)) {
    if ($Json) { '[]' } else { Write-Host '缺少 discovery.ps1，无法枚举游戏。' }
    return
}
. $discovery

$settings = Get-Settings -Dir $here
$items = @(Get-GameRootItems -Settings $settings)

if ($Json) {
    # -InputObject 保证空数组也输出 []，而不是空字符串
    ConvertTo-Json -InputObject @($items) -Compress -Depth 3
    return
}

if ($items.Count -eq 0) {
    Write-Host '没有识别到任何游戏目录。'
    Write-Host ''
    Write-Host '可能原因：'
    Write-Host '  · Steam / WeGame 装在非标准位置'
    Write-Host '  · 还没安装任何游戏'
    Write-Host ''
    Write-Host '也可以在 settings.conf 里把 ScanStandalone 设为 true，'
    Write-Host '让工具扫描各盘符的常见游戏目录（含官网下载的独立游戏）。'
    return
}

Write-Host ("识别到 {0} 个游戏：" -f $items.Count)
Write-Host ''
foreach ($src in @('Steam', 'WeGame', 'Epic', 'Standalone', 'Extra')) {
    $group = @($items | Where-Object { $_.Source -eq $src })
    if ($group.Count -eq 0) { continue }
    Write-Host ("[{0}] 共 {1} 个" -f $src, $group.Count)
    foreach ($g in ($group | Sort-Object Name)) {
        Write-Host ("  · {0}" -f $g.Name)
    }
    Write-Host ''
}
Write-Host ("配置来源：{0}" -f (Join-Path $here 'settings.conf'))

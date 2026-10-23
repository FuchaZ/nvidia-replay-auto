<#
.SYNOPSIS
    列出会触发自动开启即时回放的游戏（供 install.ps1 调用）。

.DESCRIPTION
    输出 JSON 数组，每项含 Name / Path / Source。
    单独运行时也会打印成人类可读的清单。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\_list-games.ps1
#>
[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 与主脚本共用同一套探测与排除规则，避免两处逻辑跑偏
$ExcludeTools = @(
    'OBS Studio', 'wallpaper_engine', 'MyDockFinder', 'Lossless Scaling',
    'Soundpad', 'Easy Cat Timer', 'Steamworks Shared'
)

$discovery = Join-Path $here 'discovery.ps1'
if (Test-Path $discovery) {
    . $discovery
    $steamDirs = @(Get-SteamLibraryDirs)
    $wgDirs    = @(Get-WeGameGameDirs)
} else {
    $steamDirs = @()
    $wgDirs    = @()
}

$items = @()

# ---- Steam ----
foreach ($appsDir in $steamDirs) {
    if (-not (Test-Path $appsDir)) { continue }
    $commonDir = Join-Path $appsDir 'common'
    foreach ($acf in Get-ChildItem $appsDir -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
        $raw = Get-Content $acf.FullName -Raw -ErrorAction SilentlyContinue
        if (-not ($raw -match '"installdir"\s+"([^"]+)"')) { continue }

        $installDir = $Matches[1]
        if ($ExcludeTools -contains $installDir) { continue }

        $displayName = $installDir
        if ($raw -match '"name"\s+"([^"]+)"') { $displayName = $Matches[1] }

        $full = Join-Path $commonDir $installDir
        if (Test-Path $full) {
            $items += [pscustomobject]@{
                Name   = $displayName
                Path   = $full
                Source = 'Steam'
            }
        }
    }
}

# ---- WeGame ----
foreach ($wgDir in $wgDirs) {
    if (-not (Test-Path $wgDir)) { continue }
    foreach ($g in Get-ChildItem $wgDir -Directory -ErrorAction SilentlyContinue) {
        $nice = $g.Name -replace '\(\d+\)\s*$', ''
        $items += [pscustomobject]@{
            Name   = $nice
            Path   = $g.FullName
            Source = 'WeGame'
        }
    }
}

# 去重
$seen = @{}
$uniq = @()
foreach ($it in $items) {
    $k = $it.Path.ToLowerInvariant()
    if (-not $seen.ContainsKey($k)) {
        $seen[$k] = $true
        $uniq += $it
    }
}

if ($Json) {
    # 给 install.ps1 消费
    ConvertTo-Json -InputObject @($uniq) -Compress -Depth 3
    return
}

if ($uniq.Count -eq 0) {
    Write-Host '没有识别到任何游戏目录。'
    Write-Host ''
    Write-Host '可能原因：'
    Write-Host '  · Steam / WeGame 装在非标准位置'
    Write-Host '  · 还没安装任何游戏'
    Write-Host ''
    Write-Host '可以用 -ExtraGameDirs 参数手动指定游戏目录。'
    return
}

Write-Host ("识别到 {0} 个游戏：" -f $uniq.Count)
Write-Host ''
foreach ($src in @('Steam', 'WeGame', 'Epic', 'Extra')) {
    $group = @($uniq | Where-Object { $_.Source -eq $src })
    if ($group.Count -eq 0) { continue }
    Write-Host ("[{0}] 共 {1} 个" -f $src, $group.Count)
    foreach ($g in ($group | Sort-Object Name)) {
        Write-Host ("  · {0}" -f $g.Name)
    }
    Write-Host ''
}

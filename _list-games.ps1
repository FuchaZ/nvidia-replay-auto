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
    [switch]$Json,
    [switch]$ScanStandalone
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 与主脚本共用同一套探测与排除规则，避免两处逻辑跑偏
$ExcludeTools = @(
    'OBS Studio', 'wallpaper_engine', 'MyDockFinder', 'Lossless Scaling',
    'Soundpad', 'Easy Cat Timer', 'Steamworks Shared'
)

# 独立目录扫描时额外排除的「不是游戏」的程序名
$ExcludeStandaloneNames = @(
    'teamspeak 3', 'teamspeak', 'discord', 'obs studio', 'obs',
    'wallpaper engine', 'wallpaper_engine', 'mydockfinder',
    'lossless scaling', 'soundpad', 'easy cat timer',
    'steam', 'wegame', 'epic games launcher', 'battle.net',
    'gog galaxy', 'ubisoft connect', 'ea app', 'origin',
    'visual studio', 'python', 'nodejs', 'git',
    'nvidia app', 'geforce experience', 'msi afterburner', 'rivatuner',
    'chrome', 'firefox', 'edge', 'vscode'
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

# ---- Standalone（非平台游戏，按盘符常见目录扫一层）----
if ($ScanStandalone) {
    $commonParents = @(
        'Games', 'Game', '游戏', 'SteamLibrary', 'WeGameApps',
        'Program Files\Games', 'Program Files (x86)\Games',
        'Apps', 'Applications'
    )
    $drives = @()
    try {
        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Root -match '^[A-Z]:\\$' } | Select-Object -ExpandProperty Root)
    } catch { }

    foreach ($drive in $drives) {
        foreach ($parent in $commonParents) {
            $base = Join-Path $drive $parent
            if (-not (Test-Path $base)) { continue }
            foreach ($sub in Get-ChildItem $base -Directory -ErrorAction SilentlyContinue) {
                if ($ExcludeStandaloneNames -contains $sub.Name.ToLowerInvariant()) { continue }
                $exes = @(Get-ChildItem $sub.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                    Where-Object {
                        $n = $_.Name.ToLowerInvariant()
                        $n -notmatch '^(setup|install|uninstall|repair|update|crash|bugreport|dxsetup|vcredist)' -and
                        $n -notmatch '(setup|install|uninstall|repair|updater|crashreport|helper)$'
                    })
                if ($exes.Count -gt 0) {
                    $items += [pscustomobject]@{
                        Name   = $sub.Name
                        Path   = $sub.FullName
                        Source = 'Standalone'
                    }
                }
            }
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
foreach ($src in @('Steam', 'WeGame', 'Epic', 'Standalone', 'Extra')) {
    $group = @($uniq | Where-Object { $_.Source -eq $src })
    if ($group.Count -eq 0) { continue }
    Write-Host ("[{0}] 共 {1} 个" -f $src, $group.Count)
    foreach ($g in ($group | Sort-Object Name)) {
        Write-Host ("  · {0}" -f $g.Name)
    }
    Write-Host ''
}

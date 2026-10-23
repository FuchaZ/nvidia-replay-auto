# ============================================================================
#  共享真相源：运行参数 + 游戏库发现 + 排除规则
#
#  主程序 / 清单工具(_list-games) / 诊断(diagnose) / 安装器(install) 都
#  dot-source 本文件并调用同一组函数，因此「安装时打印的清单」「诊断显示的清单」
#  「运行时真正监控的集合」三者永远一致，不会再出现数量对不上。
# ============================================================================

function Get-Settings {
    <#
        读取 settings.conf，返回 hashtable。缺失/损坏时返回默认值，绝不抛异常。
    #>
    param([string]$Dir)

    if (-not $Dir) { $Dir = Split-Path -Parent $MyInvocation.MyCommand.Path }

    $defaults = [ordered]@{}
    $defaults['ScanStandalone'] = $true
    $defaults['IncludeEpic'] = $false
    $defaults['PollSeconds'] = 3
    $defaults['AutoDisableOnExit'] = $true

    $settings = @{}
    foreach ($k in $defaults.Keys) { $settings[$k] = $defaults[$k] }

    $file = Join-Path $Dir 'settings.conf'
    if (-not (Test-Path $file)) { return $settings }

    foreach ($line in (Get-Content $file -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^([A-Za-z]\w*)\s*=\s*(.+)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim()
            if (-not $settings.ContainsKey($key)) { continue }

            if ($key -eq 'PollSeconds') {
                if ($val -match '^\d+$' -and [int]$val -ge 1) { $settings[$key] = [int]$val }
            }
            elseif ($val -match '^(?i:true$)') { $settings[$key] = $true }
            elseif ($val -match '^(?i:false$)') { $settings[$key] = $false }
        }
    }
    return $settings
}

# ---------------------------------------------------------------- 排除规则（唯一一份）

# Steam/WeGame 安装目录里的工具类程序（按 installdir 名精确匹配）
function Get-ExcludedToolNames {
    return @(
        'OBS Studio', 'wallpaper_engine', 'MyDockFinder', 'Lossless Scaling',
        'Soundpad', 'Easy Cat Timer', 'Steamworks Shared'
    )
}

# 独立目录扫描时排除的「不是游戏」的程序名（小写，精确匹配目录名）
function Get-ExcludedStandaloneNames {
    return @(
        'teamspeak 3', 'teamspeak', 'discord', 'obs studio', 'obs',
        'wallpaper engine', 'wallpaper_engine', 'mydockfinder',
        'lossless scaling', 'soundpad', 'easy cat timer',
        'steam', 'wegame', 'epic games launcher', 'battle.net',
        'gog galaxy', 'ubisoft connect', 'ea app', 'origin',
        'visual studio', 'python', 'nodejs', 'git',
        'nvidia app', 'geforce experience', 'msi afterburner', 'rivatuner',
        'chrome', 'firefox', 'edge', 'vscode'
    )
}

# 游戏目录内的辅助程序目录名（小写）——判断进程路径是否算「游戏本体」时用
function Get-ExcludedDirSegments {
    return @(
        'anticheatexpert', 'metaperf', 'redist', 'wegamelauncher',
        'tinydl', '_commonredist', 'steamworks shared'
    )
}

# 辅助程序文件名模式——判断进程路径是否算「游戏本体」时用
function Get-ExcludedFilePatterns {
    return @(
        '*卸载*', '*uninstall*', '*bugreport*', '*crashreport*', '*crashreportclient*',
        '*setup*', '*prereq*', '*vcredist*', '*dxsetup*', '*repair*',
        '*update*', '*helper*', '*service*', '*daemon*', '*download*'
    )
}

# ---------------------------------------------------------------- 库路径发现

function Get-SteamLibraryDirs {
    <#
        发现所有 Steam 库（steamapps 目录）：
          1. 注册表 SteamPath → 主库
          2. libraryfolders.vdf → 其余库（多硬盘）。新版在 <root>\config\，
             旧版在 <root>\steamapps\，两份都读，缺一会漏库
          3. 常见默认位置兜底
    #>
    $found = New-Object 'System.Collections.Generic.List[string]'
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'

    foreach ($regPath in @(
            'HKCU:\Software\Valve\Steam',
            'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
            'HKLM:\SOFTWARE\Valve\Steam'
        )) {
        try {
            $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            foreach ($k in @('SteamPath', 'InstallPath')) {
                if ($props.$k) { $steamRoots.Add($props.$k) }
            }
        } catch { }
    }

    foreach ($p in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam",
            'C:\Steam', 'D:\Steam', 'E:\Steam')) {
        if ($p) { $steamRoots.Add($p) }
    }

    $seenRoot = @{}
    foreach ($root in $steamRoots) {
        if (-not $root) { continue }
        $root = $root.TrimEnd('\', '/').Replace('/', '\')
        if ($seenRoot.ContainsKey($root.ToLower())) { continue }
        $seenRoot[$root.ToLower()] = $true

        $apps = Join-Path $root 'steamapps'
        if (Test-Path $apps) { $found.Add($apps) }

        foreach ($vdf in @(
                (Join-Path $root 'config\libraryfolders.vdf'),
                (Join-Path $apps 'libraryfolders.vdf')
            )) {
            if (-not (Test-Path $vdf)) { continue }
            try {
                $raw = Get-Content $vdf -Raw -ErrorAction SilentlyContinue
                foreach ($m in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
                    $libRoot = $m.Groups[1].Value -replace '\\\\', '\'
                    $libApps = Join-Path $libRoot 'steamapps'
                    if (Test-Path $libApps) { $found.Add($libApps) }
                }
            } catch { }
        }
    }

    $uniq = @{}
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in $found) {
        $k = $f.ToLowerInvariant()
        if (-not $uniq.ContainsKey($k)) { $uniq[$k] = $true; $result.Add($f) }
    }
    return $result.ToArray()
}

function Get-WeGameGameDirs {
    <#
        发现 WeGame 游戏根目录（rail_apps）。游戏本体不在客户端目录 D:\Wegame，
        而在 <盘符>:\WeGameApps\rail_apps\<游戏ID>\，所以按盘符扫。
    #>
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    try {
        foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $p = Join-Path $drive.Root 'WeGameApps\rail_apps'
            if (Test-Path $p) { $candidates.Add($p) }
        }
    } catch { }

    foreach ($regPath in @(
            'HKCU:\Software\Tencent\WeGame',
            'HKLM:\SOFTWARE\WOW6432Node\Tencent\WeGame',
            'HKLM:\SOFTWARE\Tencent\WeGame'
        )) {
        try {
            $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            foreach ($k in @('InstallPath', 'InstallDir', 'GamePath')) {
                if (-not $props.$k) { continue }
                $root = Split-Path $props.$k -Parent -ErrorAction SilentlyContinue
                $parent = Split-Path $root -Parent -ErrorAction SilentlyContinue
                foreach ($sub in @('rail_apps', 'apps')) {
                    $p = Join-Path $parent "WeGameApps\$sub"
                    if ($p -and (Test-Path $p)) { $candidates.Add($p) }
                }
            }
        } catch { }
    }

    $uniq = @{}
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $k = $c.ToLowerInvariant()
        if (-not $uniq.ContainsKey($k)) { $uniq[$k] = $true; $result.Add($c) }
    }
    return $result.ToArray()
}

function Get-EpicGameDirs {
    <#
        Epic 游戏清单：每次安装都是一个独立目录，因此按父目录去重，
        一个游戏只返回一条（父目录 = InstallLocation 的上一级）。
        返回 pscustomobject：Path + Name，方便清单显示可读名称。
    #>
    $manifestDir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path $manifestDir)) { return @() }

    $byParent = @{}
    foreach ($item in Get-ChildItem $manifestDir -Filter '*.item' -File -ErrorAction SilentlyContinue) {
        try {
            $j = Get-Content $item.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if (-not $j.InstallLocation -or -not (Test-Path $j.InstallLocation)) { continue }

            $full = $j.InstallLocation.TrimEnd('\')

            # 优先用 DisplayName（可读），其次 AppName（可能是 GUID），最后用目录名
            $name = $null
            if ($j.DisplayName) { $name = $j.DisplayName }
            elseif ($j.AppName -and $j.AppName -notmatch '^[0-9a-f]{32}$') { $name = $j.AppName }
            if (-not $name) { $name = Split-Path $full -Leaf }

            if (-not $byParent.ContainsKey($full.ToLower())) {
                $byParent[$full.ToLower()] = [pscustomobject]@{ Path = $full; Name = $name }
            }
        } catch { }
    }
    return @($byParent.Values | Sort-Object Path)
}

function Get-StandaloneGameDirs {
    <#
        发现不属于 Steam/WeGame/Epic 的独立安装游戏（官网下载的三角洲、解压即玩的）。
        只扫各盘符常见游戏根目录下一层，不递归全盘（常驻脚本不能扫太狠）。
    #>
    $result = New-Object 'System.Collections.Generic.List[string]'

    $commonParents = @(
        'Games', 'Game', '游戏', 'SteamLibrary', 'WeGameApps',
        'Program Files\Games', 'Program Files (x86)\Games',
        'Apps', 'Applications'
    )

    $exSet = @{}
    foreach ($e in (Get-ExcludedStandaloneNames)) { $exSet[$e.ToLowerInvariant()] = $true }

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
                if ($exSet.ContainsKey($sub.Name.ToLowerInvariant())) { continue }

                $hasGameExe = $false
                foreach ($exe in Get-ChildItem $sub.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue) {
                    $n = $exe.Name.ToLowerInvariant()
                    if ($n -match '^(setup|install|uninstall|repair|update|crash|bugreport|dxsetup|vcredist)') { continue }
                    if ($n -match '(setup|install|uninstall|repair|updater|crashreport|helper)') { continue }
                    $hasGameExe = $true
                    break
                }
                if ($hasGameExe) { $result.Add($sub.FullName) }
            }
        }
    }
    return $result.ToArray()
}

# ---------------------------------------------------------------- 统一枚举

function Get-GameRootItems {
    <#
        返回要监控的游戏根列表，每项含 Root / Path / Name / Source。
        是否纳入 Epic / 独立游戏由 $Settings 决定；主程序、清单、诊断都调它，
        所以三处结果必然相同。
    #>
    param(
        [hashtable]$Settings,
        [string[]]$SteamAppsDirs = @(),
        [string[]]$WeGameAppsDirs = @(),
        [string[]]$ExtraGameDirs = @()
    )

    if (-not $Settings) { $Settings = Get-Settings }
    if (-not $SteamAppsDirs -or $SteamAppsDirs.Count -eq 0) { $SteamAppsDirs = @(Get-SteamLibraryDirs) }
    if (-not $WeGameAppsDirs -or $WeGameAppsDirs.Count -eq 0) { $WeGameAppsDirs = @(Get-WeGameGameDirs) }

    $excludeTools = Get-ExcludedToolNames
    $items = New-Object 'System.Collections.Generic.List[object]'

    # ---- Steam：只认 appmanifest 登记过的游戏，天然过滤残留目录与工具类 ----
    foreach ($appsDir in $SteamAppsDirs) {
        if (-not (Test-Path $appsDir)) { continue }
        $commonDir = Join-Path $appsDir 'common'
        foreach ($acf in Get-ChildItem $appsDir -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
            $raw = Get-Content $acf.FullName -Raw -ErrorAction SilentlyContinue
            if (-not ($raw -match '"installdir"\s+"([^"]+)"')) { continue }

            $installDir = $Matches[1]
            if ($excludeTools -contains $installDir) { continue }

            $displayName = $installDir
            if ($raw -match '"name"\s+"([^"]+)"') { $displayName = $Matches[1] }

            $full = Join-Path $commonDir $installDir
            if (Test-Path $full) {
                $items.Add([pscustomobject]@{
                        Root   = $full.TrimEnd('\').ToLowerInvariant()
                        Path   = $full
                        Name   = $displayName
                        Source = 'Steam'
                    })
            }
        }
    }

    # ---- WeGame：rail_apps 下每个游戏目录 ----
    foreach ($wgDir in $WeGameAppsDirs) {
        if (-not (Test-Path $wgDir)) { continue }
        foreach ($g in Get-ChildItem $wgDir -Directory -ErrorAction SilentlyContinue) {
            $nice = $g.Name -replace '\(\d+\)\s*$', ''
            $items.Add([pscustomobject]@{
                    Root   = $g.FullName.TrimEnd('\').ToLowerInvariant()
                    Path   = $g.FullName
                    Name   = $nice
                    Source = 'WeGame'
                })
        }
    }

    # ---- Epic（可选）----
    if ($Settings['IncludeEpic']) {
        foreach ($ep in (Get-EpicGameDirs)) {
            $items.Add([pscustomobject]@{
                    Root   = $ep.Path.TrimEnd('\').ToLowerInvariant()
                    Path   = $ep.Path
                    Name   = $ep.Name
                    Source = 'Epic'
                })
        }
    }

    # ---- 手动补充 ----
    foreach ($extra in $ExtraGameDirs) {
        if (Test-Path $extra) {
            $items.Add([pscustomobject]@{
                    Root   = $extra.TrimEnd('\').ToLowerInvariant()
                    Path   = $extra
                    Name   = (Split-Path $extra -Leaf)
                    Source = 'Extra'
                })
        }
    }

    # ---- 独立游戏（可选）----
    if ($Settings['ScanStandalone']) {
        foreach ($sd in (Get-StandaloneGameDirs)) {
            $items.Add([pscustomobject]@{
                    Root   = $sd.TrimEnd('\').ToLowerInvariant()
                    Path   = $sd
                    Name   = (Split-Path $sd -Leaf)
                    Source = 'Standalone'
                })
        }
    }

    # 按路径去重（同一游戏可能被多个来源登记）
    $seen = @{}
    $uniq = New-Object 'System.Collections.Generic.List[object]'
    foreach ($it in $items) {
        if (-not $seen.ContainsKey($it.Root)) { $seen[$it.Root] = $true; $uniq.Add($it) }
    }
    return $uniq.ToArray()
}

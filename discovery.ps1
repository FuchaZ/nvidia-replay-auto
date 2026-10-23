# ============================================================================
#  自动发现：Steam / WeGame / Epic / GOG 游戏库
#  本文件由 NvidiaInstantReplayAuto.ps1 dot-source 引用。
#  被 dot-source 时自动探测；若脚本显式传入了目录参数则不覆盖。
# ============================================================================

function Get-SteamLibraryDirs {
    <#
        通过以下顺序发现所有 Steam 库（steamapps 目录）：
          1. 注册表 HKCU\Software\Valve\Steam\SteamPath  → 主库
          2. 各库根下的 libraryfolders.vdf → 其余库（多硬盘常见）
          3. 常见默认位置兜底
        返回去重后的 steamapps 路径数组（只返回真实存在的）。
    #>
    $found = New-Object System.Collections.Generic.List[string]

    $steamRoots = New-Object System.Collections.Generic.List[string]

    # 1) 注册表（用户级，无需管理员）
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

    # 2) 默认位置兜底
    foreach ($p in @(
            "${env:ProgramFiles(x86)}\Steam",
            "$env:ProgramFiles\Steam",
            'C:\Steam', 'D:\Steam', 'E:\Steam'
        )) {
        if ($p) { $steamRoots.Add($p) }
    }

    # 去重并展开 libraryfolders.vdf
    $seenRoot = @{}
    foreach ($root in $steamRoots) {
        if (-not $root) { continue }
        $root = $root.TrimEnd('\', '/').Replace('/', '\')
        if ($seenRoot.ContainsKey($root.ToLower())) { continue }
        $seenRoot[$root.ToLower()] = $true

        $apps = Join-Path $root 'steamapps'
        if (Test-Path $apps) { $found.Add($apps) }

        # libraryfolders.vdf 记录其他库的位置
        $vdf = Join-Path $apps 'libraryfolders.vdf'
        if (-not (Test-Path $vdf)) { continue }
        try {
            $raw = Get-Content $vdf -Raw -ErrorAction SilentlyContinue
            # 匹配 "path"  "D:\\SteamLibrary"
            foreach ($m in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
                $libRoot = $m.Groups[1].Value -replace '\\\\', '\'
                $libApps = Join-Path $libRoot 'steamapps'
                if (Test-Path $libApps) { $found.Add($libApps) }
            }
        } catch { }
    }

    # 去重（大小写不敏感）
    $uniq = @{}
    $result = @()
    foreach ($f in $found) {
        $k = $f.ToLowerInvariant()
        if (-not $uniq.ContainsKey($k)) {
            $uniq[$k] = $true
            $result += $f
        }
    }
    return $result
}

function Get-WeGameGameDirs {
    <#
        发现 WeGame 的游戏根目录（rail_apps）。
        WeGame 装的游戏本体不在客户端目录 D:\Wegame 里，而在
        <盘符>:\WeGameApps\rail_apps\<游戏ID>\ 下，所以按盘符扫一遍。
    #>
    $candidates = New-Object System.Collections.Generic.List[string]

    # 各盘符下的标准位置
    try {
        foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $p = Join-Path $drive.Root 'WeGameApps\rail_apps'
            if (Test-Path $p) { $candidates.Add($p) }
        }
    } catch { }

    # 从注册表里 WeGame 的安装信息推断（不同版本键名不一样）
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
                foreach ($sub in @('rail_apps', 'apps')) {
                    $p = Join-Path (Split-Path $root -Parent -ErrorAction SilentlyContinue) "WeGameApps\$sub"
                    if ($p -and (Test-Path $p)) { $candidates.Add($p) }
                }
            }
        } catch { }
    }

    $uniq = @{}
    $result = @()
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $k = $c.ToLowerInvariant()
        if (-not $uniq.ContainsKey($k)) {
            $uniq[$k] = $true
            $result += $c
        }
    }
    return $result
}

function Get-EpicGameDirs {
    <#
        Epic 的游戏清单在 %ProgramData%\Epic\EpicGamesLauncher\Data\Manifests\*.item
        每个 .item 是 JSON，含 InstallLocation 和 AppName。
    #>
    $result = @()
    $manifestDir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path $manifestDir)) { return $result }

    foreach ($item in Get-ChildItem $manifestDir -Filter '*.item' -File -ErrorAction SilentlyContinue) {
        try {
            $j = Get-Content $item.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($j.InstallLocation -and (Test-Path $j.InstallLocation)) {
                $result += $j.InstallLocation.TrimEnd('\')
            }
        } catch { }
    }
    return $result
}

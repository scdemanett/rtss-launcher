# Steam helpers for RTSS Launcher, dot-sourced by Install.ps1 and Uninstall.ps1.
# Finds Steam, its accounts and installed games, and adds or removes the launcher in games'
# launch options. Launch options live in Steam\userdata\<account>\config\localconfig.vdf.
# Edits are made in place, so the rest of that file stays byte-for-byte the same.
# Steam rewrites localconfig.vdf when it exits, so it must be closed while the file is changed.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:LauncherRx = [regex]'("[^"]*RTSSLauncher\.exe"|[^\s"]*RTSSLauncher\.exe)\s*'

# ---------------------------------------------------------------- VDF (Valve KeyValues text)
function ConvertFrom-VdfString([string]$s) {
    if ($s.IndexOf('\') -lt 0) { return $s }
    return [regex]::Replace($s, '\\(.)', [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        switch -CaseSensitive ($m.Groups[1].Value) { 'n' { "`n" } 't' { "`t" } default { $m.Groups[1].Value } }
    })
}

function ConvertTo-VdfString([string]$s) { return $s.Replace('\', '\\').Replace('"', '\"') }

# Parses VDF text into nodes that remember where they are in the text.
# Block node: Key, Children, Open/Close (index of { and }). Leaf node: Key, Value, ValStart/ValEnd.
function ConvertFrom-Vdf([string]$Text) {
    $root    = @{ Key = ''; Children = New-Object System.Collections.ArrayList; Open = -1; Close = $Text.Length }
    $stack   = New-Object System.Collections.Stack
    $current = $root
    $key     = $null
    $rx = [regex]'"((?:[^"\\]|\\.)*)"|(\{)|(\})|(//[^\n]*)|([^\s{}"]+)'
    foreach ($m in $rx.Matches($Text)) {
        if ($m.Groups[4].Success) { continue }                      # // comment
        if ($m.Groups[2].Success) {                                 # {
            if ($null -eq $key) { throw "Unexpected '{' at offset $($m.Index)." }
            $node = @{ Key = $key; Children = New-Object System.Collections.ArrayList; Open = $m.Index; Close = -1 }
            [void]$current.Children.Add($node); $stack.Push($current); $current = $node; $key = $null
            continue
        }
        if ($m.Groups[3].Success) {                                 # }
            if ($null -ne $key -or $stack.Count -eq 0) { throw "Unexpected '}' at offset $($m.Index)." }
            $current.Close = $m.Index; $current = $stack.Pop()
            continue
        }
        $str = if ($m.Groups[1].Success) { ConvertFrom-VdfString $m.Groups[1].Value } else { $m.Value }
        if ($null -eq $key) { $key = $str; continue }
        [void]$current.Children.Add(@{ Key = $key; Value = $str; ValStart = $m.Index; ValEnd = $m.Index + $m.Length })
        $key = $null
    }
    if ($stack.Count -ne 0 -or $null -ne $key) { throw 'File ended inside a block.' }
    return $root
}

function Get-VdfChild($Node, [string]$Key) {
    if (-not $Node) { return $null }
    foreach ($c in $Node.Children) { if ($c.Key -eq $Key) { return $c } }   # -eq is case-insensitive, like Steam
    return $null
}

function Get-VdfPath($Node, [string[]]$Keys) {
    foreach ($k in $Keys) { $Node = Get-VdfChild $Node $k; if (-not $Node) { return $null } }
    return $Node
}

function Read-VdfFile([string]$Path) { return ConvertFrom-Vdf ([IO.File]::ReadAllText($Path, $script:Utf8NoBom)) }

# ---------------------------------------------------------------- Steam discovery
function Find-SteamDir {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($p -and $p.InstallPath) { $candidates.Add([string]$p.InstallPath) }
    }
    $p = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if ($p -and $p.SteamPath) { $candidates.Add(([string]$p.SteamPath).Replace('/', '\')) }
    $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam'))
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'steam.exe'))) { return $c } }
    return $null
}

# Installed games: AppId, Name, Dir.
function Get-SteamGames([string]$SteamDir) {
    $libs = New-Object 'System.Collections.Generic.List[string]'
    $libs.Add($SteamDir)
    $lf = Join-Path $SteamDir 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $lf) {
        try {
            $folders = Get-VdfChild (Read-VdfFile $lf) 'libraryfolders'
            foreach ($f in $folders.Children) {
                $path = Get-VdfChild $f 'path'
                if ($path -and $path.Value) { $libs.Add($path.Value) }
            }
        } catch { }
    }

    $seen  = @{}
    $games = New-Object System.Collections.ArrayList
    foreach ($lib in $libs) {
        $apps = Join-Path $lib 'steamapps'
        if ($seen.ContainsKey($apps.ToLowerInvariant()) -or -not (Test-Path -LiteralPath $apps)) { continue }
        $seen[$apps.ToLowerInvariant()] = $true
        foreach ($acf in Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
            try {
                $state = Get-VdfChild (Read-VdfFile $acf.FullName) 'AppState'
                $id = Get-VdfChild $state 'appid'; $name = Get-VdfChild $state 'name'; $dir = Get-VdfChild $state 'installdir'
                if (-not $id -or -not $dir) { continue }
                $full = Join-Path $apps (Join-Path 'common' $dir.Value)
                if (-not (Test-Path -LiteralPath $full)) { continue }
                [void]$games.Add([pscustomobject]@{ AppId = $id.Value; Name = $(if ($name) { $name.Value } else { $dir.Value }); Dir = $full })
            } catch { }
        }
    }
    return @($games | Sort-Object Name)
}

# Games whose folder holds one of the given exe names: Game, Exes.
function Find-SteamGamesByExe($Games, [string[]]$ExeNames, [int]$Depth = 4) {
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $ExeNames) { [void]$wanted.Add($e) }
    $found = New-Object System.Collections.ArrayList
    foreach ($g in $Games) {
        $exes = @(Get-ChildItem -LiteralPath $g.Dir -Filter '*.exe' -File -Recurse -Depth $Depth -ErrorAction SilentlyContinue |
                  Where-Object { $wanted.Contains($_.Name) } | ForEach-Object { $_.Name } | Sort-Object -Unique)
        if ($exes.Count) { [void]$found.Add([pscustomobject]@{ Game = $g; Exes = $exes }) }
    }
    return @($found)
}

# Steam accounts with a localconfig.vdf, most recently used first: AccountId, Name, Config.
function Get-SteamAccounts([string]$SteamDir) {
    $users = $null
    $lu = Join-Path $SteamDir 'config\loginusers.vdf'
    if (Test-Path -LiteralPath $lu) { try { $users = Get-VdfChild (Read-VdfFile $lu) 'users' } catch { } }

    $accounts = New-Object System.Collections.ArrayList
    foreach ($d in Get-ChildItem -LiteralPath (Join-Path $SteamDir 'userdata') -Directory -ErrorAction SilentlyContinue) {
        $cfg = Join-Path $d.FullName 'config\localconfig.vdf'
        if ($d.Name -notmatch '^\d+$' -or $d.Name -eq '0' -or -not (Test-Path -LiteralPath $cfg)) { continue }
        $name = "Steam account $($d.Name)"; $recent = 0; $stamp = 0
        if ($users) {
            $id64 = ([UInt64]$d.Name + [UInt64]76561197960265728).ToString()
            $u = Get-VdfChild $users $id64
            if ($u) {
                $p = Get-VdfChild $u 'PersonaName'; if ($p -and $p.Value) { $name = $p.Value }
                $r = Get-VdfChild $u 'MostRecent';  if ($r) { [void][int]::TryParse($r.Value, [ref]$recent) }
                $t = Get-VdfChild $u 'Timestamp';   if ($t) { [void][long]::TryParse($t.Value, [ref]$stamp) }
            }
        }
        [void]$accounts.Add([pscustomobject]@{ AccountId = $d.Name; Name = $name; Config = $cfg
                                               Recent = $recent; Stamp = $stamp; Written = (Get-Item -LiteralPath $cfg).LastWriteTime })
    }
    return @($accounts | Sort-Object Recent, Stamp, Written -Descending)
}

# ---------------------------------------------------------------- Steam process
function Test-SteamRunning { return [bool](Get-Process -Name 'steam' -ErrorAction SilentlyContinue) }

# Asks the running Steam to exit and waits for it. Goes through explorer so nothing is started elevated.
function Stop-Steam([string]$SteamDir, [int]$TimeoutSec = 60) {
    Start-Process explorer.exe 'steam://exit'
    $deadline = (Get-Date).AddSeconds($TimeoutSec); $nudged = $false
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-SteamRunning)) { Start-Sleep -Seconds 1; return $true }
        if (-not $nudged -and (Get-Date) -gt $deadline.AddSeconds(-$TimeoutSec + 15)) {
            & (Join-Path $SteamDir 'steam.exe') -shutdown; $nudged = $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# Starts Steam as the signed-in user, not elevated (explorer opens it in the user's own context).
function Start-SteamAsUser([string]$SteamDir) {
    Start-Process explorer.exe -ArgumentList "`"$(Join-Path $SteamDir 'steam.exe')`""
}

# ---------------------------------------------------------------- launch options
function Get-SteamAppsNode($Root) { return Get-VdfPath $Root @('UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps') }

# AppId -> current launch options, for every app that has one.
function Get-SteamLaunchOptions([string]$Text) {
    $result = @{}
    $apps = Get-SteamAppsNode (ConvertFrom-Vdf $Text)
    if ($apps) {
        foreach ($app in $apps.Children) {
            if (-not $app.ContainsKey('Children')) { continue }
            $lo = Get-VdfChild $app 'LaunchOptions'
            if ($lo -and $null -ne $lo.Value) { $result[$app.Key] = $lo.Value }
        }
    }
    return $result
}

# Removes the launcher from a launch option, keeping everything else.
function Remove-LauncherOption([string]$Current) {
    if (-not $Current -or $Current -notmatch 'RTSSLauncher\.exe') { return $Current }
    $v = $script:LauncherRx.Replace($Current, '', 1).Trim()
    if ($v -eq '%command%') { return '' }
    return $v
}

# Adds the launcher in front of the game command. An older launcher path is replaced.
function Add-LauncherOption([string]$Current, [string]$LauncherExe) {
    $wrap = "`"$LauncherExe`" %command%"
    $cur  = Remove-LauncherOption $Current
    $cur  = if ($cur) { $cur.Trim() } else { '' }
    if (-not $cur) { return $wrap }
    $i = $cur.IndexOf('%command%', [StringComparison]::OrdinalIgnoreCase)
    if ($i -ge 0) { return $cur.Substring(0, $i) + $wrap + $cur.Substring($i + 9) }
    return "$wrap $cur"      # plain arguments such as -dx9 go after the game command
}

function Get-LineIndent([string]$Text, [int]$Index) {
    $ls = $Text.LastIndexOf("`n", [Math]::Max(0, $Index - 1)) + 1
    $indent = $Text.Substring($ls, $Index - $ls)
    if ($indent.Trim()) { return @{ Start = $Index; Indent = ''; Inline = $true } }   # brace not on its own line
    return @{ Start = $ls; Indent = $indent; Inline = $false }
}

# Returns $Text with launch options set for the apps in $Changes (AppId -> new value).
function Set-SteamLaunchOptions([string]$Text, [hashtable]$Changes) {
    $root = ConvertFrom-Vdf $Text
    $apps = Get-SteamAppsNode $root
    if (-not $apps) {
        $steam = Get-VdfPath $root @('UserLocalConfigStore', 'Software', 'Valve', 'Steam')
        if (-not $steam) { throw 'localconfig.vdf has an unexpected layout (no Software\Valve\Steam block).' }
    }

    $edits  = New-Object System.Collections.ArrayList     # @{ Start; End; Text }
    $newApps = New-Object System.Text.StringBuilder
    foreach ($id in $Changes.Keys) {
        $val = '"' + (ConvertTo-VdfString $Changes[$id]) + '"'
        $app = if ($apps) { Get-VdfChild $apps $id } else { $null }
        if ($app -and $app.ContainsKey('Children')) {
            $lo = Get-VdfChild $app 'LaunchOptions'
            if ($lo) { [void]$edits.Add(@{ Start = $lo.ValStart; End = $lo.ValEnd; Text = $val }); continue }
            $at = Get-LineIndent $Text $app.Close
            $line = "$($at.Indent)`t`"LaunchOptions`"`t`t$val`n"
            if ($at.Inline) { $line = "`n$line" }
            [void]$edits.Add(@{ Start = $at.Start; End = $at.Start; Text = $line })
        } else {
            [void]$newApps.Append("`t`"$id`"`n`t{`n`t`t`"LaunchOptions`"`t`t$val`n`t}`n")
        }
    }

    if ($newApps.Length) {
        $parent = if ($apps) { $apps } else { $steam }
        $at = Get-LineIndent $Text $parent.Close
        $block = $newApps.ToString()
        if (-not $apps) { $block = "`t`"apps`"`n`t{`n" + ($block -replace '(?m)^(?=.)', "`t") + "`t}`n" }
        $block = $block -replace '(?m)^(?=.)', $at.Indent
        if ($at.Inline) { $block = "`n$block" }
        [void]$edits.Add(@{ Start = $at.Start; End = $at.Start; Text = $block })
    }

    $sb = New-Object System.Text.StringBuilder $Text
    foreach ($e in ($edits | Sort-Object { $_.Start } -Descending)) {
        [void]$sb.Remove($e.Start, $e.End - $e.Start).Insert($e.Start, $e.Text)
    }
    return $sb.ToString()
}

# Writes new launch options to one account's localconfig.vdf, with a backup and a read-back check.
function Write-SteamLaunchOptions([string]$ConfigPath, [hashtable]$Changes) {
    $text    = [IO.File]::ReadAllText($ConfigPath, $script:Utf8NoBom)
    $newText = Set-SteamLaunchOptions $text $Changes
    $check   = Get-SteamLaunchOptions $newText               # throws if the result doesn't parse
    foreach ($id in $Changes.Keys) {
        if ($check[$id] -cne $Changes[$id]) { throw "Read-back check failed for app $id; nothing was written." }
    }
    Copy-Item -LiteralPath $ConfigPath "$ConfigPath.rtsslauncher.bak" -Force
    [IO.File]::WriteAllText($ConfigPath, $newText, $script:Utf8NoBom)
}

# Closes Steam if needed, after asking. Returns 'closed', 'notrunning' or $null (user said no / failed).
function Request-SteamClosed([string]$SteamDir) {
    if (-not (Test-SteamRunning)) { return 'notrunning' }
    $a = Read-Host '  Steam must be closed to change launch options. Close Steam now? [Y/n]'
    if ($a -match '^\s*n') { return $null }
    Write-Host '  Closing Steam...'
    if (Stop-Steam $SteamDir) { return 'closed' }
    Write-Host '  Steam did not close. Close it from its tray icon (Exit), then run this again.' -ForegroundColor Yellow
    return $null
}

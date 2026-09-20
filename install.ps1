# TRENCH installer.
#
#   Right-click this file and pick "Run with PowerShell", or run:
#       powershell -ExecutionPolicy Bypass -File install.ps1
#   If the game is not on the usual Steam drive, point at it yourself:
#       powershell -ExecutionPolicy Bypass -File install.ps1 -GamePath "D:\Games\Bodycam\Bodycam\Binaries\Win64"
#
# It copies the mod into ue4ss\Mods, switches it on in mods.txt, and puts a TRENCH shortcut on
# your desktop. Your presets and settings are kept if you are installing over an older copy.
param([string]$GamePath)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $here 'TRENCH'

function Say($text, $colour = 'Gray') { Write-Host "  $text" -ForegroundColor $colour }
function Die($text) { Say $text 'Red'; Write-Host ''; Read-Host 'Press Enter to close'; exit 1 }

Write-Host ''
Write-Host '  TRENCH - bots and artillery for Bodycam' -ForegroundColor Yellow
Write-Host ''

if (-not (Test-Path $source)) { Die "The TRENCH folder is missing next to this script. Unzip the whole archive first." }

# ---- find the game -----------------------------------------------------------------
function Find-Win64 {
    if ($GamePath) { return $GamePath }
    $roots = @()
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $roots += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $roots += $m.Groups[1].Value.Replace('\\', '\')
            }
        }
    }
    $roots += 'C:\Program Files (x86)\Steam'
    foreach ($r in ($roots | Select-Object -Unique)) {
        $p = Join-Path $r 'steamapps\common\Bodycam\Bodycam\Binaries\Win64'
        if (Test-Path $p) { return $p }
    }
    return $null
}

$win64 = Find-Win64
if (-not $win64) {
    Die "Could not find Bodycam. Pass the folder yourself, for example:`n     -GamePath `"D:\SteamLibrary\steamapps\common\Bodycam\Bodycam\Binaries\Win64`""
}
Say "Game: $win64"

# ---- UE4SS has to be there already -------------------------------------------------
$ue4ss = Join-Path $win64 'ue4ss'
if (-not (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))) {
    Die @"
UE4SS is not installed in this game.

     TRENCH is a UE4SS Lua mod - it cannot run on its own. Install UE4SS first
     (https://github.com/UE4SS-RE/RE-UE4SS/releases), start the game once to
     check it loads, then run this installer again.
"@
}
Say 'UE4SS: found'

# ---- copy, keeping anything of yours -----------------------------------------------
$mods = Join-Path $ue4ss 'Mods'
$dest = Join-Path $mods 'TRENCH'
$keep = Join-Path $env:TEMP ('trench-keep-' + [guid]::NewGuid().ToString('N'))

if (Test-Path $dest) {
    New-Item -ItemType Directory -Path $keep -Force | Out-Null
    foreach ($item in 'presets', 'settings.ini') {
        $p = Join-Path $dest $item
        if (Test-Path $p) { Copy-Item $p (Join-Path $keep $item) -Recurse -Force }
    }
    Remove-Item $dest -Recurse -Force
    Say 'Existing install found - your presets and settings are being kept'
}

New-Item -ItemType Directory -Path $mods -Force | Out-Null
Copy-Item $source $dest -Recurse -Force

if (Test-Path $keep) {
    foreach ($item in 'presets', 'settings.ini') {
        $from = Join-Path $keep $item
        if (-not (Test-Path $from)) { continue }
        # Take the fresh copy out of the way first. Copy-Item onto a folder that already exists
        # puts the folder *inside* it, which quietly leaves the shipped presets in place and
        # buries yours one level down.
        $to = Join-Path $dest $item
        if (Test-Path $to) { Remove-Item $to -Recurse -Force }
        Move-Item $from $to -Force
    }
    Remove-Item $keep -Recurse -Force
}
Say "Installed: $dest"

# ---- switch it on ------------------------------------------------------------------
$modsTxt = Join-Path $mods 'mods.txt'
$lines = if (Test-Path $modsTxt) { @(Get-Content $modsTxt) } else { @() }
$lines = $lines | Where-Object { $_ -notmatch '^\s*TRENCH\s*:' }
$lines += 'TRENCH : 1'
Set-Content -Path $modsTxt -Value $lines -Encoding ASCII
Say 'Enabled in mods.txt'

# ---- the panel needs Node ----------------------------------------------------------
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if ($node) {
    Say "Node.js: $node"
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'TRENCH.lnk'
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sc.TargetPath = $node
    $sc.Arguments = '"' + (Join-Path $dest 'editor\server.js') + '"'
    $sc.WorkingDirectory = Join-Path $dest 'editor'
    $sc.IconLocation = (Join-Path $dest 'editor\trench-4.ico') + ',0'
    $sc.Description = 'TRENCH control panel'
    $sc.Save()
    Say 'Desktop shortcut: TRENCH'
} else {
    Say 'Node.js is not installed - the mod itself will work, but the control panel will not.' 'Yellow'
    Say 'Install it from https://nodejs.org (LTS), then run this installer again for the shortcut.' 'Yellow'
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Say 'Start the game, host a Team Deathmatch match, then open TRENCH from the desktop.'
Say 'In game: F5/F6 your team, F7/F8 the enemy, F9 shelling on and off.'
Write-Host ''
Read-Host 'Press Enter to close'

# Removes TRENCH: the mod folder, its line in mods.txt and the desktop shortcut.
# Your presets are copied to the desktop first, so nothing you made is thrown away.
param([string]$GamePath)

$ErrorActionPreference = 'Stop'
function Say($text, $colour = 'Gray') { Write-Host "  $text" -ForegroundColor $colour }

Write-Host ''
Write-Host '  TRENCH - uninstall' -ForegroundColor Yellow
Write-Host ''

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
if (-not $win64) { Say 'Could not find Bodycam - nothing to do.' 'Yellow'; Read-Host 'Press Enter to close'; exit }

$mods = Join-Path $win64 'ue4ss\Mods'
$dest = Join-Path $mods 'TRENCH'

if (Test-Path (Join-Path $dest 'presets')) {
    $save = Join-Path ([Environment]::GetFolderPath('Desktop')) 'TRENCH-presets'
    Copy-Item (Join-Path $dest 'presets') $save -Recurse -Force
    Say "Presets saved to $save"
}

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force; Say 'Mod folder removed' }
else { Say 'Mod folder was not there' }

$modsTxt = Join-Path $mods 'mods.txt'
if (Test-Path $modsTxt) {
    Set-Content -Path $modsTxt -Encoding ASCII `
        -Value (@(Get-Content $modsTxt) | Where-Object { $_ -notmatch '^\s*TRENCH\s*:' })
    Say 'Line removed from mods.txt'
}

$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'TRENCH.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Say 'Desktop shortcut removed' }

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Read-Host 'Press Enter to close'

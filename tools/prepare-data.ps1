# Copies your original game files into assets/game/ as <NAME>.dat so Godot exports include them.
# (assets/original/ is ignored by the editor because Godot would read MUSEUM.RES as its own .res.)
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root "assets\original"
$dst = Join-Path $root "assets\game"
New-Item -ItemType Directory -Force $dst | Out-Null
$files = Get-ChildItem $src -File | Where-Object { $_.Name -notin @(".gitkeep", ".gdignore") }
if ($files.Count -eq 0) { Write-Error "No game files in $src"; exit 1 }
foreach ($f in $files) { Copy-Item $f.FullName (Join-Path $dst ($f.Name.ToUpper() + ".dat")) -Force }
Write-Host "Copied $($files.Count) files to assets/game/"

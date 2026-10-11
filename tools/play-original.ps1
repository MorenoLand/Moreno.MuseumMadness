param(
    [string]$DosBox = "dosbox-x"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$original = Join-Path $root 'assets\original'
$runtime = Join-Path $root 'assets\runtime\museum'
$conf = Join-Path $PSScriptRoot 'museum.conf'

if (-not (Test-Path $DosBox) -and -not (Get-Command $DosBox -ErrorAction SilentlyContinue)) { throw "DOSBox-X not found: $DosBox (put it on PATH or pass -DosBox <path>)" }

if (-not (Test-Path $runtime)) {
    New-Item -ItemType Directory -Force $runtime | Out-Null
    $gdignore = Join-Path $root 'assets\runtime\.gdignore'
    if (-not (Test-Path $gdignore)) { New-Item -ItemType File $gdignore | Out-Null }
    Copy-Item (Join-Path $original '*') $runtime
    foreach ($file in Get-ChildItem $original -File) {
        $copy = Join-Path $runtime $file.Name
        if ((Get-FileHash $file.FullName).Hash -ne (Get-FileHash $copy).Hash) { throw "Copy mismatch: $($file.Name)" }
    }
}

& $DosBox -conf $conf -c "mount c $runtime" -c 'c:' -c 'MUSEUM.COM'

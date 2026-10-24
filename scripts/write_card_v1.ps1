param(
    [Parameter(Mandatory = $true)]
    [string]$Drive,
    [string]$Source = 'build\card_campus_v1',
    [switch]$Yes
)

# Write a packaged card directory (with MANIFEST.TXT) to a FAT32 TF-card root.
# Safety: back up the card root to _tf_backup/<timestamp> first, then remove
# old BMP/WAV/PLAYLIST/TEXT, then copy in MANIFEST order. The FPGA identifies
# image/audio indices by FAT32 directory order.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/write_card_v1.ps1 -Drive E
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/write_card_v1.ps1 -Drive E -Source build\card_campus_v2
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/write_card_v1.ps1 -Drive E -Source build\card_campus_v2 -Yes

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if ([System.IO.Path]::IsPathRooted($Source)) {
    $source = $Source
} else {
    $source = Join-Path $repo $Source
}
$manifestPath = Join-Path $source 'MANIFEST.TXT'

if (-not (Test-Path -LiteralPath $source)) {
    throw "source not found: $source"
}
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "manifest not found: $manifestPath"
}

$letter = $Drive.TrimEnd(':', '\')
if ($letter.Length -ne 1) {
    throw "drive must be one letter, e.g. E"
}
$volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
if ($volume.DriveType -ne 'Removable') {
    throw "$letter`: is not a removable drive (DriveType=$($volume.DriveType))"
}
if ($volume.FileSystem -ne 'FAT32') {
    throw "$letter`: is not FAT32 (FileSystem=$($volume.FileSystem)); format it as FAT32 first"
}
$root = "$letter`:\"

# Parse MANIFEST: ordered content file names and expected SHA-256.
$lines = Get-Content -LiteralPath $manifestPath
$names = @()
$expected = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s+(BMP|WAV|PLAYLIST)\s+(.+?)\s*$') {
        $name = $matches[2]
        $names += $name
        if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match 'sha256=([0-9a-fA-F]{64})') {
            $expected[$name] = $matches[1].ToLower()
        }
    }
}
if ($names.Count -eq 0) { throw "no content files found in manifest" }

Write-Host "Target : $root ($($volume.FileSystemLabel), $([math]::Round($volume.Size/1GB,2)) GB)"
Write-Host "Source : $source"
Write-Host "Files to copy (MANIFEST order):"
foreach ($name in $names) {
    $p = Join-Path $source $name
    if (-not (Test-Path -LiteralPath $p)) { throw "missing source file: $p" }
    Write-Host ("  {0}  {1} bytes" -f $name, (Get-Item -LiteralPath $p).Length)
}

if (-not $Yes) {
    $answer = Read-Host "Back up the card root, remove old BMP/WAV/PLAYLIST/TEXT, then copy? (yes/no)"
    if ($answer -ne 'yes') { throw "cancelled" }
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $repo "_tf_backup\$stamp"
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Write-Host "Backup : $backup"
Get-ChildItem -LiteralPath $root -Force |
    Where-Object { $_.Name -notin @('System Volume Information', '$RECYCLE.BIN') } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $backup -Recurse -Force
    }

# Remove only the files the FPGA scans; keep unrelated user files.
Get-ChildItem -LiteralPath $root -File -Force |
    Where-Object {
        $_.Extension -in @('.bmp', '.wav') -or
        $_.Name -in @('PLAYLIST.TXT', 'TEXT.TXT')
    } |
    Remove-Item -Force

foreach ($name in $names) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination $root -Force
}

$failed = 0
foreach ($name in $names) {
    $actual = (Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash.ToLower()
    $want = $expected[$name]
    if ($want -and $actual -eq $want) {
        Write-Host "OK   $name"
    } else {
        Write-Host "FAIL $name (expected $want, actual $actual)"
        $failed++
    }
}
if ($failed -ne 0) { throw "$failed file(s) failed hash verification" }

Write-Host ""
Write-Host "DONE. Eject the card, insert it into the board, power-cycle, and verify:"
Write-Host "  S13=image1 daily, S14=image2 warning, S15=image3 exhibition, S16=image4 evacuation"
Write-Host "  SW3 up = auto rotation should show only images 1 and 3."
Write-Host "  KEY1 long press = next WAV (daily -> emergency alert)."

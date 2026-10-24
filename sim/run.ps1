# ModelSim batch run, Windows/PowerShell port of sim/run.sh.
# Usage: powershell -File sim/run.ps1 <tb> [extra vsim args...]
# Reads sim/<tb>.v and sim/<tb>.f, rebuilds sim/work_<tb>/ and prints the vsim log.
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less .ps1 files
# with the ANSI code page, so non-ASCII comments here would break parsing.
param(
    [Parameter(Mandatory = $true)][string]$Tb,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra
)
$ErrorActionPreference = 'Stop'
$MS   = 'D:/Shop/ModelSim/win64'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $repo
if (-not (Test-Path "sim/$Tb.v")) { Write-Error "missing sim/$Tb.v"; exit 1 }

$srcs = @()
if (Test-Path "sim/$Tb.f") {
    foreach ($raw in Get-Content -Encoding UTF8 "sim/$Tb.f") {
        $line = ($raw -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -like '+incdir+*') { $srcs += '+incdir+../../' + $line.Substring(8) }
        else { $srcs += "../../$line" }
    }
}

$wd = "sim/work_$Tb"
if (Test-Path $wd) { Remove-Item -Recurse -Force $wd }
New-Item -ItemType Directory -Path $wd | Out-Null
Write-Output ("sources: " + ($srcs -join ' '))
Push-Location $wd
try {
    & "$MS/vlib.exe" work | Out-Null
    & "$MS/vlog.exe" -quiet -work work @srcs "../$Tb.v"
    if ($LASTEXITCODE -ne 0) { exit 1 }
    & "$MS/vsim.exe" -c -quiet -do 'run -all; quit -f' "work.$Tb" @Extra |
        ForEach-Object { $_ -replace '^# ', '' }
} finally {
    Pop-Location
}

# Command-line TD build, Windows/PowerShell port of scripts/td_build.sh.
# Copies td_project + user_source into a scratch dir, runs synthesis then
# place&route then bitgen, and prints the timing/area summary.
# Usage: powershell -File scripts/td_build.ps1 [-Out <dir>] [-Seed <n>] [-Area 0|1]
#   -Area 1 (default) = area-priority mapping (gate map_mode area_prior)
#   -Area 0           = timing-priority mapping (TD UI default)
# NOTE: keep this file ASCII-only (PowerShell 5.1 reads BOM-less .ps1 as ANSI).
param(
    [string]$Out = (Join-Path $env:TEMP 'td_build'),
    [int]$Seed = -1,
    [int]$Area = 1,
    [switch]$SynOnly,           # stop after synthesis (fast area iteration)
    # ReuseSyn: keep the existing syn_1 result, only re-run phy (seed search).
    # !!! Only valid when the RTL is unchanged since that synthesis. After any RTL edit a stale
    #     netlist is re-used and the reported timing/MD5 belong to the old design (this has bitten
    #     us once: two "different" seeds gave byte-identical timing reports).
    [switch]$ReuseSyn
)
$ErrorActionPreference = 'Stop'
$TD   = 'D:/Shop/Bin/td_commands_prompt.exe'
$FLOW = 'D:/Shop/doc/scripts/DefaultFlow.tcl'
$PRJ  = 'HDMI1.4b_Transmitter_v1.0'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$projDir = Join-Path $Out 'td_project'
$runs = Join-Path $projDir "$($PRJ)_Runs"
$synDir = Join-Path $runs 'syn_1'
$phyDir = Join-Path $runs 'phy_1'

if (-not $ReuseSyn) {
    if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
    New-Item -ItemType Directory -Path $Out | Out-Null
    Copy-Item -Recurse (Join-Path $repo 'td_project') $projDir
    Copy-Item -Recurse (Join-Path $repo 'user_source') (Join-Path $Out 'user_source')
    Remove-Item -Recurse -Force (Join-Path $projDir "$($PRJ)_Runs") -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $projDir 'log') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $projDir '.lock.f') -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $synDir | Out-Null
    New-Item -ItemType Directory -Path $phyDir | Out-Null

    # .prj is a copy of .al with source paths two levels deeper (Runs/syn_1)
    $al = Get-Content -Encoding UTF8 (Join-Path $projDir "$PRJ.al") -Raw
    $prjText = $al -replace 'Path="\.\./', 'Path="../../../' -replace 'Path="al_ip/', 'Path="../../al_ip/'
    [System.IO.File]::WriteAllText((Join-Path $synDir "$PRJ.prj"), $prjText, $utf8NoBom)
    Copy-Item (Join-Path $synDir "$PRJ.prj") (Join-Path $phyDir "$PRJ.prj")
} else {
    Write-Output "== reuse syn_1, re-run phy only"
    Get-ChildItem $phyDir -File | Where-Object { $_.Name -notlike '*.prj' -and $_.Name -ne 'settings.cfg' } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
Write-Output "== scratch: $Out"

$common = @"
set ADCList {"../../../user_source/constraints_source/pin.adc"}
set IpSDCList { rfifo_32_32_512 ../../../user_source/hdl_source/ip/afifo_32_16_256.tcl wfifo_32_32_512 ../../../user_source/hdl_source/ip/afifo_16_32_256.tcl }
set SDCList {"../../../user_source/constraints_source/timing.sdc"}
set area_option -packarea
set device_name eagle_s20.db
set package_name EG4S20BG256
set prj_name {$PRJ}
set top_model_name {top}
"@ -replace "`r`n", "`n"

$syn = $common + "`nset end_step opt_gate`nset run_type syn`nset start_step read_design`n"
if ($Area -eq 1) { $syn += "set synWildParams {gate map_mode area_prior}`n" }
[System.IO.File]::WriteAllText((Join-Path $synDir 'settings.cfg'), $syn, $utf8NoBom)

$phy = $common + "`nset arr_filter false`nset drHoldFix on`nset end_step bitgen`nset parent ../syn_1`nset run_type phy`nset start_step opt_place`n"
if ($Seed -ge 0) { $phy += "set phyWildParams {place seed $Seed}`n" }
[System.IO.File]::WriteAllText((Join-Path $phyDir 'settings.cfg'), $phy, $utf8NoBom)

if ($Area -eq 1) { Write-Output '== synthesis mapping: area priority' }
else { Write-Output '== synthesis mapping: timing priority' }
if ($Seed -ge 0) { Write-Output "== place seed: $Seed" }

$steps = if ($SynOnly) { @('syn_1') }
         elseif ($ReuseSyn) { @('phy_1') }
         else { @('syn_1', 'phy_1') }
foreach ($step in $steps) {
    Write-Output "== $step"
    $dir = Join-Path $runs $step
    # run through a small batch file: Start-Process quoting of "< NUL > run.log"
    # inside a cmd /c argument list is not reliable
    $bat = Join-Path $dir 'run_step.cmd'
    [System.IO.File]::WriteAllText($bat,
        "@echo off`r`n`"$TD`" `"$FLOW`" < NUL > run.log 2>&1`r`n", $utf8NoBom)
    $proc = Start-Process -FilePath 'cmd.exe' -WindowStyle Hidden -PassThru `
        -WorkingDirectory $dir -ArgumentList '/c', 'run_step.cmd'
    if (-not $proc.WaitForExit(1500000)) { $proc.Kill(); Write-Error "== $step timeout" }
    $mark = if ($step -eq 'syn_1') { 'opt_gate' } else { 'bitgen' }
    $logPath = Join-Path $dir 'run.log'
    $log = Get-Content -Encoding UTF8 $logPath -Raw
    if (-not (Test-Path (Join-Path $dir ".$mark.end.f")) -or $log -match '(?i)error|couldn''t read|no such file') {
        ($log -split "`n" | Select-String -Pattern '(?i)error|couldn''t read|no such file' |
            Select-Object -First 20) | ForEach-Object { Write-Output $_ }
        ($log -split "`n" | Select-Object -Last 5) | ForEach-Object { Write-Output $_ }
        Write-Error "== $step failed, log: $logPath"
    }
}

if ($SynOnly) {
    $areaSyn = Get-ChildItem (Join-Path $synDir '*.area') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($areaSyn) {
        Get-Content -Encoding UTF8 $areaSyn.FullName |
            Select-String -Pattern '^#(lut|reg|bram|pll|mslice|slice|ram|dsp)' |
            ForEach-Object { Write-Output $_ }
    } else {
        Write-Output "== no syn area report in $synDir"
    }
    return
}

$bit = Join-Path $phyDir "$PRJ.bit"
if (-not (Test-Path $bit)) { Write-Error "no bitstream, see $phyDir/run.log" }
Write-Output "== bitstream: $bit"
$md5 = (Get-FileHash $bit -Algorithm MD5).Hash
Write-Output "== md5: $md5"
$tim = Get-Content -Encoding UTF8 (Join-Path $phyDir 'final_timing.rpt')
$tim | Select-String -Pattern 'WNS' | Select-Object -First 12 | ForEach-Object { Write-Output $_ }
Get-Content -Encoding UTF8 (Join-Path $phyDir "${PRJ}_phy.area") |
    Select-String -Pattern '^#(lut|reg|bram|pll|mslice|slice) ' | ForEach-Object { Write-Output $_ }

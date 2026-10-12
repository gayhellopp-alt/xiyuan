[CmdletBinding()]
param([string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin',
      [string]$Python='python',[switch]$Implement,[switch]$SkipBaseline)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
if(!$SkipBaseline) {
    & (Join-Path $PSScriptRoot 'run_sim.ps1') -VivadoBin $VivadoBin -Python $Python
    & (Join-Path $PSScriptRoot 'run_npu.ps1') -VivadoBin $VivadoBin -Python $Python
}
& (Join-Path $PSScriptRoot 'run_w4a8.ps1') -VivadoBin $VivadoBin -Python $Python -Directed
& (Join-Path $PSScriptRoot 'run_w4a8.ps1') -VivadoBin $VivadoBin -Python $Python -Synthesize -Implement:$Implement
Write-Host 'PHASE2_PROJECT_VALIDATION_PASS'

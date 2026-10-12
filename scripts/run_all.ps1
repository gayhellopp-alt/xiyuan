[CmdletBinding()]
param(
    [string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin',
    [string]$Python='python',
    [switch]$Implement
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'run_sim.ps1') -VivadoBin $VivadoBin -Python $Python
& (Join-Path $PSScriptRoot 'run_synth.ps1') -VivadoBin $VivadoBin -Implement:$Implement
& $Python (Join-Path $PSScriptRoot 'summarize.py') --root $root
if ($LASTEXITCODE -ne 0) {throw 'Artifact audit failed'}
& $Python (Join-Path $PSScriptRoot 'report_double_buffer.py') --root $root
if ($LASTEXITCODE -ne 0) {throw 'Double-buffer report generation failed'}
& (Join-Path $PSScriptRoot 'run_npu.ps1') -VivadoBin $VivadoBin -Python $Python -Synthesize -Implement:$Implement
Write-Host 'PROJECT_VALIDATION_PASS'

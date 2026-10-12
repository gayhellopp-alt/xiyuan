[CmdletBinding()]
param(
    [string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin',
    [string]$Python='python',
    [switch]$SingleConfig,
    [switch]$CorruptExpected,
    [switch]$Synthesize,
    [switch]$Implement,
    [switch]$AuditOnly
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
function Test-NpuSynthesisLog {
    param([string]$Work,[bool]$RequireImplementation=$false)
    $log=Get-Content -Raw -LiteralPath (Join-Path $Work 'synth_npu.log')
    # Tcl echoes may contain literal ERROR text; only actual tool lines count.
    if ($log -notmatch '(?m)^SYNTHESIS_PASS part=' -or $log -match '(?m)^ERROR:') {
        throw 'NPU synthesis reports missing or actual tool error detected'
    }
    if ($RequireImplementation -and $log -notmatch '(?m)^OOC_IMPLEMENTATION_FINISHED$') {
        throw 'NPU implementation incomplete'
    }
}
function Invoke-Checked {
    param([string]$Executable,[string[]]$Arguments,[string]$Log)
    ('& "'+$Executable+'" '+(($Arguments | ForEach-Object {'"'+$_+'"'}) -join ' ')) | Add-Content -Encoding utf8 commands.txt
    & $Executable @Arguments 2>&1 | Tee-Object -FilePath $Log | Out-Host
    if ($LASTEXITCODE -ne 0) {throw "$Executable failed with exit $LASTEXITCODE"}
}
function Invoke-NpuAudit {
    Test-NpuSynthesisLog (Join-Path $root 'build\synth_npu')
    foreach ($step in 'summarize_npu','report_npu') {
        & $Python (Join-Path $root "scripts\$step.py") --root $root
        if ($LASTEXITCODE -ne 0) {throw "$step failed"}
    }
}
if ($AuditOnly) {
    if ($CorruptExpected -or $Synthesize -or $Implement -or $SingleConfig) {throw 'AuditOnly cannot be combined with execution switches'}
    Invoke-NpuAudit
    Write-Host 'NPU_AUDIT_AND_REPORT_PASS'
    return
}
$vectorDir=Join-Path $root 'build\npu_vectors'
& $Python (Join-Path $root 'model\generate_npu_vectors.py') --out $vectorDir
if ($LASTEXITCODE -ne 0) {throw 'NPU reference generation failed'}
$sources=@('sync_sdp_ram','mac_pe','mac_array','tile_buffer','b_pingpong','matmul_top','npu_top') | ForEach-Object {Join-Path $root "rtl\$_.sv"}
$configs=@([pscustomobject]@{Name='4x4_k8_q4';Top='tb_npu'})
if (!$SingleConfig) {$configs+=[pscustomobject]@{Name='2x3_k5_q3';Top='tb_npu_alt'}}
foreach ($config in $configs) {
    $name=$config.Name
    $work=Join-Path $root "build\sim_npu_$name"
    if ($CorruptExpected) {$work+='_negative'}
    New-Item -ItemType Directory -Force $work | Out-Null
    Copy-Item -LiteralPath (Join-Path $vectorDir 'vectors.txt') -Destination $work -Force
    $simHashes=[ordered]@{}
    foreach ($source in ($sources+@(Join-Path $root 'tb\tb_npu.sv'))) {
        $key=$source.Substring($root.Length+1).Replace('\','/')
        $simHashes[$key]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [ordered]@{top=$config.Top;files=$simHashes} | ConvertTo-Json -Depth 4 |
        Set-Content -Encoding utf8 -LiteralPath (Join-Path $work 'source_inputs.json')
    Push-Location $work
    try {
        if (Test-Path -LiteralPath 'PASS.txt') {Remove-Item -LiteralPath 'PASS.txt'}
        Set-Content -Encoding utf8 commands.txt '# Actual NPU simulation commands'
        if ($CorruptExpected) {
            $tokens=(Get-Content -Raw vectors.txt).Split([char[]]" `t`r`n",[System.StringSplitOptions]::RemoveEmptyEntries)
            $tokens[1033]=[string]([int]$tokens[1033]+1)
            Set-Content -Encoding ascii vectors.txt ($tokens -join ' ')
        }
        Invoke-Checked (Join-Path $VivadoBin 'xvlog.bat') (@('--sv')+$sources+@(Join-Path $root 'tb\tb_npu.sv')) 'compile.log'
        Invoke-Checked (Join-Path $VivadoBin 'xelab.bat') @($config.Top,'-s','npu_sim','-timescale','1ns/1ps') 'elaborate.log'
        Invoke-Checked (Join-Path $VivadoBin 'xsim.bat') @('npu_sim','-tclbatch',((Join-Path $root 'scripts\run_xsim.tcl').Replace('\','/'))) 'run.log'
        $log=Get-Content -Raw run.log
        if ($log -notmatch 'NPU_TESTS_PASS' -or $log -match '(?m)^Fatal:|FAILED|TIMEOUT|^ERROR:') {throw "NPU simulation failed: $work\run.log"}
        'PASS' | Set-Content -Encoding ascii PASS.txt
    } finally {Pop-Location}
}
if ($Synthesize -or $Implement) {
    $work=Join-Path $root 'build\synth_npu'
    New-Item -ItemType Directory -Force $work | Out-Null
    $hashes=[ordered]@{}
    foreach ($source in ($sources+@(Join-Path $root 'constraints\clock.xdc'))) {
        $key=$source.Substring($root.Length+1).Replace('\','/')
        $hashes[$key]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [ordered]@{top='npu_top';QUEUE_DEPTH=4;files=$hashes} | ConvertTo-Json -Depth 4 |
        Set-Content -Encoding utf8 -LiteralPath (Join-Path $work 'source_inputs.json')
    Push-Location $work
    try {
        Set-Content -Encoding utf8 commands.txt '# Actual NPU evaluation commands'
        Invoke-Checked (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\query_parts.tcl').Replace('\','/')),'-log','query_parts.log','-journal','query_parts.jou') 'query_parts.console.log'
        Invoke-Checked (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\synth_npu.tcl').Replace('\','/')),'-log','synth_npu.log','-journal','synth_npu.jou','-tclargs',$(if ($Implement) {'1'} else {'0'})) 'synth_npu.console.log'
        Test-NpuSynthesisLog $work ([bool]$Implement)
    } finally {Pop-Location}
}
if (!$SingleConfig -and ($Synthesize -or $Implement)) {Invoke-NpuAudit}
Write-Host 'NPU_VALIDATION_PASS'

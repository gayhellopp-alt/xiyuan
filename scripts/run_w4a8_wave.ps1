[CmdletBinding()]
param(
    [string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin',
    [string]$Python='python',
    [switch]$Directed,[switch]$SingleConfig,[switch]$CorruptExpected,
    [switch]$Synthesize,[switch]$Implement,[switch]$AuditOnly,[switch]$SynthOnly,
    [ValidateSet('all','g4','g8')][string]$EdaConfig='all'
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if($SynthOnly -and !($Synthesize -or $Implement)) {throw 'SynthOnly requires Synthesize or Implement'}
function Invoke-Checked {
    param([string]$Executable,[string[]]$Arguments,[string]$Log)
    ('& "'+$Executable+'" '+(($Arguments | ForEach-Object {'"'+$_+'"'}) -join ' ')) | Add-Content -Encoding utf8 commands.txt
    & $Executable @Arguments 2>&1 | Tee-Object -FilePath $Log | Out-Host
    if($LASTEXITCODE -ne 0) {throw "$Executable exited $LASTEXITCODE"}
}
if($AuditOnly) {
    & $Python (Join-Path $root 'scripts\summarize_w4a8_wave.py')
    if($LASTEXITCODE -ne 0) {throw 'W4A8 artifact audit failed'}
    return
}
$vec=Join-Path $root 'build\w4a8_systolic_vectors'
if(!$Directed -and !$SynthOnly -and !$CorruptExpected){
    $baseline=Join-Path $root 'build\sim_w4a8_systolic_s4\PASS.txt'
    if(!(Test-Path -LiteralPath $baseline)){
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\run_w4a8_systolic.ps1') -VivadoBin $VivadoBin -Python $Python
        if($LASTEXITCODE -ne 0){throw 'Preserved tile-drain baseline gate failed'}
    }
}
& $Python (Join-Path $root 'model\w4a8_reference.py') --out (Join-Path $root 'build\w4a8_vectors')
if($LASTEXITCODE -ne 0){throw 'Base reference failed'}
& $Python (Join-Path $root 'model\w4a8_systolic_vectors.py')
if($LASTEXITCODE -ne 0) {throw 'W4A8 reference failed'}
$rtl=@('sync_sdp_ram','mac_pe','mac_array','systolic_pe','systolic_array','w4_unpack','w4a8_wave') | ForEach-Object {Join-Path $root "rtl\$_.sv"}
$sources=$rtl+@(Join-Path $root 'tb\w4a8_reuse_memory.sv')+@(Join-Path $root 'tb\tb_w4a8_wave.sv')
$configs=@([pscustomobject]@{Name='g4';Group=32;Top='tb_w4a8_wave'})
if($Directed) {$configs=@([pscustomobject]@{Name='directed';Group=32;Top='tb_w4a8_wave_directed'})}
elseif(!$SingleConfig) {
    $configs+=[pscustomobject]@{Name='g8';Group=32;Top='tb_w4a8_wave8'}
    $configs+=[pscustomobject]@{Name='t4';Group=32;Top='tb_w4a8_wave_tile4'}
    $configs+=[pscustomobject]@{Name='t8';Group=32;Top='tb_w4a8_wave_tile8'}
    $configs+=[pscustomobject]@{Name='alt';Group=12;Top='tb_w4a8_wave_alt'}
    $configs+=[pscustomobject]@{Name='words8';Group=32;Top='tb_w4a8_wave_words8'}
    $configs+=[pscustomobject]@{Name='single';Group=32;Top='tb_w4a8_wave_single'}
    $configs+=[pscustomobject]@{Name='one';Group=32;Top='tb_w4a8_wave_one'}
}
if($SynthOnly) {$configs=@()}
foreach($config in $configs) {
    $work=Join-Path $root ('build\sim_w4a8_wave_'+$config.Name)
    if($CorruptExpected) {$work+='_negative'}
    New-Item -ItemType Directory -Force $work | Out-Null
    Copy-Item -LiteralPath (Join-Path $vec ("group"+$config.Group+'.txt')) -Destination (Join-Path $work 'vectors.txt') -Force
    $hashes=[ordered]@{}
    foreach($source in $sources) {$hashes[$source.Substring($root.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
    [ordered]@{top=$config.Top;files=$hashes} | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $work 'source_inputs.json')
    Push-Location $work
    try {
        if(Test-Path -LiteralPath 'PASS.txt') {Remove-Item -LiteralPath 'PASS.txt'}
        Set-Content -Encoding utf8 commands.txt '# Actual W4A8 XSim commands'
        if($CorruptExpected) {
            $tokens=(Get-Content -Raw vectors.txt)-split '\s+' | Where-Object {$_ -ne ''}
            $mm=[int]$tokens[2];$nn=[int]$tokens[3];$kk=[int]$tokens[4];$gg=[int]$tokens[5]
            $first=6+$mm*$kk+$nn*[int][math]::Ceiling($kk/2.0)+($mm+$nn)*$gg
            $tokens[$first]=[string]([int]$tokens[$first]+1)
            Set-Content -Encoding ascii vectors.txt ($tokens -join ' ')
        }
        Invoke-Checked (Join-Path $VivadoBin 'xvlog.bat') (@('--sv')+$sources) 'compile.log'
        Invoke-Checked (Join-Path $VivadoBin 'xelab.bat') @($config.Top,'-s','w4a8_sim','-timescale','1ns/1ps') 'elaborate.log'
        Invoke-Checked (Join-Path $VivadoBin 'xsim.bat') @('w4a8_sim','-tclbatch',((Join-Path $root 'scripts\run_xsim.tcl').Replace('\','/'))) 'run.log'
        $log=Get-Content -Raw run.log
        if($log -notmatch 'W4A8_WAVE_TESTS_PASS' -or $log -match '(?m)^Fatal:|FAILED|TIMEOUT|^ERROR:') {throw "W4A8 simulation failed: $work"}
        'PASS' | Set-Content -Encoding ascii PASS.txt
    } finally {Pop-Location}
}
if(!$Directed -and !$SingleConfig -and !$CorruptExpected -and !$SynthOnly){
    $probeOut=Join-Path $root 'build\wave_negative_auto.stdout.log'
    $probeErr=Join-Path $root 'build\systolic_negative_auto.stderr.log'
    $probe=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),
        '-SingleConfig','-CorruptExpected','-VivadoBin',('"'+$VivadoBin+'"'),'-Python',('"'+$Python+'"')
    ) -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr
    $code=$probe.ExitCode
    Set-Content -Encoding ascii -LiteralPath (Join-Path $root 'build\sim_w4a8_wave_g4_negative\observed_exit_code.txt') $code
    if($code -eq 0 -or (Get-Content -Raw -LiteralPath $probeOut) -notmatch 'W4A8_WAVE_CHECK_FAILED'){throw 'Negative self-check gate failed'}
    Write-Host "WAVE_EXPECTED_NEGATIVE_EXIT=$code"
}
if($Synthesize -or $Implement) {
    if(!(Test-Path -LiteralPath (Join-Path $root 'build\selected_part.txt'))){
        $query=Join-Path $root 'build\systolic_parts';New-Item -ItemType Directory -Force $query | Out-Null
        Push-Location $query
        try {
            Set-Content -Encoding utf8 commands.txt '# Device discovery for a clean build'
            Invoke-Checked (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\query_parts.tcl').Replace('\','/')),'-log','query_parts.log','-journal','query_parts.jou') 'query_parts.console.log'
        } finally {Pop-Location}
    }
    $eda=@(
        [pscustomobject]@{Name='g4';Rows=4;Cols=4;Systolic=1;Stream=1},
        [pscustomobject]@{Name='g8';Rows=8;Cols=8;Systolic=1;Stream=1})
    if($EdaConfig -ne 'all'){$eda=@($eda|Where-Object {$_.Name -eq $EdaConfig})}
    foreach($candidate in $eda){
        $work=Join-Path $root ('build\synth_w4a8_wave_'+$candidate.Name)
        New-Item -ItemType Directory -Force $work | Out-Null
        $hashes=[ordered]@{}
        foreach($source in ($rtl+@(Join-Path $root 'constraints\clock.xdc'))) {$hashes[$source.Substring($root.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
        [ordered]@{top='w4a8_wave';config=$candidate.Name;rows=$candidate.Rows;cols=$candidate.Cols;systolic=$candidate.Systolic;group_stream=$candidate.Stream;files=$hashes}|ConvertTo-Json -Depth 4|Set-Content -Encoding utf8 (Join-Path $work 'source_inputs.json')
        Push-Location $work
        try {
            Set-Content -Encoding utf8 commands.txt '# Actual parameterized Vivado commands'
            Invoke-Checked (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\synth_w4a8_wave.tcl').Replace('\','/')),'-log','synth_w4a8_wave.log','-journal','synth_w4a8_wave.jou','-tclargs',$(if($Implement -and $candidate.Systolic){'1'}else{'0'}),[string]$candidate.Rows,[string]$candidate.Cols,[string]$candidate.Systolic,$candidate.Name,[string]$candidate.Stream) 'synth_w4a8_wave.console.log'
            $log=Get-Content -Raw synth_w4a8_wave.log
            if($log -notmatch '(?m)^W4A8_WAVE_SYNTHESIS_PASS' -or $log -match '(?m)^ERROR:'){throw 'Systolic synthesis incomplete'}
            if($Implement -and $candidate.Systolic -and $log -notmatch '(?m)^W4A8_WAVE_OOC_FINISHED'){throw 'Systolic OOC incomplete'}
        } finally {Pop-Location}
    }
}
if(!$Directed -and !$SingleConfig -and !$CorruptExpected) {
    & $Python (Join-Path $root 'scripts\summarize_w4a8_wave.py')
    if($LASTEXITCODE -ne 0) {throw 'W4A8 artifact audit failed'}
}
Write-Host 'W4A8_WAVE_VALIDATION_PASS'

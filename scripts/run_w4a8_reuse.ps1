[CmdletBinding()]
param(
    [string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin',
    [string]$Python='python',
    [switch]$Directed,[switch]$SingleConfig,[switch]$CorruptExpected,
    [switch]$Synthesize,[switch]$Implement,[switch]$AuditOnly,[switch]$SynthOnly
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
    & $Python (Join-Path $root 'scripts\summarize_w4a8_reuse.py')
    if($LASTEXITCODE -ne 0) {throw 'W4A8 artifact audit failed'}
    return
}
$vec=Join-Path $root 'build\w4a8_vectors'
& $Python (Join-Path $root 'model\w4a8_reference.py') --out $vec
if($LASTEXITCODE -ne 0) {throw 'W4A8 reference failed'}
$rtl=@('sync_sdp_ram','mac_pe','mac_array','w4_unpack','w4a8_reuse') | ForEach-Object {Join-Path $root "rtl\$_.sv"}
$sources=$rtl+@(Join-Path $root 'tb\w4a8_reuse_memory.sv')+@(Join-Path $root 'tb\tb_w4a8_reuse.sv')
$configs=@([pscustomobject]@{Name='reuse';Group=32;Top='tb_w4a8_reuse'})
if($Directed) {$configs=@([pscustomobject]@{Name='directed';Group=32;Top='tb_w4a8_reuse_directed'})}
elseif(!$SingleConfig) {
    $configs+=[pscustomobject]@{Name='no_reuse';Group=32;Top='tb_w4a8_reuse_no_reuse'}
    $configs+=[pscustomobject]@{Name='alt';Group=12;Top='tb_w4a8_reuse_alt'}
    $configs+=[pscustomobject]@{Name='words';Group=32;Top='tb_w4a8_reuse_words'}
    $configs+=[pscustomobject]@{Name='single';Group=32;Top='tb_w4a8_reuse_single'}
    $configs+=[pscustomobject]@{Name='one';Group=32;Top='tb_w4a8_reuse_one'}
    $configs+=[pscustomobject]@{Name='byte';Group=32;Top='tb_w4a8_reuse_byte'}
}
if($SynthOnly) {$configs=@()}
foreach($config in $configs) {
    $work=Join-Path $root ('build\sim_w4a8_reuse_'+$config.Name)
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
        if($log -notmatch 'W4A8_REUSE_TESTS_PASS' -or $log -match '(?m)^Fatal:|FAILED|TIMEOUT|^ERROR:') {throw "W4A8 simulation failed: $work"}
        'PASS' | Set-Content -Encoding ascii PASS.txt
    } finally {Pop-Location}
}
if($Synthesize -or $Implement) {
    $work=Join-Path $root 'build\synth_w4a8_reuse';New-Item -ItemType Directory -Force $work | Out-Null
    $hashes=[ordered]@{}
    foreach($source in ($rtl+@(Join-Path $root 'constraints\clock.xdc'))) {$hashes[$source.Substring($root.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
    [ordered]@{top='w4a8_reuse';files=$hashes} | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $work 'source_inputs.json')
    Push-Location $work
    try {
        Set-Content -Encoding utf8 commands.txt '# Actual W4A8 Vivado commands'
        Invoke-Checked (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\query_parts.tcl').Replace('\','/')),'-log','query_parts.log','-journal','query_parts.jou') 'query_parts.console.log'
        Invoke-Checked (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\synth_w4a8_reuse.tcl').Replace('\','/')),'-log','synth_w4a8_reuse.log','-journal','synth_w4a8_reuse.jou','-tclargs',$(if($Implement){'1'}else{'0'})) 'synth_w4a8_reuse.console.log'
        $log=Get-Content -Raw synth_w4a8_reuse.log
        if($log -notmatch '(?m)^W4A8_REUSE_SYNTHESIS_PASS' -or $log -match '(?m)^ERROR:') {throw 'W4A8 synthesis incomplete'}
        if($Implement -and $log -notmatch '(?m)^W4A8_REUSE_OOC_FINISHED') {throw 'W4A8 OOC incomplete'}
    } finally {Pop-Location}
}
if(!$Directed -and !$SingleConfig -and !$CorruptExpected) {
    & $Python (Join-Path $root 'scripts\summarize_w4a8_reuse.py')
    if($LASTEXITCODE -ne 0) {throw 'W4A8 artifact audit failed'}
}
Write-Host 'W4A8_REUSE_VALIDATION_PASS'

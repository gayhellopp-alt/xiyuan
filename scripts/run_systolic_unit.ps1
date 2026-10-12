[CmdletBinding()]
param([string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($size in @(4,8)) {
    $work=Join-Path $root ("build\sim_systolic_unit"+$size)
    New-Item -ItemType Directory -Force $work | Out-Null
    $sources=@('rtl\mac_pe.sv','rtl\systolic_pe.sv','rtl\systolic_array.sv','tb\tb_systolic_array.sv') | ForEach-Object {Join-Path $root $_}
    $hashes=[ordered]@{}
    foreach($source in $sources){$hashes[$source.Substring($root.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
    [ordered]@{files=$hashes}|ConvertTo-Json -Depth 4|Set-Content -Encoding utf8 (Join-Path $work 'source_inputs.json')
    Push-Location $work
    try {
        if(Test-Path PASS.txt){Remove-Item -LiteralPath PASS.txt}
        $top=if($size -eq 4){'tb_systolic_array'}else{'tb_systolic_array8'}
        $commands=@(
            @{Exe='xvlog.bat';Args=@('--sv')+$sources;Log='compile.log'},
            @{Exe='xelab.bat';Args=@($top,'-s','unit_sim','-timescale','1ns/1ps');Log='elaborate.log'},
            @{Exe='xsim.bat';Args=@('unit_sim','-tclbatch',((Join-Path $root 'scripts\run_xsim.tcl').Replace('\','/')));Log='run.log'})
        Set-Content -Encoding utf8 commands.txt '# Actual systolic unit commands'
        foreach($command in $commands){
            $exe=Join-Path $VivadoBin $command.Exe;$arguments=$command.Args
            ('& "'+$exe+'" '+(($arguments|ForEach-Object {'"'+$_+'"'})-join ' '))|Add-Content -Encoding utf8 commands.txt
            & $exe @arguments 2>&1|Tee-Object -FilePath $command.Log|Out-Host
            if($LASTEXITCODE -ne 0){throw "$exe exited $LASTEXITCODE"}
        }
        $log=Get-Content -Raw run.log
        if($log -notmatch 'SYSTOLIC_UNIT_PASS' -or $log -match 'Fatal:|FAILED|TIMEOUT|(?m)^ERROR:'){throw "Systolic unit $size failed"}
        'PASS'|Set-Content -Encoding ascii PASS.txt
    } finally {Pop-Location}
}
Write-Host 'SYSTOLIC_UNITS_VALIDATION_PASS'

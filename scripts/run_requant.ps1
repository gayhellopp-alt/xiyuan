[CmdletBinding()]
param(
    [string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin',
    [string]$Python='python',
    [switch]$Synthesize,[switch]$Implement,[switch]$Regression,
    [switch]$CorruptExpected,[switch]$TimeoutProbe,[switch]$ProbeChild
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
function Invoke-Checked {
    param([string]$Executable,[string[]]$Arguments,[string]$Log)
    ('& "'+$Executable+'" '+(($Arguments|ForEach-Object {'"'+$_+'"'})-join ' '))|Add-Content -Encoding utf8 commands.txt
    & $Executable @Arguments 2>&1 | Tee-Object -FilePath $Log | Out-Host
    if($LASTEXITCODE -ne 0){throw "$Executable exited $LASTEXITCODE"}
}
function Save-Identity {
    param([string]$Work,[string]$Top,[int]$Group,[string[]]$Sources)
    $hashes=[ordered]@{}
    foreach($source in $Sources){$hashes[$source.Substring($root.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
    [ordered]@{top=$Top;group_size=$Group;max_k=4096;files=$hashes}|ConvertTo-Json -Depth 5|Set-Content -Encoding utf8 (Join-Path $Work 'source_inputs.json')
}
try {
    $vec=Join-Path $root 'build\requant_vectors'
    if(!$ProbeChild){
        New-Item -ItemType Directory -Force $vec|Out-Null
        Push-Location $vec
        try {
            Set-Content -Encoding utf8 commands.txt '# Actual integer reference commands'
            Invoke-Checked $Python @((Join-Path $root 'model\vector\requant_reference.py'),'--out',$vec) 'model.log'
        }
        finally {Pop-Location}
    }
    $sources=@((Join-Path $root 'rtl\vector\requant_group.sv'),(Join-Path $root 'tb\vector\tb_requant_group.sv'))
    $configs=@([pscustomobject]@{Group=32;Top='tb_requant_group'},[pscustomobject]@{Group=12;Top='tb_requant_group12'})
    if($ProbeChild){$configs=@($configs[0])}
    foreach($cfg in $configs){
        $name='sim_requant_g'+$cfg.Group
        if($CorruptExpected){$name+='_negative'}
        if($TimeoutProbe){$name+='_timeout'}
        $work=Join-Path $root ('build\'+$name)
        New-Item -ItemType Directory -Force $work|Out-Null
        Copy-Item -LiteralPath (Join-Path $vec ('group'+$cfg.Group+'.txt')) -Destination (Join-Path $work 'vectors.txt') -Force
        Save-Identity $work $cfg.Top $cfg.Group ($sources+@(Join-Path $root 'model\vector\requant_reference.py')+@(Join-Path $root 'scripts\run_requant.ps1')+@(Join-Path $root 'scripts\run_xsim.tcl'))
        Push-Location $work
        try {
            if(Test-Path -LiteralPath PASS.txt){Remove-Item -LiteralPath PASS.txt}
            Set-Content -Encoding utf8 commands.txt '# Actual requant XSim commands'
            Invoke-Checked (Join-Path $VivadoBin 'xvlog.bat') (@('--sv')+$sources) 'compile.log'
            Invoke-Checked (Join-Path $VivadoBin 'xelab.bat') @($cfg.Top,'-s','requant_sim','-timescale','1ns/1ps') 'elaborate.log'
            $simargs=@('requant_sim','-tclbatch',((Join-Path $root 'scripts\run_xsim.tcl').Replace('\','/')))
            if($CorruptExpected){$simargs+=@('-testplusarg','CORRUPT_EXPECTED')}
            if($TimeoutProbe){$simargs+=@('-testplusarg','FORCE_TIMEOUT')}
            Invoke-Checked (Join-Path $VivadoBin 'xsim.bat') $simargs 'run.log'
            $log=Get-Content -Raw run.log
            if($log -notmatch 'REQUANT_TESTS_PASS' -or $log -match '(?m)^Fatal:|REQUANT_CHECK_FAILED|REQUANT_TIMEOUT|^ERROR:'){throw "Requant simulation failed: $work"}
            Set-Content -Encoding ascii PASS.txt 'PASS'
        } finally {Pop-Location}
    }
    if(!$ProbeChild){
        foreach($kind in @('negative','timeout')){
            $probeOut=Join-Path $root ('build\requant_'+$kind+'.stdout.log')
            $probeErr=Join-Path $root ('build\requant_'+$kind+'.stderr.log')
            $switch=if($kind -eq 'negative'){'-CorruptExpected'}else{'-TimeoutProbe'}
            $probe=Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-ProbeChild',$switch,'-VivadoBin',('"'+$VivadoBin+'"'),'-Python',('"'+$Python+'"')) -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr
            $code=$probe.ExitCode
            Set-Content -Encoding ascii (Join-Path $root ('build\sim_requant_g32_'+$kind+'\observed_exit_code.txt')) $code
            $marker=if($kind -eq 'negative'){'REQUANT_CHECK_FAILED'}else{'REQUANT_TIMEOUT'}
            if($code -eq 0 -or (Get-Content -Raw $probeOut) -notmatch $marker){throw "Expected $kind failure was not observed"}
            Write-Host "REQUANT_EXPECTED_${kind}_EXIT=$code"
        }
    }
    if($Synthesize -or $Implement){
        foreach($group in @(32,12)){
            $work=Join-Path $root ('build\synth_requant_g'+$group)
            New-Item -ItemType Directory -Force $work|Out-Null
            Save-Identity $work 'requant_group' $group @($sources[0],(Join-Path $root 'constraints\clock.xdc'),(Join-Path $root 'scripts\synth_requant.tcl'))
            Push-Location $work
            try {
                Set-Content -Encoding utf8 commands.txt '# Actual VU9P requant commands'
                Invoke-Checked (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\synth_requant.tcl').Replace('\','/')),'-log','synth_requant.log','-journal','synth_requant.jou','-tclargs',$(if($Implement){'1'}else{'0'}),[string]$group) 'console.log'
                $log=Get-Content -Raw synth_requant.log
                if($log -notmatch 'REQUANT_SYNTHESIS_PASS' -or $log -match '(?m)^ERROR:'){throw 'Requant synthesis incomplete'}
                if($Implement -and $log -notmatch 'REQUANT_OOC_FINISHED'){throw 'Requant OOC incomplete'}
            } finally {Pop-Location}
        }
    }
    if($Regression){
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\run_w4a8_wave.ps1') -VivadoBin $VivadoBin -Python $Python
        if($LASTEXITCODE -ne 0){throw 'Preserved W4A8 regression failed'}
    }
    if(!$ProbeChild){
        & $Python (Join-Path $root 'scripts\summarize_requant.py')
        if($LASTEXITCODE -ne 0){throw 'Requant delivery audit failed'}
    }
    Write-Host 'REQUANT_VALIDATION_PASS'
} catch {Write-Error $_; exit 1}

[CmdletBinding()]
param(
    [string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin',[string]$Python='python',
    [switch]$Synthesize,[switch]$Implement,[switch]$Regression,[switch]$ProbeChild,
    [switch]$CorruptExpected,[switch]$TimeoutProbe,
    [ValidateSet('all','module32','module12','chain32','chain12')][string]$Simulation='all',
    [switch]$AuditOnly,[switch]$SynthOnly
)
$ErrorActionPreference='Stop';$root=Split-Path -Parent $PSScriptRoot
function Invoke-Checked {
    param([string]$Executable,[string[]]$Arguments,[string]$Log)
    ('& "'+$Executable+'" '+(($Arguments|ForEach-Object {'"'+$_+'"'})-join ' '))|Add-Content -Encoding utf8 commands.txt
    & $Executable @Arguments 2>&1 | Tee-Object -FilePath $Log | Out-Host
    $code=$LASTEXITCODE;Set-Content -Encoding ascii ($Log+'.exit_code.txt') $code
    if($code -ne 0){throw "$Executable exited $code"}
}
function Save-Identity {
    param([string]$Work,[string]$Top,[int]$Group,[string[]]$Sources)
    $hashes=[ordered]@{}
    foreach($source in $Sources){$hashes[$source.Substring($root.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
    [ordered]@{top=$Top;group_size=$Group;max_k=4096;files=$hashes}|ConvertTo-Json -Depth 5|Set-Content -Encoding utf8 (Join-Path $Work 'source_inputs.json')
}
try {
    if($AuditOnly){& $Python (Join-Path $root 'scripts\summarize_dynamic.py');if($LASTEXITCODE -ne 0){throw 'Dynamic audit failed'};return}
    if($SynthOnly -and !($Synthesize -or $Implement)){throw 'SynthOnly requires Synthesize/Implement'}
    $vec=Join-Path $root 'build\dynamic_vectors'
    if(!$ProbeChild -and !$SynthOnly){
        & $Python (Join-Path $root 'scripts\summarize_requant.py');if($LASTEXITCODE -ne 0){throw 'External scale baseline gate failed'}
        New-Item -ItemType Directory -Force $vec|Out-Null;Push-Location $vec
        try {Set-Content -Encoding utf8 commands.txt '# Dynamic references';Invoke-Checked $Python @((Join-Path $root 'model\vector\dynamic_reference.py'),'--out',$vec) 'model.log'} finally {Pop-Location}
    }
    $rtl=@('sync_sdp_ram','mac_pe','mac_array','systolic_pe','systolic_array','w4_unpack','w4a8_wave','vector\requant_group','vector\requant_dynamic')|ForEach-Object {Join-Path $root ('rtl\'+$_+'.sv')}
    $sources=$rtl+@((Join-Path $root 'tb\w4a8_reuse_memory.sv'),(Join-Path $root 'tb\vector\tb_requant_dynamic.sv'),(Join-Path $root 'tb\vector\tb_w4a8_two_layer.sv'))
    $configs=@(
        [pscustomobject]@{Name='module32';Group=32;Top='tb_requant_dynamic';Vector='group32';Marker='DYNAMIC_TESTS_PASS'},
        [pscustomobject]@{Name='module12';Group=12;Top='tb_requant_dynamic12';Vector='group12';Marker='DYNAMIC_TESTS_PASS'},
        [pscustomobject]@{Name='chain32';Group=32;Top='tb_w4a8_two_layer';Vector='chain32';Marker='CHAIN_TESTS_PASS'},
        [pscustomobject]@{Name='chain12';Group=12;Top='tb_w4a8_two_layer12';Vector='chain12';Marker='CHAIN_TESTS_PASS'})
    if($Simulation -ne 'all'){$configs=@($configs|Where-Object {$_.Name -eq $Simulation})}
    if($SynthOnly){$configs=@()}
    foreach($cfg in $configs){
        $name='sim_dynamic_'+$cfg.Name;if($CorruptExpected){$name+='_negative'};if($TimeoutProbe){$name+='_timeout'}
        $work=Join-Path $root ('build\'+$name);New-Item -ItemType Directory -Force $work|Out-Null
        Copy-Item -LiteralPath (Join-Path $vec ($cfg.Vector+'.txt')) -Destination (Join-Path $work 'vectors.txt') -Force
        Save-Identity $work $cfg.Top $cfg.Group ($sources+@((Join-Path $root 'model\vector\dynamic_reference.py'),(Join-Path $root 'model\vector\requant_reference.py'),(Join-Path $root 'model\w4a8_reference.py'),(Join-Path $root 'scripts\run_dynamic.ps1')))
        Push-Location $work
        try {
            if(Test-Path -LiteralPath PASS.txt){Remove-Item -LiteralPath PASS.txt};Set-Content -Encoding utf8 commands.txt '# Actual dynamic XSim commands'
            Invoke-Checked (Join-Path $VivadoBin 'xvlog.bat') (@('--sv')+$sources) 'compile.log'
            Invoke-Checked (Join-Path $VivadoBin 'xelab.bat') @($cfg.Top,'-s','dynamic_sim','-timescale','1ns/1ps') 'elaborate.log'
            $simargs=@('dynamic_sim','-tclbatch',((Join-Path $root 'scripts\run_xsim.tcl').Replace('\','/')))
            if($CorruptExpected){$simargs+=@('-testplusarg','CORRUPT_EXPECTED')};if($TimeoutProbe){$simargs+=@('-testplusarg','FORCE_TIMEOUT')}
            Invoke-Checked (Join-Path $VivadoBin 'xsim.bat') $simargs 'run.log'
            $log=Get-Content -Raw run.log
            if($log -notmatch $cfg.Marker -or $log -match '(?m)^Fatal:|CHECK_FAILED|_TIMEOUT|^ERROR:'){throw "Dynamic simulation failed: $work"}
            Set-Content -Encoding ascii PASS.txt 'PASS'
        } finally {Pop-Location}
    }
    if(!$ProbeChild -and !$SynthOnly -and $Simulation -eq 'all'){
        foreach($probeSpec in @(@('module32','negative'),@('chain32','negative'),@('module32','timeout'))){
            $sim=$probeSpec[0];$kind=$probeSpec[1];$switch=if($kind -eq 'negative'){'-CorruptExpected'}else{'-TimeoutProbe'}
            $out=Join-Path $root ('build\dynamic_'+$sim+'_'+$kind+'.stdout.log');$err=Join-Path $root ('build\dynamic_'+$sim+'_'+$kind+'.stderr.log')
            $p=Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-ProbeChild','-Simulation',$sim,$switch,'-VivadoBin',('"'+$VivadoBin+'"')) -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
            Set-Content -Encoding ascii (Join-Path $root ('build\sim_dynamic_'+$sim+'_'+$kind+'\observed_exit_code.txt')) $p.ExitCode
            $marker=if($kind -eq 'negative'){'CHECK_FAILED'}else{'DYNAMIC_TIMEOUT'}
            if($p.ExitCode -eq 0 -or (Get-Content -Raw $out) -notmatch $marker){throw 'Failure probe missing expected failure'}
            Write-Host "DYNAMIC_EXPECTED_${sim}_${kind}_EXIT=$($p.ExitCode)"
        }
    }
    if($Synthesize -or $Implement){
        foreach($g in @(32,12)){
            $work=Join-Path $root ('build\synth_dynamic_g'+$g);New-Item -ItemType Directory -Force $work|Out-Null
            Save-Identity $work 'requant_dynamic' $g @($rtl[0],$rtl[7],$rtl[8],(Join-Path $root 'constraints\clock.xdc'),(Join-Path $root 'scripts\synth_dynamic.tcl'))
            Push-Location $work
            try {
                Set-Content -Encoding utf8 commands.txt '# Actual VU9P dynamic commands'
                Invoke-Checked (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\synth_dynamic.tcl').Replace('\','/')),'-log','synth_dynamic.log','-journal','synth_dynamic.jou','-tclargs',$(if($Implement){'1'}else{'0'}),[string]$g) 'console.log'
                $log=Get-Content -Raw synth_dynamic.log
                if($log -notmatch '(?m)^DYNAMIC_SYNTHESIS_PASS' -or ($Implement -and $log -notmatch '(?m)^DYNAMIC_OOC_FINISHED')){throw 'Dynamic EDA incomplete'}
            } finally {Pop-Location}
        }
    }
    if($Regression){
        foreach($entry in @('run_requant.ps1','run_w4a8_wave.ps1')){
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root ('scripts\'+$entry)) -VivadoBin $VivadoBin -Python $Python
            if($LASTEXITCODE -ne 0){throw "Regression failed: $entry"}
        }
    }
    if(!$ProbeChild -and $Simulation -eq 'all'){& $Python (Join-Path $root 'scripts\summarize_dynamic.py');if($LASTEXITCODE -ne 0){throw 'Dynamic delivery audit failed'}}
    Write-Host 'DYNAMIC_VALIDATION_PASS'
} catch {Write-Error $_;exit 1}

[CmdletBinding()]
param(
    [string]$VivadoBin='E:\AMDDesignTools\2025.2\Vivado\bin',
    [string]$Python='python',
    [ValidateSet('all','team','software','ad','memory','kv','ce','valid')][string]$Suite='all',
    [switch]$Synthesize
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $root 'build\team_validation'
New-Item -ItemType Directory -Force $work | Out-Null
$shell=(Get-Process -Id $PID).Path
function Invoke-Recorded {
    param([string]$Executable,[string[]]$Arguments,[string]$Log,[switch]$ExpectFailure)
    # Windows PowerShell represents native stderr as error records, including
    # unittest's ordinary successful progress output. Judge the process exit code.
    $ErrorActionPreference='Continue'
    & $Executable @Arguments > $Log 2>&1
    $code=$LASTEXITCODE
    Set-Content -Encoding ascii ($Log+'.exit_code.txt') $code
    if($ExpectFailure){if($code -eq 0){throw "Expected failing probe passed: $Log"}}
    elseif($code -ne 0){Get-Content $Log -Tail 35 | Out-Host;throw "Validation failed ($code): $Log"}
}
$selected=if($Suite -eq 'all'){@('software','team','ad','memory','kv','ce','valid')}else{@($Suite)}
$results=[ordered]@{}
foreach($name in $selected){
    $pass=Join-Path $work ($name+'.PASS.txt')
    if(Test-Path -LiteralPath $pass){Remove-Item -LiteralPath $pass}
    Write-Host "TEAM_SUITE_START $name"
    if($name -eq 'software'){
        Push-Location $root
        try {Invoke-Recorded $Python @('-m','unittest','software.test_w4a8_software','software.test_w4a8_memory_task','-v') (Join-Path $work 'software.log')}
        finally {Pop-Location}
    } elseif($name -eq 'team'){
        $vec=Join-Path $work 'vectors'
        Invoke-Recorded $Python @((Join-Path $root 'model\w4a8_memory_vectors.py'),'--out',$vec) (Join-Path $work 'vectors.log')
        $names=@('task_desc_pkg','w4a8_memory_pkg','w4a8_memory_validate','w4a8_axi_read','w4a8_axi_write',
            'w4a8_memory_packet','w4a8_memory_bridge','sync_sdp_ram','mac_pe','mac_array','systolic_pe',
            'systolic_array','w4_unpack','w4a8_wave','w4a8_task_adapter','w4a8_team_top')
        $sources=@($names|ForEach-Object {Join-Path $root "rtl\$_.sv"})+
            @((Join-Path $root 'tb\w4a8_axi_memory.sv'),(Join-Path $root 'tb\tb_w4a8_team.sv'))
        $hashes=[ordered]@{}
        foreach($file in ($sources+@($PSCommandPath,(Join-Path $root 'scripts\check_team_sim.py'),(Join-Path $root 'model\w4a8_memory_vectors.py'),(Join-Path $root 'model\w4a8_reference.py')))){
            $hashes[$file.Substring($root.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()
        }
        $hashes|ConvertTo-Json -Depth 4|Set-Content -Encoding utf8 (Join-Path $work 'sources.json')
        foreach($top in @('tb_w4a8_team','tb_w4a8_team12','tb_w4a8_team8')){
            $sim=Join-Path $work $top;New-Item -ItemType Directory -Force $sim|Out-Null
            Copy-Item -Path (Join-Path $vec '*') -Destination $sim -Force
            Push-Location $sim
            try {
                Invoke-Recorded (Join-Path $VivadoBin 'xvlog.bat') (@('--sv')+$sources) (Join-Path $sim 'compile.log')
                Invoke-Recorded (Join-Path $VivadoBin 'xelab.bat') @($top,'-s','team_sim','-timescale','1ns/1ps') (Join-Path $sim 'elaborate.log')
                $simArgs=@('team_sim','-tclbatch',((Join-Path $root 'scripts\run_w4a8_memory_xsim.tcl').Replace('\','/')))
                Invoke-Recorded (Join-Path $VivadoBin 'xsim.bat') $simArgs (Join-Path $sim 'run.log')
                Invoke-Recorded $Python @((Join-Path $root 'scripts\check_team_sim.py'),(Join-Path $sim 'run.log')) (Join-Path $sim 'check.log')
                $log=Get-Content -Raw (Join-Path $sim 'run.log')
                if($log -notmatch 'W4A8_TEAM_TESTS_PASS' -or $log -match 'Fatal:|TEAM_CHECK_FAILED|^ERROR:'){throw "Missing successful team simulation: $top"}
                ($log -split "`n"|Where-Object {$_ -match 'W4A8_TEAM_TESTS_PASS'})|Out-Host
                if($top -eq 'tb_w4a8_team'){
                    Invoke-Recorded (Join-Path $VivadoBin 'xsim.bat') ($simArgs+@('-testplusarg','corrupt_expected')) (Join-Path $sim 'negative.log')
                    if((Get-Content -Raw (Join-Path $sim 'negative.log')) -notmatch 'TEAM_CHECK_FAILED external Y bit exact'){throw 'Negative probe failed for an unrelated reason'}
                    Invoke-Recorded $Python @((Join-Path $root 'scripts\check_team_sim.py'),(Join-Path $sim 'negative.log')) (Join-Path $sim 'negative_check.log') -ExpectFailure
                    Invoke-Recorded (Join-Path $VivadoBin 'xsim.bat') ($simArgs+@('-testplusarg','timeout_probe')) (Join-Path $sim 'timeout.log')
                    if((Get-Content -Raw (Join-Path $sim 'timeout.log')) -notmatch 'TEAM_FORCED_TIMEOUT'){throw 'Timeout probe failed for an unrelated reason'}
                    Invoke-Recorded $Python @((Join-Path $root 'scripts\check_team_sim.py'),(Join-Path $sim 'timeout.log')) (Join-Path $sim 'timeout_check.log') -ExpectFailure
                }
            } finally {Pop-Location}
        }
        if($Synthesize){
            $synth=Join-Path $work 'synthesis';New-Item -ItemType Directory -Force $synth|Out-Null
            Push-Location $synth
            try {
                Invoke-Recorded (Join-Path $VivadoBin 'vivado.bat') @('-mode','batch','-source',((Join-Path $root 'scripts\synth_w4a8_team.tcl').Replace('\','/'))) (Join-Path $synth 'console.log')
                if((Get-Content -Raw (Join-Path $synth 'console.log')) -notmatch 'W4A8_TEAM_SYNTHESIS_PASS'){throw 'Incomplete team synthesis'}
            } finally {Pop-Location}
        }
    } else {
        $scriptArgs=@(switch($name){
            'ad' {@('run_w4a8_system.ps1')}
            'memory' {@('run_w4a8_memory.ps1','-SkipWaveRegression')}
            'kv' {@('run_kv_cache.ps1','-SkipBRegression')}
            'ce' {@('run_ffn.ps1','-SimOnly')}
            'valid' {@('run_w4a8_valid.ps1')}
        })
        $script=Join-Path $root ('scripts\'+$scriptArgs[0])
        $extra=@();if($scriptArgs.Count -gt 1){$extra=$scriptArgs[1..($scriptArgs.Count-1)]}
        Invoke-Recorded $shell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-VivadoBin',$VivadoBin)+$extra) (Join-Path $work ($name+'.log'))
    }
    Set-Content -Encoding ascii $pass 'PASS'
    $results[$name]='PASS'
    $results|ConvertTo-Json|Set-Content -Encoding utf8 (Join-Path $work 'latest_run.json')
    Write-Host "TEAM_SUITE_PASS $name"
}
Write-Host 'TEAM_INTEGRATION_VALIDATION_PASS'

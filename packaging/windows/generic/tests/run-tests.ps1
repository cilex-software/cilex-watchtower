#requires -Version 5.1
param([string]$PythonPath,[string]$MakensisPath,[string]$VsDevCmdPath)
$ErrorActionPreference='Stop'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($name in @('test-requirements.ps1','test-dependencies.ps1','test-common-source.ps1','test-entry.ps1','test-install.ps1','test-remote.ps1','test-build.ps1')){
    $arguments=@('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot $name))
    if($name -eq 'test-build.ps1'){
        if($PythonPath){$arguments+=@('-PythonPath',$PythonPath)}
        if($MakensisPath){$arguments+=@('-MakensisPath',$MakensisPath)}
    }
    & $powershell @arguments
    if($LASTEXITCODE -ne 0){throw ('Deployment checks failed: '+$name)}
}
if($VsDevCmdPath){
    & $powershell -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test-launcher.ps1') -VsDevCmdPath $VsDevCmdPath
    if($LASTEXITCODE -ne 0){throw 'Native startup helper checks failed.'}
}else{Write-Output 'Native startup helper checks were not run; provide -VsDevCmdPath to compile and test them.'}
Write-Output 'All generic deployment fixture suites passed. These checks do not install or reboot a station.'

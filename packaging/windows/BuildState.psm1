# Common preflight for Windows build entry points; Python is already a build input.
Set-StrictMode -Version Latest
$script:CilexBuildGuard = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build_state.py'))

function Start-CilexBuild {
    param([string]$Repository,[string]$BuildProfile,[string]$Revision='HEAD',
          [ValidateSet('Yes','No')][string]$Update='Yes',
          [ValidateSet('Ask','Yes','No')][string]$Rebuild='Ask',
          [hashtable]$Settings=@{},[string]$Python='python',[switch]$NonInteractive,
          [string]$Cache,[ValidateSet('Yes','No')][string]$Snapshot='Yes',[string[]]$ExistingBinary=@(),[string]$Git='git')
    $planPath=Join-Path ([IO.Path]::GetTempPath()) ('cilex-build-'+[Guid]::NewGuid().ToString('N')+'.json')
    $settingsPath=$planPath+'.settings.json'
    [IO.File]::WriteAllText($settingsPath,($Settings|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding $false))
    $choice=if($NonInteractive -and $Rebuild -eq 'Ask'){'no'}else{$Rebuild.ToLowerInvariant()}
    $arguments=@('-I','-B','-X','utf8',$script:CilexBuildGuard,'prepare','--repository',$Repository,
        '--profile',$BuildProfile,'--revision',$Revision,'--plan',$planPath,'--update',$Update.ToLowerInvariant(),
        '--rebuild',$choice,'--snapshot',$Snapshot.ToLowerInvariant(),'--git',$Git,'--settings-file',$settingsPath)
    if($Cache){$arguments+=@('--cache',$Cache)}
    foreach($path in $ExistingBinary){$arguments+=@('--candidate',[IO.Path]::GetFullPath($path))}
    $encoding=[Console]::OutputEncoding
    try{
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding $false
        & $Python @arguments | ForEach-Object { Write-Host $_ }
    }finally{[Console]::OutputEncoding=$encoding;[IO.File]::Delete($settingsPath)}
    if($LASTEXITCODE -ne 0){throw 'Build source/existing-output check failed. No compilation started.'}
    $plan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8|ConvertFrom-Json
    $plan|Add-Member -NotePropertyName PlanPath -NotePropertyValue $planPath
    $plan|Add-Member -NotePropertyName Python -NotePropertyValue $Python
    return $plan
}

function Complete-CilexBuild {
    param($Plan,[hashtable]$Outputs,[hashtable]$Metadata=@{})
    $metadataPath=$Plan.PlanPath+'.metadata.json'
    [IO.File]::WriteAllText($metadataPath,($Metadata|ConvertTo-Json -Compress -Depth 40),(New-Object Text.UTF8Encoding $false))
    $arguments=@('-I','-B','-X','utf8',$script:CilexBuildGuard,'record','--plan',$Plan.PlanPath,
        '--metadata-file',$metadataPath)
    foreach($role in $Outputs.Keys){$arguments+=@('--output',[string]$role,[IO.Path]::GetFullPath([string]$Outputs[$role]))}
    $encoding=[Console]::OutputEncoding
    try{
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding $false
        & $Plan.Python @arguments | ForEach-Object { Write-Host $_ }
    }finally{[Console]::OutputEncoding=$encoding;[IO.File]::Delete($metadataPath)}
    if($LASTEXITCODE -ne 0){throw 'Build output could not be verified or recorded; success was not recorded.'}
    [IO.File]::Delete($Plan.PlanPath)
}

Export-ModuleMember -Function Start-CilexBuild,Complete-CilexBuild

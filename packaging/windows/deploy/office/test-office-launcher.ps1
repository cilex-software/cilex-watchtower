#requires -Version 5.1
# Hermetic launcher checks: disposable files and a harmless child stub only.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:passed=0
function Assert($Value,[string]$Name) {
    if (-not $Value) { throw ('FAIL: '+$Name) }
    $script:passed++
}
$gatePath=Join-Path $PSScriptRoot 'office-launcher-gate.ps1'
$factoryPath=Join-Path $PSScriptRoot 'New-OfficeUpdateLauncher.ps1'
$tokens=$null; $errors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile($gatePath,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'gate parses in Windows PowerShell 5.1'
foreach ($node in $tree.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $node.Extent.Text
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('cilex-office-launcher-'+[Guid]::NewGuid().ToString('N'))
# The actual CMD must carry Unicode and shell metacharacters through an environment variable.
$unicode=[string][char]0x0410+[char]0x0434+[char]0x043C+[char]0x0438+[char]0x043D
$distribution=Join-Path $root ($unicode+' Office & wall ! (test) ^ 100%')
[IO.Directory]::CreateDirectory((Join-Path $distribution 'package'))|Out-Null
try {
    $entryContent="Import-Module ScheduledTasks -ErrorAction Stop; Import-Module CimCmdlets -ErrorAction Stop; if ((Get-FileHash -LiteralPath `$PSCommandPath -Algorithm SHA256).Hash -notmatch '^[A-F0-9]{64}$') { exit 94 }; Write-Output 'HARMLESS_CHILD_MODULES_OK'; exit 17"
    [IO.File]::WriteAllText((Join-Path $distribution 'Update-Office.ps1'),$entryContent,[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $distribution 'update-local-package.ps1'),'fixture wrapper; never executed',[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $distribution 'package\manifest.json'),'{}',[Text.Encoding]::ASCII)
    $pins=@('Update-Office.ps1','update-local-package.ps1','package\manifest.json')|ForEach-Object{(Get-FileHash -LiteralPath (Join-Path $distribution $_) -Algorithm SHA256).Hash}
    Assert ($null -eq (Test-OfficeLauncherFiles $distribution $pins)) 'real files accept three exact pins'
    $script:context=[pscustomobject]@{HostName='WT-OFFICE-01';Administrator=$true;Interactive=$true;Session=1;Policy='Restricted';Managed=$false}
    $script:consent=$true; $script:prompts=0; $script:children=@(); $script:mutateOnConsent=$false
    function Get-OfficeLauncherContext { return $script:context }
    function Read-OfficeLauncherConsent {
        $script:prompts++
        if ($script:mutateOnConsent) { [IO.File]::AppendAllText((Join-Path $distribution 'Update-Office.ps1'),'changed') }
        return $script:consent
    }
    function Invoke-OfficeLauncherChild {
        param([string]$Entry,[bool]$TemporaryException)
        $script:children+=@([pscustomobject]@{Entry=$Entry;Exception=$TemporaryException})
        return 17
    }
    Assert ((Start-OfficePackageUpdate $distribution $pins) -eq 17) 'approved one-run exception propagates child status'
    Assert ($script:prompts -eq 1 -and $script:children.Count -eq 1 -and $script:children[0].Exception) 'one approval precedes one temporary child'
    Assert ($script:children[0].Entry -eq (Join-Path $distribution 'Update-Office.ps1')) 'Unicode and special path remains one literal child argument'
    $script:children=@(); $script:prompts=0; $script:consent=$false
    Assert ((Start-OfficePackageUpdate $distribution $pins) -eq 2) 'decline returns cancelled'
    Assert ($script:prompts -eq 1 -and $script:children.Count -eq 0) 'decline never invokes updater'
    $script:context.Managed=$true; $script:prompts=0
    Assert ((Start-OfficePackageUpdate $distribution $pins) -eq 1) 'managed Restricted policy refuses exception'
    Assert ($script:prompts -eq 0 -and $script:children.Count -eq 0) 'managed rejection occurs before consent and updater'
    $script:context.Policy='RemoteSigned'
    Assert ((Start-OfficePackageUpdate $distribution $pins) -eq 17) 'allowed managed policy is honored with normal child'
    Assert ($script:prompts -eq 0 -and -not $script:children[0].Exception) 'normal execution never requests or applies exception'
    $script:children=@(); $script:context.Managed=$false; $script:context.Policy='AllSigned'
    Assert ((Start-OfficePackageUpdate $distribution $pins) -eq 17) 'AllSigned receives normal execution only'
    Assert ($script:prompts -eq 0 -and -not $script:children[0].Exception) 'normal failure is never retried with bypass'
    $script:children=@(); $script:context.Policy='Restricted'; $script:consent=$true
    foreach ($property in @('HostName','Administrator','Interactive','Session')) {
        $old=$script:context.$property
        $script:context.$property=switch($property){'HostName'{'OTHER-PC'};'Administrator'{$false};'Interactive'{$false};'Session'{0}}
        Assert ((Start-OfficePackageUpdate $distribution $pins) -eq 1) ('reject invalid '+$property)
        $script:context.$property=$old
    }
    Assert ($script:prompts -eq 0 -and $script:children.Count -eq 0) 'identity failures precede consent and updater'
    foreach ($index in 0..2) {
        $bad=@($pins);$bad[$index]='0'*64
        Assert ((Start-OfficePackageUpdate $distribution $bad) -eq 1) ('reject changed pin '+$index)
    }
    Assert ($script:prompts -eq 0 -and $script:children.Count -eq 0) 'all hash failures precede consent and updater'
    $script:mutateOnConsent=$true
    Assert ((Start-OfficePackageUpdate $distribution $pins) -eq 1) 'second verification catches change during approval'
    Assert ($script:children.Count -eq 0) 'approval cannot admit modified entry'
    $script:mutateOnConsent=$false
    [IO.File]::WriteAllText((Join-Path $distribution 'Update-Office.ps1'),$entryContent,[Text.Encoding]::ASCII)
    & $factoryPath -DistributionPath $distribution -EntrySha256 $pins[0] -WrapperSha256 $pins[1] -ManifestSha256 $pins[2] | Out-Null
    $cmdPath=Join-Path $distribution 'Update-Office.cmd'
    $cmd=[IO.File]::ReadAllText($cmdPath)
    Assert ($cmd -notmatch '[^\x00-\x7F]') 'generated launcher is ASCII'
    Assert ($cmd -notmatch 'EncodedCommand|Set-ExecutionPolicy|Unblock-File') 'launcher contains no encoded commands or persisted policy changes'
    Assert ($cmd -match 'setlocal DisableDelayedExpansion' -and $cmd -match 'CILEX_OFFICE_UPDATE_ROOT=%~dp0') 'CMD passes its directory without code interpolation'
    Assert ($cmd -match [regex]::Escape($pins[0]) -and $cmd -match [regex]::Escape($pins[1]) -and $cmd -match [regex]::Escape($pins[2])) 'all final pins are included'
    # Replace only host/context and child transport functions in a DISPOSABLE copy.
    # The CMD interpreter and powershell.exe still parse the exact generated gate.
    $commandLine=@($cmd -split '\r?\n'|Where-Object{$_ -match ' -Command '})[0]
    $inline=$commandLine.Substring($commandLine.IndexOf(' -Command ')+11).Trim('"')
    $inlineTree=[Management.Automation.Language.Parser]::ParseInput($inline,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'final inline gate parses'
    $replacement=@{
        'Get-OfficeLauncherContext'="function Get-OfficeLauncherContext { return [pscustomobject]@{HostName='WT-OFFICE-01';Administrator=`$true;Interactive=`$true;Session=1;Policy='RemoteSigned';Managed=`$false}; }"
        'Invoke-OfficeLauncherChild'="function Invoke-OfficeLauncherChild { param([string]`$Entry,[bool]`$TemporaryException); if (`$TemporaryException) { return 92; }; if (-not (Test-Path -LiteralPath `$Entry -PathType Leaf)) { return 93; }; Write-Host 'CMD_PATH_OK'; return 23; }"
    }
    foreach($name in $replacement.Keys) {
        $definition=@($inlineTree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object{$_.Name -eq $name})[0]
        $inline=$inline.Replace($definition.Extent.Text,$replacement[$name])
    }
    $probeCmd=Join-Path $distribution 'probe.cmd'
    $probe=$cmd.Replace($commandLine,('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "'+$inline+'"'))
    [IO.File]::WriteAllText($probeCmd,$probe,[Text.Encoding]::ASCII)
    # A separate disposable gate keeps the real module initialization and real
    # child invocation; only the station/administrator facts are replaced. The
    # pinned child imports OS modules and hashes its own harmless fixture file.
    $originalInline=$commandLine.Substring($commandLine.IndexOf(' -Command ')+11).Trim('"')
    $originalTree=[Management.Automation.Language.Parser]::ParseInput($originalInline,[ref]$tokens,[ref]$errors)
    $contextDefinition=@($originalTree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object{$_.Name -eq 'Get-OfficeLauncherContext'})[0]
    $actualContext=$contextDefinition.Extent.Text.Replace('function Get-OfficeLauncherContext','function Get-OfficeLauncherActualContext')
    $fixtureContext=$actualContext+" function Get-OfficeLauncherContext { `$actual=Get-OfficeLauncherActualContext; return [pscustomobject]@{HostName='WT-OFFICE-01';Administrator=`$true;Interactive=`$true;Session=1;Policy='RemoteSigned';Managed=`$false}; }"
    $childInline=$originalInline.Replace($contextDefinition.Extent.Text,$fixtureContext)
    $childCmd=Join-Path $distribution 'probe-real-child.cmd'
    [IO.File]::WriteAllText($childCmd,$cmd.Replace($commandLine,('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "'+$childInline+'"')),[Text.Encoding]::ASCII)
    $parentProbe=Join-Path $root 'probe-parent.ps1'
    [IO.File]::WriteAllText($parentProbe,('param([string]$CommandPath)' + "`r`n" + '$env:CILEX_OFFICE_LAUNCHER_PROBE=$CommandPath' + "`r`n" + '& $env:ComSpec /d /s /c ''""%CILEX_OFFICE_LAUNCHER_PROBE%""'' | Out-Host' + "`r`n" + 'exit $LASTEXITCODE'),[Text.Encoding]::ASCII)
    $parents=@([pscustomobject]@{Name='Windows PowerShell 5.1';Path=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')})
    $pwshCommand=Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $pwsh=if($pwshCommand){$pwshCommand.Source}else{Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'}
    if(Test-Path -LiteralPath $pwsh -PathType Leaf){$parents+=@([pscustomobject]@{Name='PowerShell 7';Path=$pwsh})}
    # Use an environment variable so cmd never receives an interpolated source path.
    $previous=$env:CILEX_OFFICE_LAUNCHER_PROBE
    try {
        $env:CILEX_OFFICE_LAUNCHER_PROBE=$probeCmd
        $output=& $env:ComSpec /d /s /c '""%CILEX_OFFICE_LAUNCHER_PROBE%""' 2>&1
        if ($LASTEXITCODE -ne 23) { Write-Output ('Fixture CMD status: '+$LASTEXITCODE); Write-Output $output }
        Assert ($LASTEXITCODE -eq 23 -and ($output -join "`n") -match 'CMD_PATH_OK') 'actual CMD/PS5.1 Unicode path and exit status pass without updater'
        if ([Environment]::MachineName -ne 'WT-OFFICE-01') {
            $env:CILEX_OFFICE_LAUNCHER_PROBE=$cmdPath
            $output=& $env:ComSpec /d /s /c '""%CILEX_OFFICE_LAUNCHER_PROBE%""' 2>&1
            Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'WT-OFFICE-01 only') 'unmodified generated CMD refuses another computer before any update'
            foreach($parent in $parents){
                $output=& $parent.Path -NoProfile -File $parentProbe -CommandPath $cmdPath 2>&1
                Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'WT-OFFICE-01 only') ($parent.Name+' parent reaches unmodified CMD host refusal')
                $output=& $parent.Path -NoProfile -File $parentProbe -CommandPath $childCmd 2>&1
                if($LASTEXITCODE -ne 17){Write-Output ('Harmless child parent status: '+$LASTEXITCODE);Write-Output $output}
                Assert ($LASTEXITCODE -eq 17 -and ($output -join "`n") -match 'HARMLESS_CHILD_MODULES_OK') ($parent.Name+' parent imports trusted OS modules and preserves harmless child output/exit')
            }
        }
    } finally { $env:CILEX_OFFICE_LAUNCHER_PROBE=$previous }
    $childDefinition=@($tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object{$_.Name -eq 'Invoke-OfficeLauncherChild'})[0]
    Invoke-Expression $childDefinition.Extent.Text
    # Match the process-local Desktop lookup used by the real gate before a
    # direct child-only check. The parent environment is restored afterwards.
    $previousModulePath=$env:PSModulePath
    try {
        $env:PSModulePath=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')+[IO.Path]::PathSeparator+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
        Assert ((Invoke-OfficeLauncherChild (Join-Path $distribution 'Update-Office.ps1') $false) -eq 17) 'real normal child preserves output and exact exit status for harmless stub'
    } finally { $env:PSModulePath=$previousModulePath }
    Assert (-not (Test-Path -LiteralPath (Join-Path $distribution 'result.json'))) 'fixtures did not create installation results'
    Write-Output ('Office CMD launcher: '+$script:passed+' checks passed. No updates or policy changes were run.')
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'cilex-office-launcher-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

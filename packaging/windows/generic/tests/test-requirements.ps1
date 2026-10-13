#requires -Version 5.1
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\Requirements.psm1') -Force
$script:passed=0
function Check([bool]$Condition,[string]$Label) {if(-not $Condition){throw ('FAIL: '+$Label)};$script:passed++}
$context=[pscustomobject]@{Language='en';CacheDir='C:\fixture\cache';WorkDir='C:\fixture\work';OutputDir='D:\fixture\out';InstallDir='D:\fixture\app';DependencyMode='Offline';TargetUser='TEST\operator';BackendUrl='https://example.invalid'}
$facts=@{IsWindows=$true;NativeArchitecture='AMD64';Process64=$true;OsBuild=26100;ProductType=1;RamBytes=16GB;AvailableRamBytes=8GB;CpuCount=8;Graphics=@([pscustomobject]@{Name='Fixture';DriverVersion='1';ConfigManagerErrorCode=0});Volumes=@{'C:\'=200GB;'D:\'=200GB};RebootPending=$false;Identity='TEST\operator';SessionId=1;TaskService='Running';MediaFoundationPresent=$true}
$r=@(Get-WtgRequirements $context Build $facts)
Check (@($r|Where-Object State -eq BLOCKED).Count -eq 0) 'supported baseline has no hard failure'
Check (($r|Where-Object Id -eq platform.os).State -eq 'PASS') 'OS meets dependency floor'
Check (($r|Where-Object Id -eq platform.media).State -eq 'PASS') 'Windows media files reported separately'
$facts.MediaFoundationPresent=$false;$mediaFindings=@(Get-WtgRequirements $context Target $facts)
$media=$mediaFindings|Where-Object Id -eq platform.media
Check ($media.State -eq 'WARNING' -and $media.CanOverride) 'missing Windows media permits explicit installation attempt'
Check ($media.Message -match 'Media Feature Pack' -and $media.Message -match 'support.microsoft.com') 'missing media has official repair instructions'
$facts.MediaFoundationPresent=$null;$mediaFindings=@(Get-WtgRequirements $context Target $facts)
Check (($mediaFindings|Where-Object Id -eq platform.media).State -eq 'UNKNOWN') 'unknown media state not passed'
$facts.MediaFoundationPresent=$true
Check (($r|Where-Object Id -eq capacity.validation).State -eq 'UNKNOWN') 'unmeasured workload not claimed passed'
Check (($r|Where-Object Id -eq network.check).State -eq 'UNKNOWN') 'offline endpoint checks skipped'
Check (@($r|Where-Object Id -match '^disk\.').Count -ge 2) 'disk volumes assessed separately'
$facts.AvailableRamBytes=1GB;$r=@(Get-WtgRequirements $context Build $facts)
$warning=$r|Where-Object Id -eq memory.available
Check ($warning.State -eq 'WARNING' -and $warning.CanOverride) 'temporary memory pressure is overridable'
Check (($r|Where-Object Id -eq memory.installed).State -eq 'PASS') 'physical capacity separate from temporary pressure'
$facts.OsBuild=17763;$r=@(Get-WtgRequirements $context Build $facts)
Check (($r|Where-Object Id -eq platform.os).State -eq 'WARNING') 'build OS higher floor'
$r=@(Get-WtgRequirements $context Target $facts)
Check (($r|Where-Object Id -eq platform.os).State -eq 'PASS') 'runtime OS lower floor'
Check (($r|Where-Object Id -eq platform.lifecycle).State -eq 'UNKNOWN') 'Windows support entitlement not invented'
Check (($r|Where-Object Id -eq graphics.adapter).State -eq 'UNKNOWN') 'adapter inventory does not prove decoding'
$facts.NativeArchitecture='ARM64';$r=@(Get-WtgRequirements $context Target $facts)
Check ((($r|Where-Object Id -eq platform.architecture).State -eq 'BLOCKED') -and -not ($r|Where-Object Id -eq platform.architecture).CanOverride) 'unsupported architecture hard failure'
$facts.NativeArchitecture='AMD64';$facts.Process64=$false;$r=@(Get-WtgRequirements $context Target $facts)
Check (($r|Where-Object Id -eq platform.shell).State -eq 'BLOCKED') '32-bit bootstrap refused'
$facts.Process64=$true;$facts.RamBytes=$null;$facts.RebootPending=$null;$facts.OsBuild=$null;$r=@(Get-WtgRequirements $context Target $facts)
Check (($r|Where-Object Id -eq memory.installed).State -eq 'UNKNOWN') 'missing RAM not pass'
Check (($r|Where-Object Id -eq system.restart).State -eq 'UNKNOWN') 'unreadable reboot state not pass'
Check (($r|Where-Object Id -eq platform.os).State -eq 'UNKNOWN') 'missing OS not pass'
$facts.Volumes['D:\']=1GB;$r=@(Get-WtgRequirements $context Target $facts)
Check (($r|Where-Object Id -eq 'disk.D').State -eq 'WARNING') 'disk estimate permits explicit override'
$facts.TaskService='Stopped';$r=@(Get-WtgRequirements $context Target $facts)
Check (($r|Where-Object Id -eq startup.scheduler).State -eq 'BLOCKED') 'unavailable scheduler blocks requested startup'
$context.Language='ru';$r=@(Get-WtgRequirements $context Target $facts)
Check (($r|Where-Object Id -eq memory.installed).Message -match 'память') 'Russian memory guidance'
Check (($r|Where-Object Id -eq platform.os).Message -match 'Windows') 'Russian keeps product name'
$facts.IsWindows=$false;$r=@(Get-WtgRequirements $context Target $facts)
Check ($r.Count -eq 1 -and $r[0].State -eq 'BLOCKED') 'non-Windows safe early result'
Check ((Test-WtgReadOnlyEndpoint 'https://user:secret@example.invalid') -eq 'InvalidAddress') 'embedded credentials refused before network'
Check ((Test-WtgReadOnlyEndpoint 'https://example.invalid/?token=hidden') -eq 'InvalidAddress') 'query tokens refused before network'
Write-Output ('Requirements fixtures: '+$script:passed+' passed.')

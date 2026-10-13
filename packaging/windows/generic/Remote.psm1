# Windows PowerShell 5.1. Existing authenticated channels only; no policy changes.
Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'Install.psm1') -Force

function Get-WtgRemoteStage([string]$TargetHost,[string]$RemoteStagePath,[string]$RunId,[string]$RemoteLocalPath='') {
    if($TargetHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' -or $RunId -notmatch '^[A-Za-z0-9_-]{8,80}$'){throw 'REMOTE_TARGET_OR_RUN_INVALID'}
    if(-not $RemoteStagePath){$RemoteStagePath='\\'+$TargetHost+'\C$\CilexWatchtower-Deploy'}
    if($RemoteStagePath -notmatch '^\\\\([^\\]+)\\([^\\]+)\\(.+)$' -or $matches[1] -ne $TargetHost){throw 'REMOTE_STAGE_HOST_MISMATCH'}
    $share=$matches[2];$tail=$matches[3]
    if($tail -match '(^|\\)\.\.?($|\\)|[\x00-\x1f"<>|?*:%]'){throw 'REMOTE_STAGE_PATH_INVALID'}
    if(-not $RemoteLocalPath){
        if($share -notmatch '^([A-Za-z])\$$'){throw 'REMOTE_NONADMIN_SHARE_LOCAL_PATH_REQUIRED'}
        $RemoteLocalPath=$matches[1]+':\'+$tail
    }
    if($RemoteLocalPath -notmatch '^[A-Za-z]:\\' -or $RemoteLocalPath -match '[\x00-\x1f"<>|?*]'){throw 'REMOTE_LOCAL_STAGE_INVALID'}
    return [pscustomobject]@{UNC=($RemoteStagePath.TrimEnd('\')+'\'+$RunId);Local=($RemoteLocalPath.TrimEnd('\')+'\'+$RunId);Share=('\\'+$TargetHost+'\'+$share)}
}
function New-WtgRemoteRequest($Context,[string]$PackagePath,[string]$ManifestHash,[string]$ExpectedHost,[string]$TargetSid='') {
    $req=[ordered]@{RunId=$Context.RunId;PackagePath=$PackagePath;ExpectedHost=$ExpectedHost;TargetSid=$TargetSid;PackageManifestSha256=$ManifestHash;NonInteractive=$true}
    foreach($name in @('InstallDir','InstallScope','TargetUser','StartupMode','Language','BackendUrl','PackageSha256','AdoptExisting','LegacyTaskName','ConsentUnattended','OverrideRequirements','DependencyMode','VerifyOnly','DeferEnrollment','ConfirmNoManualSignIn')){$req[$name]=Get-WtgOption $Context $name $null}
    $req.VerifyOnly=[bool]$req.VerifyOnly
    if($req.VerifyOnly -and -not $req.StartupMode){$req.StartupMode='AfterSignIn'}
    return $req
}
function Assert-WtgRemoteResult($Result,[string]$RunId,[string]$ExpectedHost,[string]$ExpectedSid='',[string[]]$AllowedStatus=@('InstalledWithDeferredChecks','VerificationCompleted','RestartRequired')) {
    foreach($name in @('RunId','Target','Status')){if(-not $Result -or -not $Result.PSObject.Properties[$name] -or $Result.$name -isnot [string]){throw 'REMOTE_RESULT_INVALID'}}
    if($Result.RunId -ne $RunId -or $Result.Target -ne $ExpectedHost){throw 'REMOTE_RESULT_IDENTITY_MISMATCH'}
    if($Result.Status -in @('Failed','Error')){
        if($Result.PSObject.Properties['ErrorCode'] -and $Result.ErrorCode -eq 'REMOTE_SCRIPT_POLICY_BLOCKED'){throw 'REMOTE_SCRIPT_POLICY_BLOCKED'}
        throw 'REMOTE_TARGET_OPERATION_FAILED_SEE_RESULT'
    }
    if($Result.Status -notin $AllowedStatus){throw 'REMOTE_RESULT_STATUS_INVALID'}
    if($Result.Status -eq 'RestartRequired'){
        if(-not $Result.PSObject.Properties['ErrorCode'] -or $Result.ErrorCode -ne 'PREREQUISITE_RESTART_REQUIRED'){throw 'REMOTE_RESULT_INVALID'}
        return $Result
    }
    if(-not $Result.PSObject.Properties['TargetSid'] -or $Result.TargetSid -isnot [string] -or $Result.TargetSid -notmatch '^S-1-\d+(?:-\d+)+$' -or $Result.TargetSid -in @('S-1-5-18','S-1-5-19','S-1-5-20')){throw 'REMOTE_RESULT_USER_MISMATCH'}
    if($ExpectedSid -and $Result.TargetSid -ne $ExpectedSid){throw 'REMOTE_RESULT_USER_MISMATCH'}
    return $Result
}
function Read-WtgProtectedRemoteRecord([string]$Path) {
    Assert-WtgStageAcl (Get-WtgStageAcl $Path -File) $true
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.Length -gt 1MB){throw 'REMOTE_RECORD_TOO_LARGE'}
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop)
}
function Read-WtgRetainedRemoteRun([string]$StagePath) {
    $result=Join-Path $StagePath 'install-result.json';$request=Join-Path $StagePath 'install-request.json'
    if(-not(Test-Path -LiteralPath $result)){throw 'REMOTE_PREVIOUS_RUN_NOT_COMPLETE_NO_RELAUNCH'}
    if(-not(Test-Path -LiteralPath $request)){throw 'REMOTE_RETAINED_REQUEST_MISSING'}
    return [pscustomobject]@{Request=(Read-WtgProtectedRemoteRecord $request);Result=(Read-WtgProtectedRemoteRecord $result)}
}
function Assert-WtgRetainedOutcome($Records,$Context,[string]$RunId,[string]$ExpectedHost,[string]$ExpectedSid) {
    try{$request=$Records.Request|ConvertFrom-Json;$result=$Records.Result|ConvertFrom-Json}catch{throw 'REMOTE_RETAINED_RECORD_INVALID'}
    foreach($name in @('RunId','ExpectedHost','TargetSid','TargetUser','InstallDir','InstallScope','StartupMode')){
        if(-not $request.PSObject.Properties[$name] -or $request.$name -isnot [string]){throw 'REMOTE_RETAINED_REQUEST_INVALID'}
    }
    if(-not $request.PSObject.Properties['VerifyOnly'] -or $request.VerifyOnly -isnot [bool]){throw 'REMOTE_RETAINED_REQUEST_INVALID'}
    if($request.RunId -ne $RunId -or $request.ExpectedHost -ne $ExpectedHost -or $request.TargetSid -ne $ExpectedSid -or $request.TargetUser -ne $Context.TargetUser){throw 'REMOTE_RETAINED_REQUEST_IDENTITY_MISMATCH'}
    if($request.InstallScope -notin @('User','Machine') -or $request.StartupMode -notin @('AfterSignIn','UnattendedReboot') -or $request.InstallDir -notmatch '^[A-Za-z]:\\'){throw 'REMOTE_RETAINED_REQUEST_INVALID'}
    foreach($name in @('InstallDir','InstallScope','StartupMode')){
        $wanted=Get-WtgOption $Context $name ''
        if($wanted -and $wanted -ne $request.$name){throw 'REMOTE_RETAINED_REQUEST_INTENT_MISMATCH'}
    }
    $verify=[bool](Get-WtgOption $request 'VerifyOnly' $false)
    if($verify -ne [bool](Get-WtgOption $Context 'VerifyOnly' $false)){throw 'REMOTE_RETAINED_REQUEST_INTENT_MISMATCH'}
    $allowed=if($verify){@('VerificationCompleted')}else{@('InstalledWithDeferredChecks','RestartRequired')}
    $null=Assert-WtgRemoteResult $result $RunId $ExpectedHost $ExpectedSid $allowed
    if($result.Status -eq 'RestartRequired'){return $result}
    foreach($name in @('InstallDir','InstallScope')){if(-not $result.PSObject.Properties[$name] -or $result.$name -isnot [string] -or $result.$name -ne $request.$name){throw 'REMOTE_RETAINED_RESULT_INTENT_MISMATCH'}}
    if(-not $result.PSObject.Properties['Runtime'] -or -not $result.Runtime -or -not $result.Runtime.PSObject.Properties['State'] -or $result.Runtime.State -notin @('DeferredUntilSignIn','VerifiedCurrentSession','VerifiedProcessesVisibilityDeferred')){throw 'REMOTE_RESULT_INVALID'}
    if(-not $verify){
        $hash=Get-WtgOption $request 'PackageManifestSha256' ''
        if($hash -notmatch '^[0-9a-fA-F]{64}$' -or -not $result.PSObject.Properties['ManifestSha256'] -or $result.ManifestSha256 -ne $hash){throw 'REMOTE_RETAINED_PACKAGE_MISMATCH'}
        $wanted=Get-WtgOption $Context 'PackageManifestSha256' ''
        if($wanted -and $wanted -ne $hash){throw 'REMOTE_RETAINED_PACKAGE_MISMATCH'}
        if(-not $result.PSObject.Properties['StartupMode'] -or $result.StartupMode -ne $request.StartupMode){throw 'REMOTE_RETAINED_RESULT_INTENT_MISMATCH'}
    }
    return $result
}
function Set-WtgRemoteRequestDirectory($Request,$Identity) {
    if(-not $Request.InstallDir){
        if($Request.InstallScope -eq 'Machine'){$Request.InstallDir=Join-Path $Identity.ProgramFiles 'Cilex Watchtower'}
        else{$Request.InstallDir=Join-Path $Identity.LocalAppData 'Programs\Cilex Watchtower'}
    }
}
function Set-WtgRemoteStageAcl([string]$Path) {
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    foreach($id in @('S-1-5-18','S-1-5-32-544')){
        $sid=New-Object Security.Principal.SecurityIdentifier $id
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}
function Assert-WtgStageAcl($Acl,[bool]$Leaf=$false) {
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464','S-1-3-4')
    if($Acl.OwnerSid -notin $trusted){throw 'REMOTE_STAGE_UNTRUSTED_OWNER'}
    if($Acl.Reparse){throw 'REMOTE_STAGE_REPARSE_FORBIDDEN'}
    # CreateFiles/CreateDirectories on an ancestor do not permit replacing its
    # already admin-owned child. DeleteChild, delete, DACL and owner writes do.
    $danger=0x000D0150L -bor 0x10000000L -bor 0x40000000L
    if($Leaf){$danger=$danger -bor 0x6L}
    foreach($rule in $Acl.Rules){
        if($rule.Type -eq 'Allow' -and -not $rule.InheritOnly -and $rule.Sid -notin $trusted -and ([long]$rule.Rights -band $danger)){throw 'REMOTE_STAGE_WRITABLE_BY_OTHER_USERS'}
    }
}
function Get-WtgStageAcl([string]$Path,[switch]$File) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($File){if($item.PSIsContainer){throw 'REMOTE_RECORD_NOT_FILE'}}elseif(-not $item.PSIsContainer){throw 'REMOTE_STAGE_NOT_DIRECTORY'}
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object{[pscustomobject]@{Sid=$_.IdentityReference.Value;Rights=[long]$_.FileSystemRights;InheritOnly=[bool]($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly);Type=$_.AccessControlType.ToString()}})
    return [pscustomobject]@{OwnerSid=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;Reparse=[bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint);Rules=$rules}
}
function Assert-WtgStageMapping([string]$RemotePath,[string]$ExpectedLocal,[string]$ShareDirectory) {
    if($RemotePath -notmatch '^\\\\[^\\]+\\[^\\]+\\(.+)$'){throw 'REMOTE_STAGE_PATH_INVALID'}
    $mapped=[IO.Path]::GetFullPath([IO.Path]::Combine($ShareDirectory,$matches[1])).TrimEnd('\')
    if($mapped -ne [IO.Path]::GetFullPath($ExpectedLocal).TrimEnd('\')){throw 'REMOTE_STAGE_LOCAL_MAPPING_MISMATCH'}
}
function Initialize-WtgSecureRemoteStage([string]$TargetHost,$Stage,[switch]$Create) {
    Initialize-WtgRemoteNative
    if($Stage.UNC -notmatch '^(\\\\[^\\]+\\([^\\]+))\\(.+)$'){throw 'REMOTE_STAGE_PATH_INVALID'}
    $share=$matches[2]
    try{$shareDirectory=[WtgRemote.Native]::GetShareDirectory($TargetHost,$share)}catch{throw 'REMOTE_SHARE_MAPPING_QUERY_FAILED'}
    Assert-WtgStageMapping $Stage.UNC $Stage.Local $shareDirectory
    # Inspect from the volume root, including parents above an ordinary share.
    # SMB+SCM requires administrative access; a share alone cannot establish
    # that a local parent cannot be replaced by another account.
    $shareRoot='\\'+$TargetHost+'\'+$Stage.Local.Substring(0,1)+'$'
    $parts=$Stage.Local.Substring(3).Split('\')
    $paths=@($shareRoot);$current=$shareRoot
    foreach($part in $parts){$current=Join-Path $current $part;$paths += $current}
    for($i=0;$i -lt $paths.Count;$i++){
        $path=$paths[$i];$leaf=($i -eq $paths.Count-1)
        if(-not(Test-Path -LiteralPath $path)){
            if(-not $Create){throw 'REMOTE_STAGE_MISSING'}
            $errorCode=[WtgRemote.Native]::CreatePrivateDirectory($path)
            if($errorCode -notin @(0,183)){throw ('REMOTE_STAGE_CREATE_FAILED_'+$errorCode)}
        }
        Assert-WtgStageAcl (Get-WtgStageAcl $path) $leaf
    }
}
function Initialize-WtgSecureLocalStage([string]$Path,[switch]$Create) {
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[\x00-\x1f"<>|?*%]' -or $Path -match '(^|\\)\.\.?($|\\)'){throw 'REMOTE_STAGE_PATH_INVALID'}
    Initialize-WtgRemoteNative
    $root=[IO.Path]::GetPathRoot($Path);$parts=$Path.Substring($root.Length).TrimEnd('\').Split('\');$paths=@($root);$current=$root
    foreach($part in $parts){$current=Join-Path $current $part;$paths+=$current}
    for($i=0;$i -lt $paths.Count;$i++){
        $path=$paths[$i]
        if(-not(Test-Path -LiteralPath $path)){if(-not $Create){throw 'REMOTE_STAGE_MISSING'};$errorCode=[WtgRemote.Native]::CreatePrivateDirectory($path);if($errorCode -notin @(0,183)){throw ('REMOTE_STAGE_CREATE_FAILED_'+$errorCode)}}
        Assert-WtgStageAcl (Get-WtgStageAcl $path) ($i -eq $paths.Count-1)
    }
}
function Test-WtgSmbIntegrity($ClientConfiguration,[object[]]$Connections=@(),[string]$ShareName='') {
    if($ClientConfiguration -and $ClientConfiguration.RequireSecuritySignature){return $true}
    if(-not $ShareName){return $false}
    $matching=@($Connections|Where-Object{$_.PSObject.Properties['ShareName'] -and $_.ShareName -eq $ShareName})
    if(-not $matching.Count){return $false}
    foreach($c in $matching){if(-not(($c.PSObject.Properties['Signed'] -and $c.Signed) -or ($c.PSObject.Properties['Encrypted'] -and $c.Encrypted))){return $false}}
    return $true
}
function Initialize-WtgRemoteNative {
    if('WtgRemote.Native' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace WtgRemote {
 public static class Native {
 [StructLayout(LayoutKind.Sequential)] private struct ShareInfo2 {public IntPtr name; public uint type; public IntPtr remark; public uint permissions; public uint maxUses; public uint currentUses; public IntPtr path; public IntPtr password;}
 [StructLayout(LayoutKind.Sequential)] private struct WorkstationInfo100 {public uint platform;public IntPtr name;public IntPtr domain;public uint major;public uint minor;}
 [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes {public int length;public IntPtr descriptor;[MarshalAs(UnmanagedType.Bool)]public bool inherit;}
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text,uint revision,out IntPtr descriptor,out uint size);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CreateDirectory(string path,ref SecurityAttributes attributes);
 [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
 [DllImport("netapi32.dll",CharSet=CharSet.Unicode)] private static extern int NetShareGetInfo(string server,string name,int level,out IntPtr buffer);
 [DllImport("netapi32.dll",CharSet=CharSet.Unicode)] private static extern int NetWkstaGetInfo(string server,int level,out IntPtr buffer);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool LookupAccountName(string system,string account,IntPtr sid,ref uint sidSize,System.Text.StringBuilder domain,ref uint domainSize,out int use);
 [DllImport("netapi32.dll")] private static extern int NetApiBufferFree(IntPtr buffer);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool LogonUser(string user,string domain,string password,int type,int provider,out IntPtr token);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
 [DllImport("advapi32.dll",SetLastError=true)] public static extern bool ImpersonateLoggedOnUser(IntPtr token);
 [DllImport("advapi32.dll",SetLastError=true)] public static extern bool RevertToSelf();
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr OpenSCManager(string machine,string database,uint access);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateService(IntPtr manager,string name,string display,uint access,uint type,uint start,uint error,string path,string group,IntPtr tag,string dependencies,string account,string password);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr OpenService(IntPtr manager,string name,uint access);
 [DllImport("advapi32.dll",SetLastError=true)] public static extern bool StartService(IntPtr service,int count,IntPtr arguments);
 [DllImport("advapi32.dll",SetLastError=true)] public static extern bool DeleteService(IntPtr service);
 [DllImport("advapi32.dll")] public static extern bool CloseServiceHandle(IntPtr handle);
 public static IntPtr OpenManager(string machine,uint access) {return OpenSCManager(machine,null,access);}
 public static IntPtr CreateTemporaryService(IntPtr manager,string name,string command) {return CreateService(manager,name,name,0x10010,0x10,3,1,command,null,IntPtr.Zero,null,null,null);}
 public static string GetShareDirectory(string machine,string share) {IntPtr buffer;int result=NetShareGetInfo("\\\\"+machine,share,2,out buffer);if(result!=0)throw new Win32Exception(result);try{ShareInfo2 info=(ShareInfo2)Marshal.PtrToStructure(buffer,typeof(ShareInfo2));return Marshal.PtrToStringUni(info.path);}finally{NetApiBufferFree(buffer);}}
 public static string GetWindowsDirectory(string machine) {return GetShareDirectory(machine,"ADMIN$");}
 public static string GetServerName(string machine) {IntPtr buffer;int error=NetWkstaGetInfo("\\\\"+machine,100,out buffer);if(error!=0)throw new Win32Exception(error);try{return Marshal.PtrToStringUni(((WorkstationInfo100)Marshal.PtrToStructure(buffer,typeof(WorkstationInfo100))).name);}finally{NetApiBufferFree(buffer);}}
 public static string GetAccountSid(string machine,string account) {uint sidSize=0,domainSize=0;int use;LookupAccountName(machine,account,IntPtr.Zero,ref sidSize,null,ref domainSize,out use);int error=Marshal.GetLastWin32Error();if(error!=122 || sidSize==0 || sidSize>65536 || domainSize>65536)throw new Win32Exception(error);IntPtr sid=Marshal.AllocHGlobal((int)sidSize);try{var domain=new System.Text.StringBuilder((int)domainSize);if(!LookupAccountName(machine,account,sid,ref sidSize,domain,ref domainSize,out use))throw new Win32Exception(Marshal.GetLastWin32Error());if(use!=1)throw new InvalidOperationException("The requested identity is not a user.");return new System.Security.Principal.SecurityIdentifier(sid).Value;}finally{Marshal.FreeHGlobal(sid);}}
 public static int CreatePrivateDirectory(string path) {IntPtr descriptor;uint size;if(!ConvertStringSecurityDescriptorToSecurityDescriptor("O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)",1,out descriptor,out size))return Marshal.GetLastWin32Error();try{SecurityAttributes a=new SecurityAttributes();a.length=Marshal.SizeOf(typeof(SecurityAttributes));a.descriptor=descriptor;a.inherit=false;return CreateDirectory(path,ref a)?0:Marshal.GetLastWin32Error();}finally{LocalFree(descriptor);}}
 }
}
'@
}
function New-WtgSmbLaunch($Stage,[string]$Kind,[string]$RunId,[string]$WindowsDirectory) {
    if($WindowsDirectory -notmatch '^[A-Za-z]:\\' -or $WindowsDirectory -match '[\x00-\x1f"<>|?*%]'){throw 'REMOTE_WINDOWS_DIRECTORY_UNVERIFIED'}
    $script=[IO.Path]::Combine($Stage.Local,'helpers\install-target.ps1')
    $request=[IO.Path]::Combine($Stage.Local,($Kind+'-request.json'));$result=[IO.Path]::Combine($Stage.Local,($Kind+'-result.json'))
    $diagnostic=[IO.Path]::Combine($Stage.Local,($Kind+'-console.log'))
    $powershell=[IO.Path]::Combine($WindowsDirectory,'System32\WindowsPowerShell\v1.0\powershell.exe')
    $launcher=[IO.Path]::Combine($Stage.Local,($Kind+'-launch.cmd'))
    # Invoking the file normally still enforces the existing execution policy.
    # The outer command reports policy refusal even when the file cannot start.
    $command="try { & '"+$script.Replace("'","''")+"' -RequestPath '"+$request.Replace("'","''")+"' -ResultPath '"+$result.Replace("'","''")+"' -RunId '"+$RunId+"' } catch { " +
        "`$code = if (`$_.Exception -is [Management.Automation.PSSecurityException] -or `$_.FullyQualifiedErrorId -match 'PSSecurityException|UnauthorizedAccess') {'REMOTE_SCRIPT_POLICY_BLOCKED'} else {'REMOTE_HELPER_FAILED'}; " +
        "[ordered]@{RunId='"+$RunId+"';Target=`$env:COMPUTERNAME;Status='Failed';ErrorCode=`$code;ExitCode=13} | ConvertTo-Json | Set-Content -LiteralPath '"+$result.Replace("'","''")+"' -Encoding UTF8; exit 13 }"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $body='@echo off'+"`r`n"+'chcp 65001 >nul'+"`r`n"+'start "" /b "'+$powershell+'" -NoProfile -NonInteractive -EncodedCommand '+$encoded+' 1>"'+$diagnostic+'" 2>&1'+"`r`n"
    return [pscustomobject]@{Body=$body;EncodedCommand=$encoded;LauncherUNC=([IO.Path]::Combine($Stage.UNC,($Kind+'-launch.cmd')));Command=('"'+[IO.Path]::Combine($WindowsDirectory,'System32\cmd.exe')+'" /d /c "'+$launcher+'"')}
}
function Write-WtgSmbLaunch($Launch) {[IO.File]::WriteAllText($Launch.LauncherUNC,$Launch.Body,(New-Object Text.UTF8Encoding $false))}
function Assert-WtgServiceCleanup([bool]$Deleted,[int]$NativeError,[string]$ServiceName,[string]$RunId,[string]$ResultPath) {
    if($Deleted){return}
    $failure=New-Object InvalidOperationException 'REMOTE_SERVICE_CLEANUP_UNCONFIRMED'
    $failure.Data['ServiceName']=$ServiceName;$failure.Data['RunId']=$RunId
    $failure.Data['NativeError']=$NativeError;$failure.Data['ResultPath']=$ResultPath
    throw $failure
}
function Invoke-WtgSmbJob([string]$TargetHost,$Stage,[string]$Kind,[string]$RunId,[int]$TimeoutSeconds=900) {
    if($TargetHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' -or $Kind -notmatch '^[A-Za-z0-9_-]{1,20}$' -or $RunId -notmatch '^[A-Za-z0-9_-]{8,80}$' -or $Stage.Local -notmatch '^[A-Za-z]:\\' -or $Stage.Local -match '[\x00-\x1f"<>|?*%]'){throw 'REMOTE_JOB_ARGUMENT_INVALID'}
    Initialize-WtgRemoteNative
    Initialize-WtgSecureRemoteStage $TargetHost $Stage
    try{$windows=[WtgRemote.Native]::GetWindowsDirectory($TargetHost)}catch{throw 'REMOTE_WINDOWS_DIRECTORY_QUERY_FAILED'}
    $launch=New-WtgSmbLaunch $Stage $Kind $RunId $windows
    # The launcher contains no credential or untrusted command text. It is kept in
    # the already protected run directory; SCM gets a fully resolved system path.
    Write-WtgSmbLaunch $launch
    $name='cilex-deploy-'+$RunId+'-'+$Kind
    $manager=[WtgRemote.Native]::OpenManager($TargetHost,3)
    if($manager -eq [IntPtr]::Zero){throw ('REMOTE_SCM_OPEN_FAILED_'+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
    $service=[IntPtr]::Zero;$created=$false
    try{
        $service=[WtgRemote.Native]::CreateTemporaryService($manager,$name,$launch.Command)
        if($service -eq [IntPtr]::Zero){throw ('REMOTE_SERVICE_CREATE_FAILED_'+[Runtime.InteropServices.Marshal]::GetLastWin32Error())};$created=$true
        $started=[WtgRemote.Native]::StartService($service,0,[IntPtr]::Zero)
        if(-not $started){$errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error();if($errorCode -notin @(1053,1067)){throw 'REMOTE_SERVICE_START_FAILED'}}
        $remoteResult=Join-Path $Stage.UNC ($Kind+'-result.json');$clock=[Diagnostics.Stopwatch]::StartNew()
        while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds){
            if(Test-Path -LiteralPath $remoteResult){try{return (Get-Content -LiteralPath $remoteResult -Raw -Encoding UTF8|ConvertFrom-Json)}catch{}}
            $console=Join-Path $Stage.UNC ($Kind+'-console.log')
            if(Test-Path -LiteralPath $console){
                $item=Get-Item -LiteralPath $console -ErrorAction SilentlyContinue
                if($item -and $item.Length -lt 256KB){$message=Get-Content -LiteralPath $console -Raw -ErrorAction SilentlyContinue;if($message -match 'PSSecurityException|UnauthorizedAccess.*ExecutionPolicy|running scripts is disabled|выполнение сценариев отключено'){throw 'REMOTE_SCRIPT_POLICY_BLOCKED'}}
            }
            Start-Sleep -Seconds 2
        }
        throw 'REMOTE_RESULT_UNKNOWN_RECONCILE_RUN'
    }finally{
        $deleted=$true;$cleanupError=0
        if($service -ne [IntPtr]::Zero){
            if($created){$deleted=[WtgRemote.Native]::DeleteService($service);if(-not $deleted){$cleanupError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()}}
            $null=[WtgRemote.Native]::CloseServiceHandle($service)
        }
        $null=[WtgRemote.Native]::CloseServiceHandle($manager)
        Assert-WtgServiceCleanup $deleted $cleanupError $name $RunId ([IO.Path]::Combine($Stage.UNC,($Kind+'-result.json')))
    }
}
function Copy-WtgRemoteFiles([string]$Source,[string]$Destination,$Session=$null,[switch]$PackageOnly) {
    foreach($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File)){
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'REMOTE_REPARSE_FILE_FORBIDDEN'}
        $relative=$file.FullName.Substring($Source.TrimEnd('\').Length+1);$dest=[IO.Path]::Combine($Destination,$relative)
        if($PackageOnly -and $relative -ne 'manifest.json' -and -not $relative.StartsWith('payload\',[StringComparison]::OrdinalIgnoreCase)){continue}
        if($Session){Invoke-Command -Session $Session -ScriptBlock {param($p)[IO.Directory]::CreateDirectory((Split-Path -Parent $p))|Out-Null} -ArgumentList $dest;Copy-Item -LiteralPath $file.FullName -Destination $dest -ToSession $Session -Force}
        else{[IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $dest -Force}
    }
}
function Install-WtgRemotePackage($Context,[string]$PackagePath,[Management.Automation.PSCredential]$Credential,[ValidateSet('WinRM','SMBService')][string]$Transport='WinRM',[string]$RemoteStagePath='') {
    $target=[string](Get-WtgOption $Context 'TargetHost' '')
    $expected=[string](Get-WtgOption $Context 'ExpectedHost' '')
    $ip=$null;if([Net.IPAddress]::TryParse($target,[ref]$ip) -and -not $expected){throw 'REMOTE_IP_REQUIRES_EXPECTED_HOSTNAME'}
    if(-not $expected){$expected=$target.Split('.')[0]}
    if(-not(Get-WtgOption $Context 'TargetUser' '')){throw 'REMOTE_TARGET_USER_REQUIRED'}
    $resume=[string](Get-WtgOption $Context 'ResumeRunId' '')
    $remoteRun=if($resume){$resume}else{$Context.RunId}
    $stage=Get-WtgRemoteStage $target $RemoteStagePath $remoteRun (Get-WtgOption $Context 'RemoteStageLocalPath' (Get-WtgOption $Context 'RemoteLocalPath' ''))
    $verifyOnly=[bool](Get-WtgOption $Context 'VerifyOnly' $false)
    $root=$PackagePath
    if(-not $verifyOnly -and -not $resume){$root=Expand-WtgInstallInput $Context $PackagePath 'remote-package'}
    $package=$null
    if(-not $verifyOnly -and -not $resume){$package=Test-WtgPackage $root (Get-WtgOption $Context 'PackageManifestSha256' '')}
    $manifestHash=if($package){$package.ManifestSha256}else{''}
    $session=$null;$impersonation=$false;$token=[IntPtr]::Zero
    try{
        if($Transport -eq 'WinRM'){
            $args=@{ComputerName=$target;ErrorAction='Stop';SessionOption=(New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 1200000)}
            if($Credential){$args.Credential=$Credential}
            if($ip){$args.UseSSL=$true;$args.Authentication='Negotiate'}else{$args.Authentication='Kerberos'}
            $session=New-PSSession @args
            $actual=Invoke-Command -Session $session -ScriptBlock {$env:COMPUTERNAME}
            if($actual -ne $expected){throw 'REMOTE_HOSTNAME_MISMATCH'}
            $preparer=@{}
            foreach($name in @('Initialize-WtgRemoteNative','Assert-WtgStageAcl','Get-WtgStageAcl','Initialize-WtgSecureLocalStage','Read-WtgProtectedRemoteRecord','Read-WtgRetainedRemoteRun')){$preparer[$name]=(Get-Item ('Function:\'+$name)).ScriptBlock.ToString()}
            $prepared=Invoke-Command -Session $session -ScriptBlock {
                param($p,$functions,$resumeRun,$user)
                foreach($name in $functions.Keys){Set-Item -Path ('Function:\'+$name) -Value ([scriptblock]::Create($functions[$name]))}
                $sid=(New-Object Security.Principal.NTAccount $user).Translate([Security.Principal.SecurityIdentifier]).Value
                if(Test-Path -LiteralPath $p){
                    Initialize-WtgSecureLocalStage $p
                    return [pscustomobject]@{Sid=$sid;Retained=(Read-WtgRetainedRemoteRun $p)}
                }
                if($resumeRun){throw 'REMOTE_PREVIOUS_RUN_NOT_COMPLETE_NO_RELAUNCH'}
                Initialize-WtgSecureLocalStage $p -Create
                return [pscustomobject]@{Sid=$sid;Retained=$null}
            } -ArgumentList $stage.Local,$preparer,$resume,$Context.TargetUser
            if($prepared.Retained){return (Assert-WtgRetainedOutcome $prepared.Retained $Context $remoteRun $expected $prepared.Sid)}
            if($package){Copy-WtgRemoteFiles $root ([IO.Path]::Combine($stage.Local,'package')) $session -PackageOnly}
            $helpers=Join-Path $Context.RunDir 'remote-helpers';[IO.Directory]::CreateDirectory($helpers)|Out-Null
            foreach($name in @('install-target.ps1','Install.psm1','Common.psm1','StationVideoHealth.psm1','Requirements.psm1','requirements.json')){$path=Get-WtgHelperPath $name;Copy-Item -LiteralPath $path -Destination $helpers}
            Copy-WtgRemoteFiles $helpers ([IO.Path]::Combine($stage.Local,'helpers')) $session
            $request=New-WtgRemoteRequest $Context ([IO.Path]::Combine($stage.Local,'package')) $manifestHash $expected
            $request.Inspect=$true
            $inspect=Invoke-Command -Session $session -ScriptBlock {param($d,$r)$p=Join-Path $d 'inspect-request.json';[IO.File]::WriteAllText($p,($r|ConvertTo-Json -Depth 8));& (Join-Path $d 'helpers\install-target.ps1') -RequestPath $p -RunId $r.RunId -EmitJson} -ArgumentList $stage.Local,$request
            $identity=Assert-WtgRemoteResult ($inspect|ConvertFrom-Json) $Context.RunId $expected $prepared.Sid @('Inspected')
            if($identity.Status -ne 'Inspected'){throw 'REMOTE_INSPECTION_FAILED'}
            $request.Inspect=$false;$request.TargetSid=$identity.TargetSid;Set-WtgRemoteRequestDirectory $request $identity
            # Disconnect the retained PowerShell session if the bounded wait expires.
            $job=Invoke-Command -Session $session -AsJob -ScriptBlock {param($d,$r)$p=Join-Path $d 'install-request.json';[IO.File]::WriteAllText($p,($r|ConvertTo-Json -Depth 8));& (Join-Path $d 'helpers\install-target.ps1') -RequestPath $p -RunId $r.RunId -ResultPath (Join-Path $d 'install-result.json')} -ArgumentList $stage.Local,$request
            $clock=[Diagnostics.Stopwatch]::StartNew()
            while($job.State -in @('Running','NotStarted') -and $clock.Elapsed.TotalSeconds -lt 1200){$null=Wait-Job $job -Timeout 2}
            if($job.State -ne 'Completed'){
                if($session.State -eq 'Opened'){Disconnect-PSSession -Session $session -IdleTimeoutSec 7200 -ErrorAction Stop|Out-Null}
                $session=$null
                throw 'REMOTE_RESULT_UNKNOWN_RECONCILE_RUN'
            }
            $null=Receive-Job $job -ErrorAction Stop;Remove-Job $job
            $json=Invoke-Command -Session $session -ScriptBlock {param($p)Get-Content -LiteralPath $p -Raw -Encoding UTF8} -ArgumentList ([IO.Path]::Combine($stage.Local,'install-result.json'))
            return (Assert-WtgRemoteResult ($json|ConvertFrom-Json) $Context.RunId $expected $identity.TargetSid)
        }
        Initialize-WtgRemoteNative
        if($Credential){
            $net=$Credential.GetNetworkCredential();$domain=$net.Domain;if(-not $domain){$domain=$target}
            if(-not [WtgRemote.Native]::LogonUser($net.UserName,$domain,$net.Password,9,3,[ref]$token)){throw 'REMOTE_CREDENTIAL_LOGON_FAILED'}
            if(-not [WtgRemote.Native]::ImpersonateLoggedOnUser($token)){throw 'REMOTE_CREDENTIAL_IMPERSONATION_FAILED'};$impersonation=$true;$net=$null
        }
        # Force connection establishment, then require SMB signing or encryption already active.
        $null=Get-Item -LiteralPath $stage.Share -ErrorAction Stop
        $client=$null;try{$client=Get-SmbClientConfiguration -ErrorAction Stop}catch{}
        $safe=Test-WtgSmbIntegrity $client
        if(-not $safe){$connections=@(Get-SmbConnection -ErrorAction Stop|Where-Object {$_.ServerName -eq $target -or $_.ServerName -eq $expected});$safe=Test-WtgSmbIntegrity $client $connections ($stage.Share.Substring($stage.Share.LastIndexOf('\')+1))}
        if(-not $safe){throw 'REMOTE_SMB_INTEGRITY_NOT_VERIFIED_USE_WINRM'}
        if(Test-Path -LiteralPath $stage.UNC){
            Initialize-WtgSecureRemoteStage $target $stage
            try{$actual=[WtgRemote.Native]::GetServerName($target);$sid=[WtgRemote.Native]::GetAccountSid($target,$Context.TargetUser)}catch{throw 'REMOTE_CURRENT_TARGET_IDENTITY_UNVERIFIED'}
            if($actual -ne $expected){throw 'REMOTE_HOSTNAME_MISMATCH'}
            return (Assert-WtgRetainedOutcome (Read-WtgRetainedRemoteRun $stage.UNC) $Context $remoteRun $expected $sid)
        }
        if($resume){throw 'REMOTE_PREVIOUS_RUN_NOT_COMPLETE_NO_RELAUNCH'}
        Initialize-WtgSecureRemoteStage $target $stage -Create
        if($package){Copy-WtgRemoteFiles $root (Join-Path $stage.UNC 'package') -PackageOnly}
        $helpers=Join-Path $stage.UNC 'helpers';[IO.Directory]::CreateDirectory($helpers)|Out-Null
        foreach($name in @('install-target.ps1','Install.psm1','Common.psm1','StationVideoHealth.psm1','Requirements.psm1','requirements.json')){$path=Get-WtgHelperPath $name;Copy-Item -LiteralPath $path -Destination $helpers}
        $request=New-WtgRemoteRequest $Context ([IO.Path]::Combine($stage.Local,'package')) $manifestHash $expected
        $request.Inspect=$true;Write-WtgJson -Path (Join-Path $stage.UNC 'inspect-request.json') -Value $request
        $identity=Assert-WtgRemoteResult (Invoke-WtgSmbJob $target $stage 'inspect' $Context.RunId 90) $Context.RunId $expected '' @('Inspected')
        if($identity.Status -ne 'Inspected'){throw 'REMOTE_INSPECTION_FAILED'}
        $request.Inspect=$false;$request.TargetSid=$identity.TargetSid;Set-WtgRemoteRequestDirectory $request $identity
        Write-WtgJson -Path (Join-Path $stage.UNC 'install-request.json') -Value $request
        return (Assert-WtgRemoteResult (Invoke-WtgSmbJob $target $stage 'install' $Context.RunId 1200) $Context.RunId $expected $identity.TargetSid)
    }finally{
        if($session){Remove-PSSession $session -ErrorAction SilentlyContinue}
        if($impersonation){$null=[WtgRemote.Native]::RevertToSelf()}
        if($token -ne [IntPtr]::Zero){$null=[WtgRemote.Native]::CloseHandle($token)}
    }
}
Export-ModuleMember -Function Install-WtgRemotePackage,Get-WtgRemoteStage,New-WtgRemoteRequest,Assert-WtgRemoteResult,Test-WtgSmbIntegrity

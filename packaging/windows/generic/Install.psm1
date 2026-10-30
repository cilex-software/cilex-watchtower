# Windows PowerShell 5.1. All destructive operations are scoped to a marked installation.
Set-StrictMode -Version 2

function Get-WtgOption($Context,[string]$Name,$Default=$null) {
    $p=$Context.PSObject.Properties[$Name]; if($p){return $p.Value}; return $Default
}
function Get-WtgHelperPath([string]$Name) {
    if($Name -notmatch '^[A-Za-z0-9_.-]+$'){throw 'INSTALL_HELPER_NAME_INVALID'}
    $path=Join-Path $PSScriptRoot $Name
    if($Name -eq 'StationVideoHealth.psm1' -and -not(Test-Path -LiteralPath $path)){$path=Join-Path $PSScriptRoot '..\deploy\StationVideoHealth.psm1'}
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'INSTALL_REQUIRED_HELPER_MISSING'}
    return [IO.Path]::GetFullPath($path)
}
function Get-WtgInstallText([string]$Language,[string]$English,[string]$Russian) {
    if($Language -eq 'ru'){return $Russian}; return $English
}
function Get-WtgInstallFailureText([string]$Code,[string]$Language='en') {
    $en='Installation did not complete. Check the saved result and correct the reported condition before trying again.';$ru='Установка не завершена. Проверьте сохранённый результат и устраните причину перед повторной попыткой.'
    switch -Regex ($Code) {
        'ELEVATION|ACCESS_DENIED|PERMISSION' {$en='Administrator approval is required. Run the installer with Windows administrator approval for the intended desktop user.';$ru='Нужно разрешение администратора Windows. Запустите установщик с этим разрешением для нужного пользователя.';break}
        'HASH|INTEGRITY|TRUSTED|PUBLISHER' {$en='The package could not be verified. Obtain the original package and its verified checksum, then retry.';$ru='Не удалось проверить пакет. Получите исходный пакет и его проверенную контрольную сумму, затем повторите попытку.';break}
        'DISK|SPACE' {$en='There is not enough free disk space. Free space or choose another installation folder.';$ru='Недостаточно свободного места на диске. Освободите место или выберите другую папку.';break}
        'RESTART_REQUIRED' {$en='A required component needs a Windows restart. Restart when convenient, then run the installer again.';$ru='Необходимому компоненту нужен перезапуск Windows. Перезапустите компьютер в удобное время и повторите установку.';break}
        'REQUIREMENTS|ACCEPTANCE' {$en='Some requirements need attention or explicit acceptance. Review the displayed findings before continuing.';$ru='Некоторые требования требуют внимания или подтверждения. Проверьте показанные замечания перед продолжением.';break}
        'PROFILE|IDENTITY|HOSTNAME|TARGET_HOST|TARGET_USER|ACCOUNT|SESSION' {$en='The target computer or desktop account could not be verified. Check the computer and account names and sign in to that account once.';$ru='Не удалось проверить компьютер или пользователя. Проверьте имена и выполните вход под нужной учётной записью.';break}
        'UNMANAGED|ADOPT|OWNERSHIP|OTHER_INSTALLATION' {$en='An existing installation needs a verified migration. Use its existing updater or specify the exact existing Warden task for adoption.';$ru='Существующая установка требует проверенного переноса. Используйте прежний скрипт обновления или укажите точное задание Warden для переноса.';break}
        'ROLLBACK' {$en='The update failed and recovery could not be confirmed. Keep the backup and result files; check the station before another update.';$ru='Обновление не удалось, восстановление не подтверждено. Сохраните резервную копию и результат; проверьте станцию перед новой попыткой.';break}
        'STARTUP|VIDEO|PROCESS' {$en='Watchtower did not pass the startup or video check. Check the saved result and the restored station before retrying.';$ru='Watchtower не прошёл проверку запуска или видео. Проверьте результат и восстановленную станцию перед повторной попыткой.';break}
        'REMOTE_.*(UNKNOWN|RECONCILE|PREVIOUS_RUN)' {$en='The remote result is not yet confirmed. Reconcile the recorded run before starting another installation.';$ru='Результат на удалённом компьютере ещё не подтверждён. Проверьте записанный запуск перед новой установкой.';break}
        'SCRIPT_POLICY' {$en='Windows has blocked script execution. Ask the administrator to approve this installer under the existing policy; no policy was changed.';$ru='Windows заблокировала запуск скрипта. Попросите администратора разрешить установщик в рамках действующих правил; правила не изменены.';break}
        'REMOTE_' {$en='Remote installation could not complete. Check the approved Windows remote access, target permissions and saved result; the offline installer can also be run locally.';$ru='Удалённая установка не завершена. Проверьте доступ Windows, права и сохранённый результат; установщик также можно запустить на нужном компьютере.';break}
        'PATH|DIRECTORY|REPARSE' {$en='The selected folder is not suitable. Choose a normal local application folder without links or reserved Windows paths.';$ru='Выбранная папка не подходит. Выберите обычную локальную папку приложения без ссылок и системных путей Windows.';break}
        'CANCELLED' {$en='Installation was cancelled.';$ru='Установка отменена.';break}
    }
    return Get-WtgInstallText $Language $en $ru
}
function Assert-WtgLocalPath([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f"<>|?*]'){throw 'INSTALL_INVALID_LOCAL_PATH'}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if($full.Length -le 3){throw 'INSTALL_ROOT_FORBIDDEN'}
    $cursor=$full
    while($cursor -and $cursor.Length -gt 3){
        if(Test-Path -LiteralPath $cursor){
            $i=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if(($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'INSTALL_REPARSE_POINT_FORBIDDEN'}
        }
        $cursor=Split-Path -Parent $cursor
    }
    return $full
}
function Resolve-WtgPayloadPath([string]$Root,[string]$Relative) {
    if([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '(^[\\/]|[:\x00-\x1f"<>|?*]|(^|[\\/])\.\.?([\\/]|$))'){throw 'PACKAGE_UNSAFE_PATH'}
    foreach($part in ($Relative -split '[\\/]')){
        if($part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or -not $part){throw 'PACKAGE_UNSAFE_PATH'}
    }
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if(-not $full.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'PACKAGE_PATH_ESCAPE'}
    return (Assert-WtgLocalPath $full)
}
function Test-WtgPackage([string]$PackagePath,[string]$ManifestSha256='') {
    $root=Assert-WtgLocalPath $PackagePath
    $manifestPath=Join-Path $root 'manifest.json'
    if($ManifestSha256 -and (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $ManifestSha256){throw 'PACKAGE_MANIFEST_HASH_MISMATCH'}
    $m=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($m.schemaVersion -ne 1 -or $m.product -ne 'CilexWatchtower' -or $m.architecture -ne 'x64' -or $m.version -notmatch '^\d+\.\d+\.\d+' -or $m.wardenVersion -notmatch '^\d+\.\d+\.\d+' -or $m.sourceCommit -notmatch '^[a-fA-F0-9]{40}$'){throw 'PACKAGE_MANIFEST_INVALID'}
    $payload=Join-Path $root 'payload'; $seen=@{}; $total=0L
    foreach($f in @($m.files)){
        $path=Resolve-WtgPayloadPath $payload ([string]$f.path)
        $key=([string]$f.path).Replace('/','\').ToLowerInvariant()
        if($seen.ContainsKey($key) -or $f.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [long]$f.size -lt 0){throw 'PACKAGE_FILE_ENTRY_INVALID'}
        $seen[$key]=$true
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        if($item.PSIsContainer -or $item.Length -ne [long]$f.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $f.sha256){throw 'PACKAGE_FILE_HASH_MISMATCH'}
        $total += $item.Length
    }
    if(-not $seen.ContainsKey('watchtower.exe') -or -not $seen.ContainsKey('warden\warden.exe') -or -not $seen.ContainsKey('warden\warden-launcher.exe')){throw 'PACKAGE_REQUIRED_EXECUTABLE_MISSING'}
    foreach($file in @(Get-ChildItem -LiteralPath $payload -Recurse -Force)){
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'PACKAGE_REPARSE_POINT_FORBIDDEN'}
        if(-not $file.PSIsContainer){$rel=$file.FullName.Substring($payload.Length+1).ToLowerInvariant();if(-not $seen.ContainsKey($rel)){throw 'PACKAGE_UNDECLARED_FILE'}}
    }
    return [pscustomobject]@{Root=$root;Payload=$payload;Manifest=$m;Bytes=$total;ManifestSha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash}
}
function Expand-WtgPackage([string]$Path,[string]$Destination,[string]$Sha256) {
    if($Sha256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Sha256){throw 'PACKAGE_TRUSTED_SHA256_REQUIRED'}
    if(Test-Path -LiteralPath $Destination){throw 'PACKAGE_EXTRACTION_DESTINATION_EXISTS'}
    $null=Assert-WtgLocalPath $Destination
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try{
        $entries=@{}; $bytes=0L
        foreach($entry in $archive.Entries){
            $name=$entry.FullName.TrimEnd('/'); if(-not $name){continue}
            $null=Resolve-WtgPayloadPath $Destination $name
            if($entries.ContainsKey($name.ToLowerInvariant())){throw 'PACKAGE_DUPLICATE_ARCHIVE_ENTRY'}
            $entries[$name.ToLowerInvariant()]=$true
            if(($entry.ExternalAttributes -band 0x400) -ne 0){throw 'PACKAGE_ARCHIVE_REPARSE_POINT'}
            $bytes += $entry.Length
            if($bytes -gt 100GB){throw 'PACKAGE_ARCHIVE_TOO_LARGE'}
        }
        $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Destination))
        if($drive.AvailableFreeSpace -lt ($bytes+256MB)){throw 'PACKAGE_EXTRACTION_DISK_FULL'}
        [IO.Directory]::CreateDirectory($Destination)|Out-Null
        foreach($entry in $archive.Entries){
            if($entry.FullName.EndsWith('/')){continue}
            $dest=Resolve-WtgPayloadPath $Destination $entry.FullName
            [IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$false)
        }
    }finally{$archive.Dispose()}
    return $Destination
}
function Expand-WtgInstallInput($Context,[string]$PackagePath,[string]$FolderName='package') {
    if(Test-Path -LiteralPath $PackagePath -PathType Container){return $PackagePath}
    $hash=[string](Get-WtgOption $Context 'PackageSha256' '')
    $dest=Join-Path $Context.RunDir $FolderName
    if([IO.Path]::GetExtension($PackagePath) -eq '.zip'){return Expand-WtgPackage $PackagePath $dest $hash}
    if([IO.Path]::GetExtension($PackagePath) -ne '.exe'){throw 'PACKAGE_FORMAT_UNSUPPORTED'}
    if($hash -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash -ne $hash){throw 'PACKAGE_TRUSTED_SHA256_REQUIRED'}
    if(Test-Path -LiteralPath $dest){throw 'PACKAGE_EXTRACTION_DESTINATION_EXISTS'}
    $null=Assert-WtgLocalPath $dest
    $p=Start-Process -FilePath $PackagePath -ArgumentList @('/S',('/EXTRACTONLY="'+$dest+'"')) -WindowStyle Hidden -PassThru
    try{$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $p.WaitForExit(1000) -and $clock.Elapsed.TotalSeconds -lt 300){};if(-not $p.HasExited -or $p.ExitCode -ne 0){throw 'PACKAGE_INSTALLER_EXTRACTION_FAILED'}}finally{$p.Dispose()}
    if(-not(Test-Path -LiteralPath $dest -PathType Container)){throw 'PACKAGE_INSTALLER_EXTRACTION_MISSING'}
    return $dest
}
function Resolve-WtgTargetIdentity([string]$TargetUser='',[string]$ExpectedSid='') {
    $current=[Security.Principal.WindowsIdentity]::GetCurrent()
    if(-not $TargetUser){$TargetUser=$current.Name}
    $sid=(New-Object Security.Principal.NTAccount $TargetUser).Translate([Security.Principal.SecurityIdentifier]).Value
    if($sid -in @('S-1-5-18','S-1-5-19','S-1-5-20') -or ($ExpectedSid -and $sid -ne $ExpectedSid)){throw 'TARGET_DESKTOP_IDENTITY_MISMATCH'}
    $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop
    if(-not $profile -or $profile.Special -or -not (Test-Path -LiteralPath $profile.LocalPath -PathType Container)){throw 'TARGET_PROFILE_MISSING_SIGN_IN_ONCE'}
    $profilePath=Assert-WtgLocalPath ([string]$profile.LocalPath)
    $local=Join-Path $profilePath 'AppData\Local';$roaming=Join-Path $profilePath 'AppData\Roaming'
    # Read only these two known-folder entries. Never inspect the entire user hive.
    $hive=[Microsoft.Win32.Registry]::Users.OpenSubKey("$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
    if($hive){try{
        $l=[string]$hive.GetValue('Local AppData','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $r=[string]$hive.GetValue('AppData','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if($l){$local=$l.Replace('%USERPROFILE%',$profilePath)};if($r){$roaming=$r.Replace('%USERPROFILE%',$profilePath)}
    }finally{$hive.Dispose()}}
    elseif($sid -ne $current.User.Value){throw 'TARGET_PROFILE_HIVE_NOT_LOADED_SIGN_IN_ONCE'}
    $null=Assert-WtgLocalPath $local; $null=Assert-WtgLocalPath $roaming
    return [pscustomobject]@{Name=$TargetUser;Sid=$sid;Profile=$profilePath;LocalAppData=$local;AppData=$roaming;IsCurrent=($sid -eq $current.User.Value)}
}
function Get-WtgInstallPlan($Context,$Identity) {
    $scope=[string](Get-WtgOption $Context 'InstallScope' 'User')
    $dir=[string](Get-WtgOption $Context 'InstallDir' '')
    if(-not $dir){if($scope -eq 'Machine'){$dir=Join-Path $env:ProgramFiles 'Cilex Watchtower'}else{$dir=Join-Path $Identity.LocalAppData 'Programs\Cilex Watchtower'}}
    $dir=Assert-WtgLocalPath $dir
    if($dir.Contains(',')){throw 'INSTALL_PATH_COMMA_UNSUPPORTED_BY_WARDEN'}
    $forbidden=@($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$Identity.Profile,$Identity.LocalAppData,$Identity.AppData,$env:ProgramData)
    foreach($p in $forbidden){if($p -and ($dir -eq $p.TrimEnd('\') -or $dir.StartsWith($env:SystemRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'INSTALL_PROTECTED_DIRECTORY'}}
    if($scope -notin @('User','Machine')){throw 'INSTALL_SCOPE_INVALID'}
    $digest=[Security.Cryptography.SHA256]::Create();try{$id=([BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($dir.ToLowerInvariant()+'|'+$Identity.Sid)))).Replace('-','').Substring(0,16)}finally{$digest.Dispose()}
    $config=Assert-WtgLocalPath (Join-Path $Identity.Profile '.config\watchtower-warden\warden.conf')
    $state=Assert-WtgLocalPath (Join-Path $Identity.LocalAppData "CilexWatchtower\Deployment\$id")
    return [pscustomobject]@{Directory=$dir;Scope=$scope;Identity=$Identity;Id=$id;TaskName="CilexWatchtower-$id";ConfigPath=$config;StatePath=$state}
}
function Set-WtgPrivateAcl([string]$Path,[string]$Sid,[switch]$Machine) {
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@($Sid,$(if($Machine){'ReadAndExecute'}else{'FullControl'})))){
        $identity=New-Object Security.Principal.SecurityIdentifier $entry[0]
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,[Security.AccessControl.FileSystemRights]$entry[1],[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Set-WtgPrivateFileAcl([string]$Path,[string]$Sid) {
    $acl=New-Object Security.AccessControl.FileSecurity;$acl.SetAccessRuleProtection($true,$false)
    foreach($id in @('S-1-5-18','S-1-5-32-544',$Sid)){
        $principal=New-Object Security.Principal.SecurityIdentifier $id
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($principal,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Assert-WtgMachineParent([string]$Directory) {
    $parent=Split-Path -Parent $Directory
    while($parent -and -not(Test-Path -LiteralPath $parent -PathType Container)){$parent=Split-Path -Parent $parent}
    if(-not $parent){throw 'INSTALL_MACHINE_PARENT_UNVERIFIED'}
    $acl=Get-Acl -LiteralPath $parent -ErrorAction Stop
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'INSTALL_MACHINE_PARENT_NOT_ADMIN_OWNED'}
    $danger=[Security.AccessControl.FileSystemRights]'WriteData,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly){continue}
        if($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $danger) -and $rule.IdentityReference.Value -notin $trusted){throw 'INSTALL_MACHINE_PARENT_WRITABLE_BY_OTHER_USERS'}
    }
}
function Assert-WtgOwnedInstallation($Plan) {
    if(-not(Test-Path -LiteralPath $Plan.Directory)){return $null}
    $marker=Join-Path $Plan.Directory '.cilex-install.json'
    if(-not(Test-Path -LiteralPath $marker)){
        if(@(Get-ChildItem -LiteralPath $Plan.Directory -Force).Count -gt 0){throw 'INSTALL_DIRECTORY_UNMANAGED_USE_EXISTING_UPDATER'}
        return $null
    }
    $m=Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json
    if($m.product -ne 'CilexWatchtower' -or $m.installId -ne $Plan.Id -or $m.targetSid -ne $Plan.Identity.Sid -or $m.installDir -ne $Plan.Directory){throw 'INSTALL_OWNERSHIP_MISMATCH'}
    return $m
}
function Assert-WtgNoOtherStartupAction([object[]]$Tasks,[string]$LegacyTaskName,[string]$Directory) {
    foreach($task in $Tasks){
        if($task.TaskName -eq $LegacyTaskName){continue}
        foreach($action in @($task.Actions)){
            # Windows also has COM-handler actions, which have no Execute or
            # Arguments properties. Missing fields are not executable commands.
            $execute=[string](Get-WtgOption $action 'Execute' '')
            $arguments=[string](Get-WtgOption $action 'Arguments' '')
            if(($execute -and $execute.IndexOf($Directory,[StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($arguments -and $arguments.IndexOf($Directory,[StringComparison]::OrdinalIgnoreCase) -ge 0)){throw 'ADOPT_OTHER_STARTUP_ACTION_PRESENT'}
        }
    }
}
function Get-WtgLegacyAdoption($Context,$Plan) {
    if(-not(Get-WtgOption $Context 'AdoptExisting' $false)){return $null}
    if(Test-Path -LiteralPath (Join-Path $Plan.Directory '.cilex-install.json')){return $null}
    foreach($file in @('watchtower.exe','warden\warden.exe')){if(-not(Test-Path -LiteralPath (Join-Path $Plan.Directory $file) -PathType Leaf)){throw 'ADOPT_EXISTING_FILES_MISSING'}}
    $name=[string](Get-WtgOption $Context 'LegacyTaskName' '')
    if(-not $name){throw 'ADOPT_LEGACY_TASK_REQUIRED'}
    $temporary=[pscustomobject]@{TaskName=$name;Directory=$Plan.Directory;Identity=$Plan.Identity;AllowLegacyWarden=$true}
    $xml=Get-WtgTaskXml $temporary
    if(-not $xml){throw 'ADOPT_LEGACY_TASK_MISSING'}
    $doc=[xml]$xml;$ns=New-Object Xml.XmlNamespaceManager $doc.NameTable;$ns.AddNamespace('t',$doc.DocumentElement.NamespaceURI)
    if($doc.SelectSingleNode('//t:Principal/t:LogonType',$ns).InnerText -ne 'InteractiveToken' -or $doc.SelectSingleNode('//t:Exec/t:Arguments',$ns).InnerText -ne 'run'){throw 'ADOPT_LEGACY_TASK_UNSUPPORTED'}
    foreach($i in @(Get-ChildItem -LiteralPath $Plan.Directory -Recurse -Force)){if(($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'ADOPT_REPARSE_POINT_FORBIDDEN'}}
    # No other action may relaunch this same installation after its legacy task is disabled.
    Assert-WtgNoOtherStartupAction @(Get-ScheduledTask) $name $Plan.Directory
    return [pscustomobject]@{TaskName=$name;Xml=$xml;Enabled=(Get-WtgTaskEnabled $name)}
}
function Get-WtgTaskEnabled([string]$TaskName) {
    $tasks=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -eq $TaskName})
    if($tasks.Count -ne 1 -or -not $tasks[0].Settings.PSObject.Properties['Enabled'] -or $null -eq $tasks[0].Settings.Enabled){throw 'INSTALL_TASK_ENABLED_STATE_UNKNOWN'}
    return [bool]$tasks[0].Settings.Enabled
}
function Set-WtgRestoredTaskEnabled([string]$TaskName,[bool]$Enabled) {
    # XML can omit this default. Restore the captured API value explicitly.
    if($Enabled){Enable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop|Out-Null}
    else{Disable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop|Out-Null}
    if((Get-WtgTaskEnabled $TaskName) -ne $Enabled){throw 'INSTALL_TASK_STATE_RESTORATION_UNVERIFIED'}
}
function Stop-WtgTaskExecution($Plan,[int]$TimeoutSeconds=15) {
    if(-not(Get-WtgTaskXml $Plan)){throw 'INSTALL_TASK_DISAPPEARED'}
    Disable-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -ErrorAction Stop|Out-Null
    # Revalidate immediately before ending the task instance. Disabling its
    # triggers alone does not stop an already-running scheduler instance.
    if(-not(Get-WtgTaskXml $Plan)){throw 'INSTALL_TASK_DISAPPEARED'}
    Stop-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -ErrorAction Stop
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{
        $tasks=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -eq $Plan.TaskName})
        if($tasks.Count -ne 1){throw 'INSTALL_TASK_DISAPPEARED'}
        if([string]$tasks[0].State -ne 'Running'){return}
        if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'INSTALL_TASK_STOP_TIMEOUT'}
        Start-Sleep -Milliseconds 200
    }while($true)
}
function Get-WtgNativeProcessHandle([int]$ProcessId) {
    try{return Get-Process -Id $ProcessId -ErrorAction Stop}
    catch{
        if($_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*'){return $null}
        throw 'INSTALL_PROCESS_HANDLE_UNVERIFIED'
    }
}
function Assert-WtgNativeProcessIdentity($Handle,$Row) {
    try{
        $null=$Handle.Handle
        $id=$Handle.Id;$created=$Handle.StartTime.ToUniversalTime();$path=$Handle.MainModule.FileName;$session=$Handle.SessionId
    }catch{throw 'INSTALL_PROCESS_HANDLE_UNVERIFIED'}
    if($id -ne $Row.ProcessId -or [Math]::Abs(($created-$Row.CreatedUTC).TotalMilliseconds) -gt 1 -or $path -ne $Row.Path -or $session -ne $Row.Session){throw 'INSTALL_PROCESS_CHANGED'}
}
function Test-WtgCapturedProcessExited($Captured) {
    if(-not $Captured.Handle.HasExited){return $false}
    $observed=Get-WtgNativeProcessHandle $Captured.Row.ProcessId
    if(-not $observed){return $true}
    try{
        $null=$observed.Handle
        if($observed.Id -ne $Captured.Row.ProcessId -or [Math]::Abs(($observed.StartTime.ToUniversalTime()-$Captured.Row.CreatedUTC).TotalMilliseconds) -gt 1 -or -not $observed.HasExited){throw 'INSTALL_PROCESS_CHANGED'}
        return $true
    }finally{$observed.Dispose()}
}
function Wait-WtgCapturedProcessExit($Captured,[int]$TimeoutMilliseconds=0) {
    if(-not $Captured.Handle.HasExited -and -not $Captured.Handle.WaitForExit([Math]::Max(0,$TimeoutMilliseconds))){return $false}
    return Test-WtgCapturedProcessExited $Captured
}
function Get-WtgOwnedProcesses($Plan,[object[]]$CapturedProcesses=@(),[int]$CapturedExitWaitMilliseconds=0,[object[]]$AdmissionRows=@()) {
    $paths=@((Join-Path $Plan.Directory 'watchtower.exe'),(Join-Path $Plan.Directory 'warden\warden.exe'),(Join-Path $Plan.Directory 'warden\warden-launcher.exe'))
    $result=@()
    $exitWaitClock=[Diagnostics.Stopwatch]::StartNew()
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='watchtower.exe' OR Name='warden.exe' OR Name='warden-launcher.exe' OR Name='python.exe' OR Name='pythonw.exe'" -ErrorAction Stop)){
        $captured=@($CapturedProcesses|Where-Object{$_.Row.ProcessId -eq [int]$p.ProcessId})
        if($captured.Count){
            if($captured.Count -ne 1 -or [Math]::Abs(($p.CreationDate.ToUniversalTime()-$captured[0].Row.CreatedUTC).TotalMilliseconds) -gt 1 -or $p.ExecutablePath -ne $captured[0].Row.Path -or [int]$p.SessionId -ne $captured[0].Row.Session){throw 'INSTALL_PROCESS_CHANGED'}
            # A provider can retain an exited row. The held native handle proves
            # that exact generation dead without calling its now-invalid owner method.
            if(Test-WtgCapturedProcessExited $captured[0]){continue}
        }else{
            $admitted=@($AdmissionRows|Where-Object{$_.ProcessId -eq [int]$p.ProcessId})
            if($admitted.Count){
                if($admitted.Count -ne 1 -or [Math]::Abs(($p.CreationDate.ToUniversalTime()-$admitted[0].CreatedUTC).TotalMilliseconds) -gt 1 -or $p.ExecutablePath -ne $admitted[0].Path -or [int]$p.SessionId -ne $admitted[0].Session){throw 'INSTALL_PROCESS_CHANGED'}
                $observed=Get-WtgNativeProcessHandle ([int]$p.ProcessId)
                if(-not $observed){continue}
                try{
                    $null=$observed.Handle
                    if($observed.Id -ne $admitted[0].ProcessId -or [Math]::Abs(($observed.StartTime.ToUniversalTime()-$admitted[0].CreatedUTC).TotalMilliseconds) -gt 1){throw 'INSTALL_PROCESS_CHANGED'}
                    if($observed.HasExited){continue}
                    Assert-WtgNativeProcessIdentity $observed $admitted[0]
                }finally{$observed.Dispose()}
            }
        }
        if($p.ExecutablePath -and $p.ExecutablePath -in $paths){
            try{$owner=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop}
            catch{
                $remaining=[int][Math]::Max(0,($CapturedExitWaitMilliseconds-$exitWaitClock.ElapsedMilliseconds))
                if($captured.Count -eq 1 -and (Wait-WtgCapturedProcessExit $captured[0] $remaining)){continue}
                throw
            }
            if($owner.ReturnValue -ne 0 -or -not $owner.Sid){
                # The process can finish between the census and GetOwnerSid.
                $remaining=[int][Math]::Max(0,($CapturedExitWaitMilliseconds-$exitWaitClock.ElapsedMilliseconds))
                if($captured.Count -eq 1 -and (Wait-WtgCapturedProcessExit $captured[0] $remaining)){continue}
                throw 'INSTALL_PROCESS_OWNER_OR_SESSION_MISMATCH'
            }
            if($owner.Sid -ne $Plan.Identity.Sid -or $p.SessionId -eq 0){throw 'INSTALL_PROCESS_OWNER_OR_SESSION_MISMATCH'}
            $result += [pscustomobject]@{ProcessId=[int]$p.ProcessId;ParentId=[int]$p.ParentProcessId;CreatedUTC=$p.CreationDate.ToUniversalTime();Path=$p.ExecutablePath;Session=[int]$p.SessionId;Sid=$owner.Sid}
        }
        elseif($p.CommandLine -and $p.CommandLine.IndexOf($Plan.Directory,[StringComparison]::OrdinalIgnoreCase) -ge 0){throw 'INSTALL_UNMANAGED_SUPERVISOR_PRESENT'}
    }
    return $result
}
function Assert-WtgAdmissionCensus([object[]]$AdmissionRows,[object[]]$Rows,[object[]]$CapturedProcesses=@(),[int]$ExitWaitMilliseconds=0) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach($admitted in $AdmissionRows){
        $observed=Get-WtgNativeProcessHandle $admitted.ProcessId
        if(-not $observed){continue}
        try{
            $null=$observed.Handle
            if($observed.Id -ne $admitted.ProcessId -or [Math]::Abs(($observed.StartTime.ToUniversalTime()-$admitted.CreatedUTC).TotalMilliseconds) -gt 1){throw 'INSTALL_PROCESS_CHANGED'}
            if($observed.HasExited){continue}
            try{Assert-WtgNativeProcessIdentity $observed $admitted}
            catch{
                $captured=@($CapturedProcesses|Where-Object{$_.Row.ProcessId -eq $admitted.ProcessId})
                $remaining=[int][Math]::Max(0,($ExitWaitMilliseconds-$clock.ElapsedMilliseconds))
                if($_.Exception.Message -eq 'INSTALL_PROCESS_HANDLE_UNVERIFIED' -and $captured.Count -eq 1 -and (Wait-WtgCapturedProcessExit $captured[0] $remaining)){continue}
                throw
            }
            if(@($Rows|Where-Object{$_.ProcessId -eq $admitted.ProcessId}).Count -ne 1){throw 'INSTALL_PROCESS_HANDLE_UNVERIFIED'}
        }finally{$observed.Dispose()}
    }
}
function Get-WtgLiveDrainRows($Plan,[object[]]$CapturedProcesses,[int]$ExitWaitMilliseconds=0,[object[]]$AdmissionRows=@()) {
    $live=@()
    $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach($item in $CapturedProcesses){if($item.Handle.HasExited){$null=Test-WtgCapturedProcessExited $item}}
    $rows=@(Get-WtgOwnedProcesses $Plan $CapturedProcesses $ExitWaitMilliseconds $AdmissionRows)
    $remaining=[int][Math]::Max(0,($ExitWaitMilliseconds-$clock.ElapsedMilliseconds))
    Assert-WtgAdmissionCensus $AdmissionRows $rows $CapturedProcesses $remaining
    foreach($row in $rows){
        $captured=@($CapturedProcesses|Where-Object{$_.Row.ProcessId -eq $row.ProcessId})
        if($captured.Count){
            if($captured.Count -ne 1 -or $row.CreatedUTC -ne $captured[0].Row.CreatedUTC -or $row.Path -ne $captured[0].Row.Path -or $row.Session -ne $captured[0].Row.Session -or $row.Sid -ne $captured[0].Row.Sid){throw 'INSTALL_PROCESS_CHANGED'}
            if(-not $captured[0].Handle.HasExited){$live+=,$row}
            continue
        }
        $handle=Get-WtgNativeProcessHandle $row.ProcessId
        if(-not $handle){continue}
        try{
            $null=$handle.Handle
            if($handle.HasExited){continue}
            Assert-WtgNativeProcessIdentity $handle $row
            # No post-capture identity is ever adopted into the termination set.
            throw 'INSTALL_PROCESS_RESPAWNED'
        }finally{$handle.Dispose()}
    }
    return $live
}
function Stop-WtgOwnedProcesses($Plan,[scriptblock]$BeforeStop={},[ValidateRange(0,60000)][int]$TimeoutMilliseconds=15000,$Admission=$null) {
    $captured=New-Object Collections.Generic.List[object]
    try{
        if(-not $Admission){$Admission=[pscustomobject]@{Initialized=$false;Rows=@()}}
        $reuseAdmission=[bool]$Admission.Initialized
        # A failed first census/capture must never make recovery admit a new cohort.
        if(-not $reuseAdmission){$Admission.Initialized=$true;$Admission.Rows=@()}
        $rows=@(Get-WtgOwnedProcesses $Plan @() 0 @($Admission.Rows))
        if($reuseAdmission){Assert-WtgAdmissionCensus @($Admission.Rows) $rows}
        if(@($rows|Select-Object -ExpandProperty Session -Unique).Count -gt 1){throw 'INSTALL_PROCESS_OWNER_OR_SESSION_MISMATCH'}
        $currentSession=[Diagnostics.Process]::GetCurrentProcess().SessionId
        if($Plan.Identity.PSObject.Properties['IsCurrent'] -and $Plan.Identity.IsCurrent -and $currentSession -gt 0 -and @($rows|Where-Object{$_.Session -ne $currentSession}).Count){throw 'INSTALL_PROCESS_OWNER_OR_SESSION_MISMATCH'}
        foreach($row in $rows){
            $handle=Get-WtgNativeProcessHandle $row.ProcessId
            if(-not $handle){continue}
            try{
                if($reuseAdmission){
                    $admitted=@($Admission.Rows|Where-Object{$_.ProcessId -eq $row.ProcessId})
                    if($admitted.Count -eq 0){
                        $null=$handle.Handle
                        if($handle.HasExited){continue}
                        Assert-WtgNativeProcessIdentity $handle $row
                        throw 'INSTALL_PROCESS_RESPAWNED'
                    }
                    if($admitted.Count -ne 1 -or $row.CreatedUTC -ne $admitted[0].CreatedUTC -or $row.Path -ne $admitted[0].Path -or $row.Session -ne $admitted[0].Session -or $row.Sid -ne $admitted[0].Sid){throw 'INSTALL_PROCESS_CHANGED'}
                }
                Assert-WtgNativeProcessIdentity $handle $row
                $captured.Add([pscustomobject]@{Row=$row;Handle=$handle})
                if(-not $reuseAdmission){$Admission.Rows=@($Admission.Rows)+@([pscustomobject]@{ProcessId=$row.ProcessId;ParentId=$row.ParentId;CreatedUTC=$row.CreatedUTC;Path=$row.Path;Session=$row.Session;Sid=$row.Sid})}
                $handle=$null
            }finally{if($handle){$handle.Dispose()}}
        }
        # Retain the admitted native identities before the scheduler can tear
        # down the launcher, its onefile bootloader and its supervisor child.
        & $BeforeStop
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $null=Get-WtgLiveDrainRows $Plan ($captured.ToArray()) $TimeoutMilliseconds @($Admission.Rows)
        foreach($item in ($captured|Sort-Object @{Expression={if($_.Row.Path.EndsWith('\warden-launcher.exe',[StringComparison]::OrdinalIgnoreCase)){0}elseif($_.Row.Path.EndsWith('\warden.exe',[StringComparison]::OrdinalIgnoreCase)){1}else{2}}})){
            if($item.Handle.HasExited){continue}
            try{Assert-WtgNativeProcessIdentity $item.Handle $item.Row}
            catch{
                if($_.Exception.Message -ne 'INSTALL_PROCESS_HANDLE_UNVERIFIED'){throw}
                $remaining=[int][Math]::Max(0,($TimeoutMilliseconds-$clock.ElapsedMilliseconds))
                if(Wait-WtgCapturedProcessExit $item $remaining){continue}
                throw
            }
            try{$item.Handle.Kill()}catch{if(-not $item.Handle.HasExited){throw 'INSTALL_PROCESS_STOP_FAILED'}}
            $remaining=[int][Math]::Max(0,($TimeoutMilliseconds-$clock.ElapsedMilliseconds))
            if(-not $item.Handle.WaitForExit($remaining)){throw 'INSTALL_PROCESS_STOP_TIMEOUT'}
        }
        $quiet=0
        do{
            $remaining=[int][Math]::Max(0,($TimeoutMilliseconds-$clock.ElapsedMilliseconds))
            $live=@(Get-WtgLiveDrainRows $Plan ($captured.ToArray()) $remaining @($Admission.Rows))
            if($live.Count -eq 0 -and @($captured|Where-Object{-not $_.Handle.HasExited}).Count -eq 0){$quiet++}else{$quiet=0}
            if($quiet -ge 2){return}
            if($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds){throw 'INSTALL_PROCESS_STOP_TIMEOUT'}
            Start-Sleep -Milliseconds ([int][Math]::Min(100,[Math]::Max(1,($TimeoutMilliseconds-$clock.ElapsedMilliseconds))))
        }while($true)
    }finally{foreach($item in $captured){$item.Handle.Dispose()}}
}
function Get-WtgTaskXml($Plan) {
    $tasks=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -eq $Plan.TaskName})
    if($tasks.Count -eq 0){return $null}
    if($tasks.Count -ne 1 -or $tasks[0].TaskName -cne $Plan.TaskName -or $tasks[0].TaskPath -ne '\'){throw 'INSTALL_TASK_NAME_AMBIGUOUS'}
    $xml=Export-ScheduledTask -TaskName $Plan.TaskName -ErrorAction Stop
    $doc=[xml]$xml; $ns=New-Object Xml.XmlNamespaceManager $doc.NameTable;$ns.AddNamespace('t',$doc.DocumentElement.NamespaceURI)
    $userNode=$doc.SelectSingleNode('//t:Principal/t:UserId',$ns)
    $commandNode=$doc.SelectSingleNode('//t:Actions/t:Exec/t:Command',$ns)
    $logonNode=$doc.SelectSingleNode('//t:Principal/t:LogonType',$ns)
    if(-not $userNode -or -not $commandNode -or -not $logonNode){throw 'INSTALL_TASK_OWNERSHIP_MISMATCH'}
    $user=$userNode.InnerText
    if($user -notmatch '^S-1-'){$user=(New-Object Security.Principal.NTAccount $user).Translate([Security.Principal.SecurityIdentifier]).Value}
    $exe=$commandNode.InnerText
    $actions=@($doc.SelectNodes('//t:Actions/*',$ns));$arguments=$doc.SelectSingleNode('//t:Actions/t:Exec/t:Arguments',$ns)
    $runLevelNode=$doc.SelectSingleNode('//t:Principal/t:RunLevel',$ns)
    $runLevel=if($runLevelNode){$runLevelNode.InnerText}else{''}
    # Windows can omit default-valued XML elements. In that case require the
    # live task API to confirm Limited; do not infer privileges from omission.
    if(-not $runLevel -and $tasks[0].PSObject.Properties['Principal']){
        $principal=$tasks[0].Principal
        if($principal -and $principal.PSObject.Properties['RunLevel'] -and [string]$principal.RunLevel -eq 'Limited'){$runLevel='LeastPrivilege'}
    }
    $expectedExecutable=if(Get-WtgOption $Plan 'AllowLegacyWarden' $false){'warden\warden.exe'}else{'warden\warden-launcher.exe'}
    if($user -ne $Plan.Identity.Sid -or $exe -ne (Join-Path $Plan.Directory $expectedExecutable) -or $actions.Count -ne 1 -or -not $arguments -or $arguments.InnerText.Trim() -ne 'run' -or $logonNode.InnerText -ne 'InteractiveToken' -or $runLevel -ne 'LeastPrivilege'){throw 'INSTALL_TASK_OWNERSHIP_MISMATCH'}
    return $xml
}
function Register-WtgTask($Plan) {
    $action=New-ScheduledTaskAction -Execute (Join-Path $Plan.Directory 'warden\warden-launcher.exe') -Argument 'run' -WorkingDirectory $Plan.Directory
    $principal=New-ScheduledTaskPrincipal -UserId $Plan.Identity.Sid -LogonType Interactive -RunLevel Limited
    $logon=New-ScheduledTaskTrigger -AtLogOn -User $Plan.Identity.Sid
    $timer=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $Plan.TaskName -Action $action -Principal $principal -Trigger @($logon,$timer) -Settings $settings -Force -ErrorAction Stop|Out-Null
    $null=Get-WtgTaskXml $Plan
}
function Assert-WtgStartupTask($Plan) {
    # Get-WtgTaskXml first validates the exact task name, account and Warden action.
    $xml=Get-WtgTaskXml $Plan
    if(-not $xml){throw 'VERIFY_STARTUP_TASK_MISSING'}
    $doc=[xml]$xml;$ns=New-Object Xml.XmlNamespaceManager $doc.NameTable;$ns.AddNamespace('t',$doc.DocumentElement.NamespaceURI)
    $enabled=$doc.SelectSingleNode('/t:Task/t:Settings/t:Enabled',$ns)
    if(-not $enabled){
        $tasks=@(Get-ScheduledTask -TaskName $Plan.TaskName -ErrorAction SilentlyContinue)
        if($tasks.Count -ne 1 -or -not $tasks[0].PSObject.Properties['Settings'] -or -not $tasks[0].Settings -or -not $tasks[0].Settings.PSObject.Properties['Enabled'] -or $null -eq $tasks[0].Settings.Enabled){throw 'VERIFY_STARTUP_TASK_ENABLED_STATE_UNKNOWN'}
        if(-not [bool]$tasks[0].Settings.Enabled){throw 'VERIFY_STARTUP_TASK_DISABLED'}
        return $true
    }
    if($enabled.InnerText.Trim() -ne 'true'){throw 'VERIFY_STARTUP_TASK_DISABLED'}
    return $true
}
function Get-WtgInteractiveSessions($Plan) {
    $sessions=@()
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'")){
        $owner=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
        if($owner.ReturnValue -eq 0 -and $owner.Sid -eq $Plan.Identity.Sid -and $p.SessionId -gt 0){$sessions += [int]$p.SessionId}
    }
    return @($sessions|Select-Object -Unique)
}
function ConvertFrom-WtgWindowProof($Proof,$Expected) {
    foreach($name in @('Nonce','RunId','Status','OwnerSid','ProcessId','Session','Path','CreatedUTC','Visible')){if(-not $Proof -or -not $Proof.PSObject.Properties[$name]){throw 'INSTALL_WINDOW_PROBE_INVALID'}}
    if($Proof.Status -notin @('Observed','Unavailable') -or $Proof.Visible -isnot [bool]){throw 'INSTALL_WINDOW_PROBE_INVALID'}
    if(-not $Proof -or $Proof.Nonce -ne $Expected.Nonce -or $Proof.RunId -ne $Expected.RunId){throw 'INSTALL_WINDOW_PROBE_INVALID'}
    if($Proof.OwnerSid -and $Proof.OwnerSid -ne $Expected.OwnerSid){throw 'INSTALL_WINDOW_PROBE_IDENTITY_MISMATCH'}
    if($Proof.Status -ne 'Observed'){return [pscustomobject]@{State='Deferred';Reason='ProbeUnavailable'}}
    if($Proof.OwnerSid -ne $Expected.OwnerSid -or $Proof.ProcessId -ne $Expected.ProcessId -or $Proof.Session -ne $Expected.Session -or $Proof.Path -ne $Expected.Path){throw 'INSTALL_WINDOW_PROBE_IDENTITY_MISMATCH'}
    try{$difference=[Math]::Abs(([DateTime]::Parse($Proof.CreatedUTC).ToUniversalTime()-[DateTime]::Parse($Expected.CreatedUTC).ToUniversalTime()).TotalMilliseconds)}catch{throw 'INSTALL_WINDOW_PROBE_INVALID'}
    if($difference -gt 1){throw 'INSTALL_WINDOW_PROBE_PROCESS_CHANGED'}
    return [pscustomobject]@{State=$(if($Proof.Visible){'Verified'}else{'NotVisible'});Reason='UserDesktopObserved'}
}
function New-WtgWindowProbeCommand($Expected) {
    $data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Expected|ConvertTo-Json -Compress)))
    $body=@'
$ErrorActionPreference='Stop'
$request=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__DATA__')))
$result=[ordered]@{Nonce=$request.Nonce;RunId=$request.RunId;Status='Unavailable';OwnerSid='';ProcessId=$request.ProcessId;Session=-1;Path='';CreatedUTC='';Visible=$false}
try{
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$result.OwnerSid=$identity.User.Value}finally{$identity.Dispose()}
 $observer=Get-Process -Id $PID
 try{$observerSession=$observer.SessionId}finally{$observer.Dispose()}
 $process=Get-Process -Id $request.ProcessId -ErrorAction Stop
 try{
  $result.Session=$process.SessionId;$result.Path=$process.MainModule.FileName;$result.CreatedUTC=$process.StartTime.ToUniversalTime().ToString('o')
  if($observerSession -eq $request.Session){$result.Visible=($process.MainWindowHandle -ne [IntPtr]::Zero);$result.Status='Observed'}
 }finally{$process.Dispose()}
}catch{}
[IO.File]::WriteAllText($request.ResultPath,($result|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding $true))
'@
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body.Replace('__DATA__',$data)))
}
function Assert-WtgWindowProbeTask($Task,$Spec) {
    if(-not $Task -or $Task.TaskName -cne $Spec.Name -or $Task.TaskPath -ne '\' -or @($Task.Actions).Count -ne 1){throw 'INSTALL_WINDOW_PROBE_TASK_CHANGED'}
    $principal=$Task.Principal;$sid=[string]$principal.UserId
    if($sid -notmatch '^S-1-'){$sid=(New-Object Security.Principal.NTAccount $sid).Translate([Security.Principal.SecurityIdentifier]).Value}
    if($sid -ne $Spec.Sid -or [string]$principal.LogonType -ne 'Interactive' -or [string]$principal.RunLevel -ne 'Limited' -or [string]$Task.Actions[0].Execute -ne $Spec.Executable -or [string]$Task.Actions[0].Arguments -cne $Spec.Arguments){throw 'INSTALL_WINDOW_PROBE_TASK_CHANGED'}
}
function Get-WtgProbeWaitOutcome($Proof,$Expected,[bool]$TimedOut) {
    if($Proof){return (ConvertFrom-WtgWindowProof $Proof $Expected)}
    return [pscustomobject]@{State='Deferred';Reason=$(if($TimedOut){'ProbeTimedOut'}else{'ProbeUnavailable'})}
}
function Invoke-WtgUserWindowProbe($Context,$Plan,$Process) {
    $nonce=[Guid]::NewGuid().ToString('N');$directory=Join-Path $Plan.StatePath ('visibility-'+$nonce)
    try{$null=Assert-WtgLocalPath $directory;[IO.Directory]::CreateDirectory($directory)|Out-Null;Set-WtgPrivateAcl $directory $Plan.Identity.Sid}catch{return [pscustomobject]@{State='Deferred';Reason='ProbeOutputUnavailable';CleanupVerified=$true}}
    $expected=[pscustomobject]@{RunId=$Context.RunId;Nonce=$nonce;OwnerSid=$Plan.Identity.Sid;ProcessId=$Process.ProcessId;Session=$Process.Session;Path=$Process.Path;CreatedUTC=$Process.CreatedUTC.ToString('o');ResultPath=(Join-Path $directory 'result.json')}
    $executable=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+(New-WtgWindowProbeCommand $expected)
    $spec=[pscustomobject]@{Name=($Plan.TaskName+'-visibility-'+$nonce);Sid=$Plan.Identity.Sid;Executable=$executable;Arguments=$arguments}
    $attempted=$false;$clean=$true;$answer=[pscustomobject]@{State='Deferred';Reason='ProbeUnavailable'};$failure=$null
    try{
        if(@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -ceq $spec.Name}).Count){throw 'INSTALL_WINDOW_PROBE_TASK_CHANGED'}
        $action=New-ScheduledTaskAction -Execute $executable -Argument $arguments -WorkingDirectory $Plan.Directory
        $principal=New-ScheduledTaskPrincipal -UserId $spec.Sid -LogonType Interactive -RunLevel Limited
        $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $attempted=$true
        $null=Register-ScheduledTask -TaskName $spec.Name -Action $action -Principal $principal -Settings $settings -ErrorAction Stop
        Assert-WtgWindowProbeTask (Get-ScheduledTask -TaskName $spec.Name -ErrorAction Stop) $spec
        Start-ScheduledTask -TaskName $spec.Name -ErrorAction Stop
        $clock=[Diagnostics.Stopwatch]::StartNew();$proof=$null
        while($clock.Elapsed.TotalSeconds -lt 30){
            if(Test-Path -LiteralPath $expected.ResultPath){
                $item=Get-Item -LiteralPath $expected.ResultPath
                if($item.Length -gt 16KB -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'INSTALL_WINDOW_PROBE_INVALID'}
                try{$proof=Get-Content -LiteralPath $expected.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json;break}catch{}
            }
            Start-Sleep -Milliseconds 250
        }
        if(-not $proof -and (Test-Path -LiteralPath $expected.ResultPath)){throw 'INSTALL_WINDOW_PROBE_INVALID'}
        $answer=Get-WtgProbeWaitOutcome $proof $expected ($clock.Elapsed.TotalSeconds -ge 30)
    }catch{
        if($_.Exception.Message -match '^INSTALL_WINDOW_PROBE_(INVALID|IDENTITY_MISMATCH|PROCESS_CHANGED|TASK_CHANGED)$'){$failure=$_}
    }finally{
        if($attempted){try{
            $tasks=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -ceq $spec.Name})
            if($tasks.Count -gt 1){throw 'INSTALL_WINDOW_PROBE_CLEANUP_UNCONFIRMED'}
            if($tasks.Count -eq 1){
              Assert-WtgWindowProbeTask $tasks[0] $spec
              if($tasks[0].PSObject.Properties['State'] -and [string]$tasks[0].State -eq 'Running'){
                Stop-ScheduledTask -TaskName $spec.Name -ErrorAction Stop
                $stopClock=[Diagnostics.Stopwatch]::StartNew()
                do{
                    $remaining=@(Get-ScheduledTask -TaskName $spec.Name -ErrorAction Stop)
                    if($remaining.Count -ne 1){throw 'INSTALL_WINDOW_PROBE_CLEANUP_UNCONFIRMED'}
                    Assert-WtgWindowProbeTask $remaining[0] $spec
                    if([string]$remaining[0].State -ne 'Running'){break}
                    Start-Sleep -Milliseconds 250
                }while($stopClock.Elapsed.TotalSeconds -lt 5)
                if([string]$remaining[0].State -eq 'Running'){throw 'INSTALL_WINDOW_PROBE_CLEANUP_UNCONFIRMED'}
              }
              Unregister-ScheduledTask -TaskName $spec.Name -Confirm:$false -ErrorAction Stop
              if(@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -ceq $spec.Name}).Count){throw 'INSTALL_WINDOW_PROBE_CLEANUP_UNCONFIRMED'}
            }
        }catch{$clean=$false}}
    }
    $answer|Add-Member -NotePropertyName CleanupVerified -NotePropertyValue $clean
    if(-not $clean){$answer|Add-Member -NotePropertyName ObservedState -NotePropertyValue $answer.State;$answer.State='Deferred';$answer.Reason='ProbeCleanupUnconfirmed';$answer|Add-Member -NotePropertyName RetainedTask -NotePropertyValue $spec.Name}
    $statusPath=Join-Path $directory 'probe-status.json'
    try{Write-WtgInstallJson $statusPath @{TaskName=$spec.Name;Result=$answer;ErrorCode=$(if($failure){$failure.Exception.Message}else{$null})}}catch{}
    if($failure){$failure.Exception.Data['ProbeStatusPath']=$statusPath;if(-not $clean){$failure.Exception.Data['RetainedTask']=$spec.Name;$failure.Exception.Data['CleanupVerified']=$false};throw $failure}
    return $answer
}
function Get-WtgWindowVisibility($Context,$Plan,$Process,[switch]$ReadOnly) {
    $observer=Get-Process -Id $PID
    try{$sameSession=($observer.SessionId -eq $Process.Session)}finally{$observer.Dispose()}
    if($sameSession){
        $native=Get-Process -Id $Process.ProcessId -ErrorAction Stop
        try{
            if($native.SessionId -ne $Process.Session -or $native.MainModule.FileName -ne $Process.Path -or [Math]::Abs(($native.StartTime.ToUniversalTime()-$Process.CreatedUTC).TotalMilliseconds) -gt 1){throw 'INSTALL_WINDOW_PROBE_PROCESS_CHANGED'}
            return [pscustomobject]@{State=$(if($native.MainWindowHandle -ne [IntPtr]::Zero){'Verified'}else{'NotVisible'});Reason='CurrentDesktopObserved';CleanupVerified=$true}
        }finally{$native.Dispose()}
    }
    if($ReadOnly){return [pscustomobject]@{State='Deferred';Reason='DifferentDesktopReadOnly';CleanupVerified=$true}}
    return (Invoke-WtgUserWindowProbe $Context $Plan $Process)
}
function Test-WtgProcessParentage($Plan,[object[]]$Rows,[int]$Session) {
    $app=@($Rows|Where-Object{$_.Path -eq (Join-Path $Plan.Directory 'watchtower.exe')})
    $wardens=@($Rows|Where-Object{$_.Path -eq (Join-Path $Plan.Directory 'warden\warden.exe')})
    if($app.Count -ne 1 -or $wardens.Count -lt 1 -or $app[0].Session -ne $Session -or $app[0].ParentId -notin @($wardens.ProcessId)){return $false}
    if(@($Rows|Where-Object{$_.Session -ne $Session}).Count -or @($wardens|Where-Object{$_.ProcessId -eq $app[0].ParentId -and $_.CreatedUTC -gt $app[0].CreatedUTC}).Count){return $false}
    if(Get-WtgOption $Plan 'AllowLegacyWarden' $false){return $true}
    $launchers=@($Rows|Where-Object{$_.Path -eq (Join-Path $Plan.Directory 'warden\warden-launcher.exe')})
    if($launchers.Count -ne 1 -or $launchers[0].Session -ne $Session){return $false}
    foreach($warden in $wardens){
        $cursor=$warden;$seen=@{}
        while($cursor.ParentId -ne $launchers[0].ProcessId){
            if($seen.ContainsKey([int]$cursor.ProcessId)){return $false};$seen[[int]$cursor.ProcessId]=$true
            $parents=@($wardens|Where-Object{$_.ProcessId -eq $cursor.ParentId})
            if($parents.Count -ne 1 -or $parents[0].CreatedUTC -gt $cursor.CreatedUTC -or $parents[0].Session -ne $Session){return $false}
            $cursor=$parents[0]
        }
        if($cursor.CreatedUTC -lt $launchers[0].CreatedUTC -or $cursor.Session -ne $Session){return $false}
    }
    return $true
}
function Test-WtgInstalledStartup($Context,$Plan,[int]$Seconds=150,$Before=$null,[switch]$ReadOnly) {
    $sessions=@(Get-WtgInteractiveSessions $Plan)
    if($sessions.Count -eq 0){return [pscustomobject]@{State='DeferredUntilSignIn';Video='Deferred';Processes=@()}}
    if($sessions.Count -ne 1){throw 'INSTALL_MULTIPLE_TARGET_DESKTOP_SESSIONS'}
    $watch=[Diagnostics.Stopwatch]::StartNew();$first=$null;$stable=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt ($Seconds+45)){
        $rows=@(Get-WtgOwnedProcesses $Plan);$app=@($rows|Where-Object {$_.Path -eq (Join-Path $Plan.Directory 'watchtower.exe')});$wardens=@($rows|Where-Object {$_.Path -eq (Join-Path $Plan.Directory 'warden\warden.exe')})
        $good=Test-WtgProcessParentage $Plan $rows $sessions[0]
        if($good){
            if(-not $first){$first=$app[0];$stable.Restart()}
            elseif($first.ProcessId -ne $app[0].ProcessId -or $first.CreatedUTC -ne $app[0].CreatedUTC){throw 'INSTALL_STARTUP_RESTARTED'}
            if($stable.Elapsed.TotalSeconds -ge $Seconds){
                $visibility=Get-WtgWindowVisibility $Context $Plan $first -ReadOnly:$ReadOnly
                if($visibility.State -eq 'NotVisible'){throw 'INSTALL_STARTUP_WINDOW_NOT_VISIBLE'}
                $video='Deferred';$proof=$null;$module=Get-WtgHelperPath 'StationVideoHealth.psm1'
                if(Test-Path -LiteralPath $module){
                    Import-Module $module -Force
                    $snap=Get-StationVideoSnapshot -LogPath (Join-Path $Plan.Identity.AppData 'Cilex Vision\Watchtower\flightrec\watchtower.log') -ProcessId $first.ProcessId -CreatedUTC $first.CreatedUTC
                    if($Before -and $Before.ExpectedVideo){$proof=Assert-StationVideoProgress -Before $Before -After $snap;$video='Verified'}
                    elseif($snap.Known -and $snap.ExpectedVideo){$proof=Assert-StationVideoBaseline $snap;$video='Verified'}
                }elseif($Before){throw 'INSTALL_VIDEO_VERIFIER_MISSING'}
                return [pscustomobject]@{State=$(if($visibility.State -eq 'Verified'){'VerifiedCurrentSession'}else{'VerifiedProcessesVisibilityDeferred'});Visibility=$visibility;Video=$video;VideoProof=$proof;Processes=$rows}
            }
        }elseif($first){throw 'INSTALL_STARTUP_LOST'}
        Start-Sleep -Seconds 3
    }
    throw 'INSTALL_STARTUP_TIMEOUT'
}
function Set-WtgWardenConfiguration($Context,$Plan) {
    $dir=Split-Path -Parent $Plan.ConfigPath;$null=Assert-WtgLocalPath $dir
    [IO.Directory]::CreateDirectory($dir)|Out-Null;Set-WtgPrivateAcl $dir $Plan.Identity.Sid
    $text='';if(Test-Path -LiteralPath $Plan.ConfigPath){$text=[IO.File]::ReadAllText($Plan.ConfigPath)}
    $previousApp=@($text -split '\r?\n'|Where-Object{$_ -match '^\s*APP_CMD\s*=\s*\S'})
    if($previousApp.Count -and ($previousApp[-1] -replace '^\s*APP_CMD\s*=\s*','').Trim() -ne (Join-Path $Plan.Directory 'watchtower.exe')){throw 'WARDEN_PROFILE_ALREADY_BOUND_TO_OTHER_INSTALLATION'}
    $lines=@($text -split '\r?\n'|Where-Object {$_ -notmatch '^\s*APP_CMD\s*='})
    $lines += 'APP_CMD='+(Join-Path $Plan.Directory 'watchtower.exe')
    $environment=@{}
    foreach($line in $lines){if($line -match '^\s*APP_ENV\s*=(.*)$'){foreach($item in $matches[1].Split(',')){$separator=$item.IndexOf('=');if($separator -ge 0){$environment[$item.Substring(0,$separator).Trim()]=$item.Substring($separator+1).Trim()}}}}
    $environment['GST_PLUGIN_SYSTEM_PATH_1_0']=Join-Path $Plan.Directory 'lib\gstreamer-1.0'
    $environment['GST_PLUGIN_PATH_1_0']=Join-Path $Plan.Directory 'lib\gstreamer-1.0'
    $environment['GST_PLUGIN_SCANNER_1_0']=Join-Path $Plan.Directory 'libexec\gstreamer-1.0\gst-plugin-scanner.exe'
    $environment['GST_PLUGIN_SCANNER']=$environment['GST_PLUGIN_SCANNER_1_0']
    $environment['QML2_IMPORT_PATH']=Join-Path $Plan.Directory 'qml';$environment['QML_IMPORT_PATH']=$environment['QML2_IMPORT_PATH']
    $environment['QT_PLUGIN_PATH']=$Plan.Directory
    $backend=[string](Get-WtgOption $Context 'BackendUrl' '')
    if($backend){
        $uri=$null;if(-not [Uri]::TryCreate($backend,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('https','http') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $backend -match '[\r\n,]'){throw 'BACKEND_URL_INVALID'}
        $existing=@($lines|Where-Object{$_ -match '^\s*BACKEND_URL\s*=\s*\S'})
        if($existing.Count -and ($existing[-1] -replace '^\s*BACKEND_URL\s*=\s*','').Trim() -ne $backend.TrimEnd('/')){throw 'BACKEND_EXISTING_CONFIGURATION_DIFFERS'}
        $lines=@($lines|Where-Object{$_ -notmatch '^\s*BACKEND_URL\s*='});$lines += 'BACKEND_URL='+$backend.TrimEnd('/')
        if($environment.ContainsKey('WT_CV_URL') -and $environment['WT_CV_URL'].TrimEnd('/') -ne $backend.TrimEnd('/')){throw 'BACKEND_EXISTING_APP_ENV_DIFFERS'}
        $environment['WT_CV_URL']=$backend.TrimEnd('/')
    }
    $lines=@($lines|Where-Object{$_ -notmatch '^\s*APP_ENV\s*='});$lines += 'APP_ENV='+(($environment.Keys|Sort-Object|ForEach-Object{$_+'='+$environment[$_]}) -join ',')
    [IO.File]::WriteAllText($Plan.ConfigPath,($lines -join "`r`n"),(New-Object Text.UTF8Encoding $false))
    Set-WtgPrivateFileAcl $Plan.ConfigPath $Plan.Identity.Sid
    return 'ApplicationEnrollmentRequired'
}
function Set-WtgUnattendedStartup($Context,$Plan) {
    if((Get-WtgOption $Context 'StartupMode' 'AfterSignIn') -ne 'UnattendedReboot'){return 'AfterSignInConfiguredButUnverified'}
    $language=[string](Get-WtgOption $Context 'Language' 'en')
    if(-not (Get-WtgOption $Context 'ConsentUnattended' $false)){
        if(Get-WtgOption $Context 'NonInteractive' $false){return 'UnattendedConsentRequired'}
        $prompt=Get-WtgInstallText $language 'Automatic sign-in opens this account desktop after reboot. Type YES to open the approved setup tool, or press Enter to defer' 'Автоматический вход открывает рабочий стол после перезагрузки. Введите YES для настройки или нажмите Enter, чтобы отложить'
        if((Read-Host $prompt) -cne 'YES'){return 'UnattendedSetupDeferred'}
    }
    $state=Get-WtgAutomaticSignInState $Plan
    if($state.AccountMatches -and $state.Enabled -and -not $state.BannerPresent){return 'UnattendedConfiguredButUnverified'}
    if($state.BannerPresent){return 'UnattendedBlockedByLogonNotice'}
    $tool=[string](Get-WtgOption $Context 'AutologonPath' '')
    if(-not $tool -or -not(Test-Path -LiteralPath $tool -PathType Leaf)){
        Write-Host (Get-WtgInstallText $language 'Complete automatic sign-in using Microsoft Autologon: https://learn.microsoft.com/sysinternals/downloads/autologon . Enter credentials only in its window. Reboot verification remains required.' 'Настройте автоматический вход через Microsoft Autologon: https://learn.microsoft.com/sysinternals/downloads/autologon . Вводите пароль только в его окне. Затем требуется проверка после перезагрузки.')
        return 'UnattendedSetupRequired'
    }
    $sig=Get-AuthenticodeSignature -LiteralPath $tool
    if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)'){throw 'AUTOLOGON_PUBLISHER_NOT_VERIFIED'}
    if(Get-WtgOption $Context 'NonInteractive' $false){return 'UnattendedInteractiveSetupRequired'}
    # Visible window is intentional: the operator must enter credentials directly.
    $p=Start-Process -FilePath $tool -PassThru -Verb RunAs
    while(-not $p.WaitForExit(1000)){}
    $state=Get-WtgAutomaticSignInState $Plan
    if($state.AccountMatches -and $state.Enabled -and -not $state.BannerPresent){return 'UnattendedConfiguredButUnverified'}
    return 'UnattendedSetupNotConfirmed'
}
function Get-WtgAutomaticSignInState($Plan) {
    # Public configuration only. Never request DefaultPassword, whole-key data, or LSA secrets.
    $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    $enabled=$false;$accountMatches=$false;$banner=$false
    try{
        $key=$machine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon')
        if($key){try{
            $enabled=([string]$key.GetValue('AutoAdminLogon','') -eq '1')
            $user=[string]$key.GetValue('DefaultUserName','');$domain=[string]$key.GetValue('DefaultDomainName','')
            if($user){$name=if($domain){$domain+'\'+$user}else{$user};try{$sid=(New-Object Security.Principal.NTAccount $name).Translate([Security.Principal.SecurityIdentifier]).Value;$accountMatches=($sid -eq $Plan.Identity.Sid)}catch{}}
        }finally{$key.Dispose()}}
        $policy=$machine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System')
        if($policy){try{$caption=([string]$policy.GetValue('legalnoticecaption','')).Trim([char]0).Trim();$text=([string]$policy.GetValue('legalnoticetext','')).Trim([char]0).Trim();$banner=([bool]$caption -or [bool]$text)}finally{$policy.Dispose()}}
    }finally{$machine.Dispose()}
    return [pscustomobject]@{Enabled=$enabled;AccountMatches=$accountMatches;BannerPresent=$banner;Credential='NotRead';VerifiedAfterReboot=$false}
}
function Write-WtgInstallJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $false))}
function Confirm-WtgTargetRequirements($Context,$Plan) {
    $module=Join-Path $PSScriptRoot 'Requirements.psm1'
    if(-not(Test-Path -LiteralPath $module)){throw 'INSTALL_REQUIREMENTS_MODULE_MISSING'}
    Import-Module $module -Force
    $Context|Add-Member -NotePropertyName InstallDir -NotePropertyValue $Plan.Directory -Force
    $findings=@(Get-WtgRequirements -Context $Context -Role Target)
    $blocked=@($findings|Where-Object{$_.State -eq 'BLOCKED' -and -not $_.CanOverride})
    $accepted=@(Get-WtgOption $Context 'OverrideRequirements' @())
    $pending=@($findings|Where-Object{$_.State -ne 'PASS' -and $_.Id -notin $accepted})
    foreach($finding in $pending){Write-Host ($finding.Id+': '+$finding.Message)}
    if($blocked.Count){throw 'INSTALL_REQUIREMENTS_BLOCKED'}
    if($pending.Count){
        if(@($pending|Where-Object{-not $_.CanOverride}).Count -or (Get-WtgOption $Context 'NonInteractive' $false)){throw 'INSTALL_REQUIREMENTS_ACCEPTANCE_REQUIRED'}
        $prompt=Get-WtgInstallText (Get-WtgOption $Context 'Language' 'en') 'Continue with these limitations? Type YES or press Enter to cancel' 'Продолжить с указанными ограничениями? Введите YES или нажмите Enter для отмены'
        if((Read-Host $prompt) -cne 'YES'){throw 'INSTALL_CANCELLED'}
        $Context|Add-Member -NotePropertyName OverrideRequirements -NotePropertyValue (@($accepted)+@($pending.Id)) -Force
    }
    return $findings
}
function Install-WtgRuntimePrerequisites($Package,$Context) {
    if(-not $Package.Manifest.PSObject.Properties['prerequisites']){return}
    foreach($prerequisite in @($Package.Manifest.prerequisites)){
        # Only the supported VC runtime installer is accepted. Never execute arbitrary manifest commands.
        if($prerequisite.path -ne 'prerequisites/vc_redist.x64.exe' -and $prerequisite.path -ne 'prerequisites\vc_redist.x64.exe'){throw 'PACKAGE_PREREQUISITE_UNSUPPORTED'}
        $declared=@($Package.Manifest.files|Where-Object{$_.path.Replace('/','\') -eq $prerequisite.path.Replace('/','\')})
        if($declared.Count -ne 1){throw 'PACKAGE_PREREQUISITE_NOT_HASHED'}
        $exe=Resolve-WtgPayloadPath $Package.Payload $prerequisite.path
        $sig=Get-AuthenticodeSignature -LiteralPath $exe
        if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)'){throw 'PACKAGE_PREREQUISITE_PUBLISHER_INVALID'}
        $runtime=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')
        $ready=$false
        if($runtime){try{$installedVersion=[string]$runtime.GetValue('Version','');$required=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion;$ready=([int]$runtime.GetValue('Installed',0) -eq 1 -and [version]$installedVersion.TrimStart('v') -ge [version]($required -replace '[^0-9.].*$',''))}catch{$ready=$false}finally{$runtime.Dispose()}}
        if($ready){continue}
        if(-not(Test-WtgElevation)){throw 'INSTALL_ELEVATION_REQUIRED'}
        $process=Start-Process -FilePath $exe -ArgumentList '/install','/quiet','/norestart' -PassThru -WindowStyle Hidden
        try{$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $process.WaitForExit(1000) -and $clock.Elapsed.TotalSeconds -lt 900){};if(-not $process.HasExited){throw 'PREREQUISITE_INSTALL_TIMEOUT'};$code=$process.ExitCode}finally{$process.Dispose()}
        if($code -eq 3010){throw 'PREREQUISITE_RESTART_REQUIRED'}
        if($code -notin @(0,1638)){throw 'PREREQUISITE_INSTALL_FAILED'}
    }
}
function Register-WtgUninstaller($Plan,$Package) {
    $meta=Join-Path $Plan.Directory '.deployment';[IO.Directory]::CreateDirectory($meta)|Out-Null
    $files=@()
    foreach($name in @('install-target.ps1','Install.psm1','Common.psm1','StationVideoHealth.psm1','Requirements.psm1','requirements.json')){
        $src=Get-WtgHelperPath $name
        if(Test-Path -LiteralPath $src){$dest=Join-Path $meta $name;[IO.File]::Copy($src,$dest,$true);$files += [pscustomobject]@{path=('.deployment\'+$name);sha256=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash;size=(Get-Item -LiteralPath $dest).Length}}
    }
    $markerPath=Join-Path $Plan.Directory '.cilex-install.json';$m=Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8|ConvertFrom-Json
    $m.files=@($m.files)+$files;Write-WtgInstallJson $markerPath $m
    $base=if($Plan.Scope -eq 'Machine'){[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::Users}
    $prefix=if($Plan.Scope -eq 'Machine'){''}else{$Plan.Identity.Sid+'\'}
    $key=$base.CreateSubKey($prefix+'Software\Microsoft\Windows\CurrentVersion\Uninstall\CilexWatchtower-'+$Plan.Id)
    try{
        $cmd='"'+(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')+'" -NoProfile -File "'+(Join-Path $meta 'install-target.ps1')+'" -Uninstall -InstallDir "'+$Plan.Directory+'" -InstallScope '+$Plan.Scope+' -TargetSid '+$Plan.Identity.Sid+' -TargetUser "'+$Plan.Identity.Name+'"'
        $key.SetValue('DisplayName','Cilex Watchtower');$key.SetValue('DisplayVersion',$Package.Manifest.version);$key.SetValue('Publisher','Cilex');$key.SetValue('InstallLocation',$Plan.Directory);$key.SetValue('UninstallString',$cmd);$key.SetValue('NoModify',1,[Microsoft.Win32.RegistryValueKind]::DWord);$key.SetValue('NoRepair',1,[Microsoft.Win32.RegistryValueKind]::DWord)
    }finally{$key.Dispose()}
}
function Get-WtgRegistrationSnapshot($Plan) {
    $base=if($Plan.Scope -eq 'Machine'){[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::Users}
    $prefix=if($Plan.Scope -eq 'Machine'){''}else{$Plan.Identity.Sid+'\'}
    $key=$base.OpenSubKey($prefix+'Software\Microsoft\Windows\CurrentVersion\Uninstall\CilexWatchtower-'+$Plan.Id)
    if(-not $key){return [pscustomobject]@{Present=$false;Values=@()}}
    try{$values=@();foreach($name in @('DisplayName','DisplayVersion','Publisher','InstallLocation','UninstallString','NoModify','NoRepair')){if($key.GetValueNames() -contains $name){$values += [pscustomobject]@{Name=$name;Kind=$key.GetValueKind($name).ToString();Value=$key.GetValue($name)}}};return [pscustomobject]@{Present=$true;Values=$values}}finally{$key.Dispose()}
}
function Restore-WtgRegistration($Plan,$Snapshot) {
    $base=if($Plan.Scope -eq 'Machine'){[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::Users}
    $prefix=if($Plan.Scope -eq 'Machine'){''}else{$Plan.Identity.Sid+'\'}
    $path=$prefix+'Software\Microsoft\Windows\CurrentVersion\Uninstall\CilexWatchtower-'+$Plan.Id
    if(-not $Snapshot.Present){$base.DeleteSubKeyTree($path,$false);return}
    $key=$base.CreateSubKey($path)
    try{foreach($name in @('DisplayName','DisplayVersion','Publisher','InstallLocation','UninstallString','NoModify','NoRepair')){if($name -notin @($Snapshot.Values.Name)){$key.DeleteValue($name,$false)}};foreach($value in $Snapshot.Values){$key.SetValue($value.Name,$value.Value,[Microsoft.Win32.RegistryValueKind]$value.Kind)}}finally{$key.Dispose()}
}
function Remove-WtgTaskIfPresent($Plan) {
    # A missing task can cause a terminating CIM exception even with SilentlyContinue.
    # Enumerate successfully first; never confuse a failed query with absence.
    $task=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -eq $Plan.TaskName})
    if(-not $task.Count){return}
    if($task.Count -ne 1){throw 'INSTALL_TASK_IDENTITY_MISMATCH'}
    $null=Get-WtgTaskXml $Plan
    Unregister-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
    if(@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object{$_.TaskName -eq $Plan.TaskName}).Count){throw 'INSTALL_TASK_REMOVAL_UNVERIFIED'}
}
function Get-WtgFailureDiagnostic($Record) {
    $code='INSTALL_OPERATION_FAILED'
    if($Record.Exception.Message -match '^[A-Z][A-Z0-9_]{4,100}$'){$code=$Record.Exception.Message}
    return [pscustomobject]@{ErrorCode=$code;ExceptionType=$Record.Exception.GetType().FullName;Script=[IO.Path]::GetFileName([string]$Record.InvocationInfo.ScriptName);Line=[int]$Record.InvocationInfo.ScriptLineNumber}
}
function Invoke-WtgDirectoryTransaction($Package,$Plan,[string]$RunId,[scriptblock]$Configure,[scriptblock]$Verify,[scriptblock]$Restore,[scriptblock]$BeforeReplace={}) {
    $parent=Split-Path -Parent $Plan.Directory;[IO.Directory]::CreateDirectory($parent)|Out-Null
    $stage=Join-Path $parent ('.cilex-stage-'+$RunId);$backup=Join-Path $parent ('.cilex-backup-'+$RunId)
    if(Test-Path -LiteralPath $stage){throw 'INSTALL_STAGE_EXISTS'};if(Test-Path -LiteralPath $backup){throw 'INSTALL_BACKUP_EXISTS'}
    [IO.Directory]::CreateDirectory($stage)|Out-Null
    foreach($f in $Package.Manifest.files){$dest=Resolve-WtgPayloadPath $stage $f.path;[IO.Directory]::CreateDirectory((Split-Path -Parent $dest))|Out-Null;[IO.File]::Copy((Resolve-WtgPayloadPath $Package.Payload $f.path),$dest,$false);if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $f.sha256){throw 'INSTALL_STAGED_HASH_MISMATCH'}}
    $marker=[ordered]@{product='CilexWatchtower';schemaVersion=1;installId=$Plan.Id;targetSid=$Plan.Identity.Sid;installDir=$Plan.Directory;installScope=$Plan.Scope;taskName=$Plan.TaskName;version=$Package.Manifest.version;wardenVersion=$Package.Manifest.wardenVersion;sourceCommit=$Package.Manifest.sourceCommit;manifestSha256=$Package.ManifestSha256;runId=$RunId;files=$Package.Manifest.files}
    Write-WtgInstallJson (Join-Path $stage '.cilex-install.json') $marker
    Set-WtgPrivateAcl $stage $Plan.Identity.Sid -Machine:($Plan.Scope -eq 'Machine')
    $moved=$false;$installed=$false
    try{
        & $BeforeReplace
        if(Test-Path -LiteralPath $Plan.Directory){Move-Item -LiteralPath $Plan.Directory -Destination $backup -ErrorAction Stop;$moved=$true}
        Move-Item -LiteralPath $stage -Destination $Plan.Directory -ErrorAction Stop;$installed=$true
        & $Configure
        $check=& $Verify
        return [pscustomobject]@{Backup=$(if($moved){$backup}else{$null});Verification=$check;Marker=$marker}
    }catch{
        $original=$_
        try{
            # Restore callback must first stop only the new owned processes.
            & $Restore 'BeforeFiles'
            if($installed){$failed=Join-Path $parent ('.cilex-failed-'+$RunId);Move-Item -LiteralPath $Plan.Directory -Destination $failed -ErrorAction Stop}
            if($moved){Move-Item -LiteralPath $backup -Destination $Plan.Directory -ErrorAction Stop}
            & $Restore 'AfterFiles'
        }catch{
            $failure=New-Object InvalidOperationException 'INSTALL_FAILED_ROLLBACK_UNVERIFIED'
            $failure.Data['InstallFailure']=Get-WtgFailureDiagnostic $original
            $failure.Data['RollbackFailure']=Get-WtgFailureDiagnostic $_
            $failure.Data['RollbackVerified']=$false
            throw $failure
        }
        $original.Exception.Data['InstallFailure']=Get-WtgFailureDiagnostic $original
        $original.Exception.Data['RollbackVerified']=$true
        throw $original
    }
}
function Install-WtgPackage($Context,[string]$PackagePath) {
    if($Context.RunId -notmatch '^[A-Za-z0-9_-]{8,80}$'){throw 'INSTALL_RUN_ID_INVALID'}
    $identity=Resolve-WtgTargetIdentity (Get-WtgOption $Context 'TargetUser' '') (Get-WtgOption $Context 'TargetSid' '')
    $plan=Get-WtgInstallPlan $Context $identity
    if($plan.Scope -eq 'Machine'){Assert-WtgMachineParent $plan.Directory}
    if((Get-WtgOption $Context 'ExpectedHost' '') -and $env:COMPUTERNAME -ne $Context.ExpectedHost){throw 'TARGET_HOST_MISMATCH'}
    $findings=Confirm-WtgTargetRequirements $Context $plan
    $packageRoot=Expand-WtgInstallInput $Context $PackagePath
    $package=Test-WtgPackage $packageRoot (Get-WtgOption $Context 'PackageManifestSha256' '')
    $adoption=Get-WtgLegacyAdoption $Context $plan
    $old=if($adoption){[pscustomobject]@{Legacy=$true}}else{Assert-WtgOwnedInstallation $plan}
    $oldTask=Get-WtgTaskXml $plan
    $oldTaskEnabled=if($oldTask){Get-WtgTaskEnabled $plan.TaskName}else{$false}
    $null=Get-WtgOwnedProcesses $plan
    if(($plan.Scope -eq 'Machine' -or -not $identity.IsCurrent) -and -not(Test-WtgElevation)){throw 'INSTALL_ELEVATION_REQUIRED'}
    Install-WtgRuntimePrerequisites $package $Context
    $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($plan.Directory));if($drive.AvailableFreeSpace -lt ($package.Bytes+256MB)){throw 'INSTALL_INSUFFICIENT_DISK'}
    [IO.Directory]::CreateDirectory($plan.StatePath)|Out-Null;Set-WtgPrivateAcl $plan.StatePath $identity.Sid
    # Warden's configuration/single-instance lock is per profile, so serialise other
    # installation paths for the same user as well as this exact installation.
    $profileLock=[IO.File]::Open((Join-Path (Split-Path -Parent $plan.StatePath) 'profile-warden.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $lock=$null
    try {
    $lock=[IO.File]::Open((Join-Path $plan.StatePath 'install.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $registration=Get-WtgRegistrationSnapshot $plan
    $configBackup=Join-Path $plan.StatePath ($Context.RunId+'.warden.conf.backup');$hadConfig=Test-Path -LiteralPath $plan.ConfigPath
    $configAcl=$null;$configDirectoryAcl=$null
    if($hadConfig){$configAcl=Get-Acl -LiteralPath $plan.ConfigPath;[IO.File]::Copy($plan.ConfigPath,$configBackup,$false)}
    if(Test-Path -LiteralPath (Split-Path -Parent $plan.ConfigPath)){$configDirectoryAcl=Get-Acl -LiteralPath (Split-Path -Parent $plan.ConfigPath)}
    $baseline=$null;$app=@(Get-WtgOwnedProcesses $plan|Where-Object{$_.Path -eq (Join-Path $plan.Directory 'watchtower.exe')})
    if($app.Count){
        $vm=Get-WtgHelperPath 'StationVideoHealth.psm1';Import-Module $vm -Force
        $baseline=Get-StationVideoSnapshot -LogPath (Join-Path $identity.AppData 'Cilex Vision\Watchtower\flightrec\watchtower.log') -ProcessId $app[0].ProcessId -CreatedUTC $app[0].CreatedUTC
        $null=Assert-StationVideoBaseline $baseline
    }
    Write-WtgInstallJson (Join-Path $plan.StatePath ($Context.RunId+'.previous-startup.json')) @{managedTaskXml=$oldTask;managedTaskEnabled=$oldTaskEnabled;legacy=$adoption;wasRunning=($app.Count -gt 0)}
    $taskDisabled=$false
    $shutdown=[pscustomobject]@{OriginalAdmission=[pscustomobject]@{Initialized=$false;Rows=@()};ReplacementAdmission=[pscustomobject]@{Initialized=$false;Rows=@()};StartupAttempted=$false}
    try{
        $beforeReplace={
            Stop-WtgOwnedProcesses $plan -BeforeStop {
                if($adoption){$legacyPlan=$plan.PSObject.Copy();$legacyPlan.TaskName=$adoption.TaskName;$legacyPlan|Add-Member -NotePropertyName AllowLegacyWarden -NotePropertyValue $true;Stop-WtgTaskExecution $legacyPlan}
                if($oldTask){Stop-WtgTaskExecution $plan}
            } -Admission $shutdown.OriginalAdmission
        }
        $configure={
            $null=Set-WtgWardenConfiguration $Context $plan
            Register-WtgUninstaller $plan $package
            Register-WtgTask $plan
            if(@(Get-WtgInteractiveSessions $plan).Count -gt 0){$shutdown.StartupAttempted=$true;Start-ScheduledTask -TaskName $plan.TaskName}
        }
        $verify={Test-WtgInstalledStartup $Context $plan -Before $baseline}
        $restore={param($Phase)
            if($Phase -eq 'BeforeFiles'){
                $admission=if($shutdown.StartupAttempted){$shutdown.ReplacementAdmission}else{$shutdown.OriginalAdmission}
                Stop-WtgOwnedProcesses $plan -BeforeStop {
                    $task=Get-WtgTaskXml $plan
                    if($task){Stop-WtgTaskExecution $plan}
                } -Admission $admission
            }else{
                Restore-WtgRegistration $plan $registration
                if($hadConfig){[IO.File]::Copy($configBackup,$plan.ConfigPath,$true);Set-Acl -LiteralPath $plan.ConfigPath -AclObject $configAcl}elseif(Test-Path -LiteralPath $plan.ConfigPath){Remove-Item -LiteralPath $plan.ConfigPath -Force}
                if($configDirectoryAcl){Set-Acl -LiteralPath (Split-Path -Parent $plan.ConfigPath) -AclObject $configDirectoryAcl}
                if($oldTask){Register-ScheduledTask -TaskName $plan.TaskName -Xml $oldTask -Force|Out-Null;Set-WtgRestoredTaskEnabled $plan.TaskName $oldTaskEnabled;if($oldTaskEnabled -and $app.Count -gt 0 -and @(Get-WtgInteractiveSessions $plan).Count){Start-ScheduledTask -TaskName $plan.TaskName;$null=Test-WtgInstalledStartup $Context $plan -Before $baseline}}
                else{Remove-WtgTaskIfPresent $plan}
                if($adoption){Register-ScheduledTask -TaskName $adoption.TaskName -Xml $adoption.Xml -Force|Out-Null;Set-WtgRestoredTaskEnabled $adoption.TaskName $adoption.Enabled;if($adoption.Enabled -and $app.Count -gt 0 -and @(Get-WtgInteractiveSessions $plan).Count){Start-ScheduledTask -TaskName $adoption.TaskName;$legacyPlan=$plan.PSObject.Copy();$legacyPlan|Add-Member -NotePropertyName AllowLegacyWarden -NotePropertyValue $true;$null=Test-WtgInstalledStartup $Context $legacyPlan -Before $baseline}}
            }
        }
        $tx=Invoke-WtgDirectoryTransaction $package $plan $Context.RunId $configure $verify $restore $beforeReplace
        if($adoption){Write-WtgInstallJson (Join-Path $plan.StatePath ($Context.RunId+'.adoption.json')) @{taskName=$adoption.TaskName;xml=$adoption.Xml;backup=$tx.Backup}}
        $startupError=$null
        try{$startup=Set-WtgUnattendedStartup $Context $plan}catch{
            # Files, task and current-session validation are already committed. Preserve
            # that truthful outcome when the separate automatic-sign-in step is declined.
            $startup='UnattendedSetupNotCompleted';$startupError='AUTOLOGON_SETUP_FAILED'
            if($_.Exception.Message -match '^[A-Z][A-Z0-9_]{4,100}$'){$startupError=$_.Exception.Message}
        }
        $result=[pscustomobject]@{RunId=$Context.RunId;Target=$env:COMPUTERNAME;Status='InstalledWithDeferredChecks';InstallDir=$plan.Directory;InstallScope=$plan.Scope;StartupMode=(Get-WtgOption $Context 'StartupMode' 'AfterSignIn');Version=$package.Manifest.version;WardenVersion=$package.Manifest.wardenVersion;SourceCommit=$package.Manifest.sourceCommit;ManifestSha256=$package.ManifestSha256;TargetSid=$identity.Sid;TaskName=$plan.TaskName;Startup=$startup;StartupErrorCode=$startupError;Backend='ApplicationEnrollmentRequired';Runtime=$tx.Verification;Backup=$tx.Backup;RebootVerified=$false;InstalledUTC=[DateTime]::UtcNow.ToString('o');BootUTC=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');Findings=$findings;AcceptedWarnings=@(Get-WtgOption $Context 'OverrideRequirements' @())}
        Write-WtgInstallJson (Join-Path $plan.StatePath 'last-install.json') $result
        return $result
    }catch{
        if($taskDisabled -and $oldTask -and (Test-Path -LiteralPath $plan.Directory)){try{Register-ScheduledTask -TaskName $plan.TaskName -Xml $oldTask -Force|Out-Null}catch{}}
        throw
    }
    }finally{if($lock){$lock.Dispose()};$profileLock.Dispose()}
}
function Uninstall-WtgPackage($Context) {
    $identity=Resolve-WtgTargetIdentity (Get-WtgOption $Context 'TargetUser' '') (Get-WtgOption $Context 'TargetSid' '')
    $plan=Get-WtgInstallPlan $Context $identity;$marker=Assert-WtgOwnedInstallation $plan
    if(-not $marker){throw 'UNINSTALL_MARKER_REQUIRED'}
    if(($plan.Scope -eq 'Machine' -or -not $identity.IsCurrent) -and -not(Test-WtgElevation)){throw 'INSTALL_ELEVATION_REQUIRED'}
    $task=Get-WtgTaskXml $plan
    foreach($f in $marker.files){$path=Resolve-WtgPayloadPath $plan.Directory $f.path;if((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $f.sha256){throw 'UNINSTALL_MODIFIED_FILE_RETAINED'}}
    [IO.Directory]::CreateDirectory($plan.StatePath)|Out-Null
    $lock=[IO.File]::Open((Join-Path $plan.StatePath 'install.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        Stop-WtgOwnedProcesses $plan -BeforeStop {if($task){Stop-WtgTaskExecution $plan}}
        # Delete only unchanged declared payload files. Unknown/changed files and settings survive.
        foreach($f in $marker.files){$path=Resolve-WtgPayloadPath $plan.Directory $f.path;if(Test-Path -LiteralPath $path){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $f.sha256){Remove-Item -LiteralPath $path -Force}else{throw 'UNINSTALL_MODIFIED_FILE_RETAINED'}}}
        if($task){Unregister-ScheduledTask -TaskName $plan.TaskName -Confirm:$false}
        $base=if($plan.Scope -eq 'Machine'){[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::Users}
        $prefix=if($plan.Scope -eq 'Machine'){''}else{$identity.Sid+'\'}
        $base.DeleteSubKeyTree($prefix+'Software\Microsoft\Windows\CurrentVersion\Uninstall\CilexWatchtower-'+$plan.Id,$false)
        Remove-Item -LiteralPath (Join-Path $plan.Directory '.cilex-install.json') -Force
        return [pscustomobject]@{RunId=$Context.RunId;Target=$env:COMPUTERNAME;TargetSid=$identity.Sid;Status='Uninstalled';Settings='Preserved';InstallDir=$plan.Directory}
    }finally{$lock.Dispose()}
}
function Get-WtgInstallRecordState($Record,$Marker) {
    if(-not $Record){return 'Missing'}
    foreach($name in @('RunId','TargetSid','InstallDir','InstallScope','Version','WardenVersion','SourceCommit')){
        if(-not $Record.PSObject.Properties[$name] -or -not $Marker.PSObject.Properties[$name] -or [string]$Record.$name -ne [string]$Marker.$name){return 'Mismatched'}
    }
    if($Marker.PSObject.Properties['ManifestSha256'] -and $Marker.ManifestSha256){
        if(-not $Record.PSObject.Properties['ManifestSha256'] -or [string]$Record.ManifestSha256 -ne [string]$Marker.ManifestSha256){return 'Mismatched'}
    }
    return 'Current'
}
function Get-WtgStartupVerification($Context) {
    $identity=Resolve-WtgTargetIdentity (Get-WtgOption $Context 'TargetUser' '') (Get-WtgOption $Context 'TargetSid' '')
    $plan=Get-WtgInstallPlan $Context $identity;$marker=Assert-WtgOwnedInstallation $plan
    if(-not $marker){throw 'VERIFY_INSTALLATION_REQUIRED'}
    $null=Assert-WtgStartupTask $plan
    $lastPath=Join-Path $plan.StatePath 'last-install.json';$last=$null;$before=$null;$recordState='Missing'
    if(Test-Path -LiteralPath $lastPath){
        $last=Get-Content -LiteralPath $lastPath -Raw -Encoding UTF8|ConvertFrom-Json
        $recordState=Get-WtgInstallRecordState $last $marker
        if($recordState -ne 'Current'){$last=$null}
        if($last -and $last.Runtime.PSObject.Properties['VideoProof'] -and $last.Runtime.VideoProof -and $last.Runtime.VideoProof.VideoVerified){
            $before=[pscustomobject]@{Known=$true;ExpectedVideo=$true;Latest=[pscustomobject]@{Errors=0;Lit=$last.Runtime.VideoProof.FinalLit;Decoders=$last.Runtime.VideoProof.FinalDecoders}}
        }
    }
    $runtime=Test-WtgInstalledStartup $Context $plan -Before $before -ReadOnly
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $automatic=Get-WtgAutomaticSignInState $plan
    $evidence=Test-WtgRebootEvidence $last $boot $runtime $automatic ([bool](Get-WtgOption $Context 'ConfirmNoManualSignIn' $false))
    return [pscustomobject]@{RunId=$Context.RunId;Target=$env:COMPUTERNAME;Status='VerificationCompleted';InstallDir=$plan.Directory;InstallScope=$plan.Scope;TargetSid=$identity.Sid;InstallRecordState=$recordState;Runtime=$runtime;RebootObserved=$evidence.RebootObserved;AutomaticSignIn=$evidence.AutomaticSignIn;RebootVerified=$evidence.RebootVerified;AutologonPublicConfiguration=$automatic}
}
function Test-WtgRebootEvidence($Last,[DateTime]$Boot,$Runtime,$Automatic,[bool]$ConfirmNoManualSignIn) {
    $observed=($Last -and $Boot -gt [DateTime]::Parse($Last.InstalledUTC).ToUniversalTime() -and $Runtime.State -in @('VerifiedCurrentSession','VerifiedProcessesVisibilityDeferred') -and @($Runtime.Processes|Where-Object{[DateTime]$_.CreatedUTC -lt $Boot}).Count -eq 0)
    $visible=($Runtime.PSObject.Properties['Visibility'] -and $Runtime.Visibility -and $Runtime.Visibility.State -eq 'Verified')
    $verified=($observed -and $visible -and $ConfirmNoManualSignIn -and $Automatic.Enabled -and $Automatic.AccountMatches -and -not $Automatic.BannerPresent)
    return [pscustomobject]@{RebootObserved=[bool]$observed;RebootVerified=[bool]$verified;AutomaticSignIn=$(if($verified){'VerifiedWithExplicitNoManualSignInConfirmation'}else{'NotProven'})}
}
Export-ModuleMember -Function Install-WtgPackage,Uninstall-WtgPackage,Get-WtgStartupVerification,Test-WtgPackage,Expand-WtgPackage,Expand-WtgInstallInput,Resolve-WtgTargetIdentity,Get-WtgInstallPlan,Get-WtgOption,Get-WtgInstallFailureText,Get-WtgHelperPath,Test-WtgRebootEvidence

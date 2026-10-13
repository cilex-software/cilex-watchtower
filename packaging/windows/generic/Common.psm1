# Shared helpers for the standalone Windows deployer. Windows PowerShell 5.1.
Set-StrictMode -Version 2
$script:WtgSecrets = New-Object 'System.Collections.Generic.List[string]'
$script:Messages = @{
    en = @{
        Preview='Preview only. No files, applications or settings were changed.'
        WindowsOnly='Run this installer on Windows.'
        Plan='Mode: {0}. Installation target: {1}. Source: {2}.'
        Checking='Checking this computer and the required access.'
        PlanAccept='Continue with the listed downloads and installation steps? [y/N]'
        Cancelled='Cancelled. Existing installations were preserved.'
        RequiredInputs='Missing required input: {0}.'
        Requirements='Some requirements are not met. Retry checks, continue with the listed warnings, or cancel? [R/C/N]'
        Blocked='Installation cannot continue: {0}'
        Unknown='This check is not verified: {0}'
        Dependency='Preparing the required build tools.'
        Source='Obtaining the requested source revision.'
        Building='Building and checking Watchtower and Warden.'
        Packaging='Creating the offline installer.'
        Installing='Installing the verified package.'
        Finished='Completed. Result: {0}'
        Deferred='Completed with checks or setup still required. Result: {0}'
        Failed='The operation did not complete. {0}'
        Log='Diagnostic record: {0}'
        GitFailed='Source access failed. Check the repository, tag and GitHub authorization.'
        GitToken='GitHub read-only token (input hidden)'
        GitDenied='GitHub refused access. Check token expiry, repository read permission and organization authorization; enter the token through Read-Host -AsSecureString.'
        GitMissingRef='The requested tag or branch was not found. Check its exact name; main was not substituted.'
        Backend='Backend address, or leave empty to configure later'
        Startup='Startup: 1 = after Windows sign-in; 2 = unattended after reboot. Choose 1 or 2'
        StartupRequired='Choose AfterSignIn or UnattendedReboot. Reboot alone cannot display cameras without a signed-in desktop.'
        OverrideRequired='Explicit acceptance is required for these findings: {0}.'
        LicenseRequired='Accept the dependency license terms with -AcceptLicenses before automatic provisioning.'
        InputConflict='These options cannot be combined: {0}.'
        Resume='Inspect the previous result before repeating an interrupted installation: {0}'
        OfflineSource='Offline builds need -SourceBundle or -SourceDirectory with -SourceCommit. Latest main cannot be verified offline.'
        ResultUnavailable='The operation failed before a result directory was created.'
        NoClaim='Build and package checks do not prove fresh-machine, camera-capacity or reboot compatibility.'
        InvalidHost='Use a computer name or IPv4 address for TargetHost.'
        InvalidBackend='Use an HTTP(S) backend address without a password, token, query or fragment.'
        StatePASS='PASS'; StateWARNING='WARNING'; StateBLOCKED='BLOCKED'; StateUNKNOWN='UNKNOWN'
    }
    ru = @{
        Preview='Только предварительный просмотр. Файлы, программы и настройки не изменены.'
        WindowsOnly='Запустите установщик в Windows.'
        Plan='Режим: {0}. Компьютер для установки: {1}. Исходный код: {2}.'
        Checking='Проверяю компьютер и необходимый доступ.'
        PlanAccept='Продолжить загрузку и установку перечисленных компонентов? [y/N]'
        Cancelled='Отменено. Существующие установки сохранены.'
        RequiredInputs='Не указан обязательный параметр: {0}.'
        Requirements='Некоторые требования не выполнены. Повторить проверку, продолжить с предупреждениями или отменить? [R/C/N]'
        Blocked='Невозможно продолжить установку: {0}'
        Unknown='Проверка не подтверждена: {0}'
        Dependency='Подготавливаю необходимые средства сборки.'
        Source='Получаю указанную версию исходного кода.'
        Building='Собираю и проверяю Watchtower и Warden.'
        Packaging='Создаю установщик для работы без интернета.'
        Installing='Устанавливаю проверенный пакет.'
        Finished='Готово. Результат: {0}'
        Deferred='Работа завершена, но нужны дополнительные настройки или проверки. Результат: {0}'
        Failed='Операция не завершена. {0}'
        Log='Подробности проверки: {0}'
        GitFailed='Не удалось получить исходный код. Проверьте репозиторий, тег и доступ GitHub.'
        GitToken='Токен GitHub для чтения (ввод скрыт)'
        GitDenied='GitHub отказал в доступе. Проверьте срок действия токена, право чтения репозитория и разрешение организации; вводите токен через Read-Host -AsSecureString.'
        GitMissingRef='Указанный тег или ветка не найдены. Проверьте точное имя; замена на main не выполнялась.'
        Backend='Адрес сервера; оставьте пустым, чтобы настроить позже'
        Startup='Запуск: 1 — после входа в Windows; 2 — автоматически после перезагрузки. Выберите 1 или 2'
        StartupRequired='Выберите AfterSignIn или UnattendedReboot. Для отображения камер нужен вход пользователя в Windows.'
        OverrideRequired='Нужно явно принять следующие предупреждения: {0}.'
        LicenseRequired='Для автоматической установки примите условия лицензий параметром -AcceptLicenses.'
        InputConflict='Эти параметры нельзя использовать вместе: {0}.'
        Resume='Перед повторной установкой проверьте результат предыдущей попытки: {0}'
        OfflineSource='Для сборки без интернета нужны -SourceBundle или -SourceDirectory вместе с -SourceCommit. Актуальность main проверить невозможно.'
        ResultUnavailable='Сбой произошёл до создания папки с результатом.'
        NoClaim='Проверки сборки не подтверждают работу на чистом компьютере, допустимое число камер или запуск после перезагрузки.'
        InvalidHost='Укажите имя компьютера или IPv4-адрес в TargetHost.'
        InvalidBackend='Укажите HTTP(S)-адрес сервера без пароля, токена, параметров запроса или фрагмента.'
        StatePASS='ПРОЙДЕНО'; StateWARNING='ВНИМАНИЕ'; StateBLOCKED='НЕВОЗМОЖНО'; StateUNKNOWN='НЕ ПРОВЕРЕНО'
    }
}

function Get-WtgLanguage {
    param([ValidateSet('Auto','en','ru')][string]$Language='Auto')
    if($Language -ne 'Auto'){return $Language}
    $culture=[Globalization.CultureInfo]::CurrentUICulture
    if(-not $culture -or -not $culture.Name){$culture=[Globalization.CultureInfo]::InstalledUICulture}
    if($culture.TwoLetterISOLanguageName -eq 'ru'){return 'ru'}
    return 'en'
}
function Get-WtgMessage {
    param([Parameter(Mandatory=$true)][string]$Key,[object[]]$Values=@(),[string]$Language='en')
    if(-not $script:Messages.ContainsKey($Language)){$Language='en'}
    $message=$script:Messages[$Language][$Key]
    if(-not $message){$message=$Key}
    if($Values.Count){return [string]::Format([Globalization.CultureInfo]::InvariantCulture,$message,$Values)}
    return $message
}
function Write-WtgMessage {
    param($Context,[string]$Key,[object[]]$Values=@())
    Write-Host (Get-WtgMessage -Key $Key -Values $Values -Language $Context.Language)
}
function Merge-WtgFindings {
    param([object[]]$Findings)
    # Build and target checks may share an identifier: never hide the worse result.
    $rank=@{PASS=0;WARNING=1;UNKNOWN=2;BLOCKED=3}
    foreach($group in @($Findings|Group-Object Id|Sort-Object Name)){
        $group.Group|Sort-Object @{Expression={$rank[[string]$_.State]};Descending=$true},@{Expression={[bool]$_.CanOverride};Descending=$false}|Select-Object -First 1
    }
}
function Protect-WtgText {
    param([AllowNull()][string]$Text)
    if($null -eq $Text){return ''}
    foreach($secret in $script:WtgSecrets){if($secret){$Text=$Text.Replace($secret,'[REDACTED]')}}
    $Text=[regex]::Replace($Text,'(?i)(https?://)[^\s/@]+:[^\s/@]+@','$1[REDACTED]@')
    $Text=[regex]::Replace($Text,'(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})\b','[REDACTED]')
    $Text=[regex]::Replace($Text,'(?i)((?:authorization\s*[:=]\s*(?:bearer|basic)?|(?:access_token|refresh_token|gh_token|station_token|password)\s*[=:])\s*)[^\s,;]+','$1[REDACTED]')
    return $Text
}
function Register-WtgSecret { param([string]$Secret) if($Secret){$script:WtgSecrets.Add($Secret)} }
function Unregister-WtgSecret { param([string]$Secret) if($Secret){$null=$script:WtgSecrets.Remove($Secret)} }
function Get-WtgSha256 { param([Parameter(Mandatory=$true)][string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-WtgDiagnostic {
    param([string]$Path,[string]$Text,[ValidateRange(1024,16777216)][int]$MaximumCharacters=2097152)
    $value=Protect-WtgText $Text
    if($value.Length -gt $MaximumCharacters){
        $half=[int]($MaximumCharacters/2)-64
        $value=$value.Substring(0,$half)+"`r`n[Diagnostic log size limit reached; middle output omitted.]`r`n"+$value.Substring($value.Length-$half)
    }
    [IO.File]::WriteAllText($Path,$value,(New-Object Text.UTF8Encoding($false)))
}
function Write-WtgJson {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Value)
    $parent=Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'Result directory does not exist.'}
    $tmp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $backup=$tmp+'.previous'
    try {
        $json=Protect-WtgText ($Value|ConvertTo-Json -Depth 30)
        [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($tmp,$Path,$backup)}else{[IO.File]::Move($tmp,$Path)}
    }finally{
        if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}
        if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force}
    }
}
function Test-WtgElevation {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function ConvertTo-WtgArgument {
    param([AllowEmptyString()][string]$Value)
    if($Value -match "[\x00\r\n]"){throw 'Process arguments must not contain control characters.'}
    return '"'+([regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1'))+'"'
}
function Invoke-WtgProcess {
    param([Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),[string]$WorkingDirectory,
        [hashtable]$Environment=@{},[int]$TimeoutSeconds=1800,[string]$LogPath,[int[]]$AllowedExitCodes=@(0),
        [switch]$NoCapture,[switch]$KeepOnTimeout,[string]$OutputEncoding)
    if($TimeoutSeconds -lt 1){throw 'Process timeout must be positive.'}
    $resolved=(Get-Command -Name $FilePath -ErrorAction Stop).Source
    if([IO.Path]::GetExtension($resolved) -in @('.cmd','.bat')){throw 'Use an explicit, safely quoted command-shell invocation for batch files.'}
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$resolved
    $psi.Arguments=(@($Arguments|ForEach-Object {ConvertTo-WtgArgument $_}) -join ' ')
    if($WorkingDirectory){$psi.WorkingDirectory=$WorkingDirectory}
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=-not $NoCapture;$psi.RedirectStandardError=-not $NoCapture
    if($OutputEncoding -and -not $NoCapture){$psi.StandardOutputEncoding=[Text.Encoding]::GetEncoding($OutputEncoding);$psi.StandardErrorEncoding=$psi.StandardOutputEncoding}
    # Never pass ambient deployment credentials to compilers/installer helpers.
    foreach($name in @($psi.EnvironmentVariables.Keys)){
        if([string]$name -match '^(?i)(GH_|GITHUB_|GIT_|SSH_ASKPASS$|WT_|WTG_GIT_|CV_|QT_|QML_|GST_)' -or
            [string]$name -match '(?i)(TOKEN|PASSWORD|SECRET|API_KEY|PRIVATE_KEY)'){$psi.EnvironmentVariables.Remove([string]$name)}
    }
    foreach($key in $Environment.Keys){
        if($null -eq $Environment[$key]){$psi.EnvironmentVariables.Remove([string]$key)}
        else{$psi.EnvironmentVariables[[string]$key]=[string]$Environment[$key]}
    }
    # PowerShell 7 module paths are not usable by the inbox Windows engine.
    # Apply after explicit overrides, to this child only; keep the caller intact.
    $windowsPowerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if($resolved.Equals($windowsPowerShell,[StringComparison]::OrdinalIgnoreCase)){
        $psi.EnvironmentVariables['PSModulePath']=(Join-Path (Split-Path -Parent $windowsPowerShell) 'Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
    }
    $process=New-Object Diagnostics.Process;$process.StartInfo=$psi
    try {
        if(-not $process.Start()){throw 'Could not start the required tool.'}
        try{$process.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal}catch{}
        if(-not $NoCapture){$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()}
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while(-not $process.WaitForExit(500)){
            if([DateTime]::UtcNow -ge $deadline){
                if(-not $KeepOnTimeout){$process.Kill();$null=$process.WaitForExit(5000)}
                throw 'Tool timeout. Inspect the retained run before retrying; child operations may still be active.'
            }
        }
        $stdout='';$stderr=''
        if(-not $NoCapture){
            if(-not $out.Wait(5000) -or -not $err.Wait(5000)){throw 'Tool exited but inherited output remains open. Inspect the run before retrying.'}
            $stdout=Protect-WtgText $out.Result;$stderr=Protect-WtgText $err.Result
        }
        if($LogPath){Write-WtgDiagnostic -Path $LogPath -Text ($stdout+"`r`n"+$stderr)}
        $result=[pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdout;StdErr=$stderr}
        if($process.ExitCode -notin $AllowedExitCodes){
            $ex=New-Object InvalidOperationException ('Tool failed: '+[IO.Path]::GetFileName($resolved)+' (exit '+$process.ExitCode+').')
            $ex.Data['ExitCode']=$process.ExitCode
            throw $ex
        }
        return $result
    }finally{$process.Dispose()}
}
function Resolve-WtgSafeDirectory {
    param([Parameter(Mandatory=$true)][string]$Path,[string[]]$ForbiddenRoots=@(),[switch]$AllowExisting)
    if(-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or $Path -match '[\x00-\x1f]'){throw 'Use an absolute local directory.'}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if($full.Length -le [IO.Path]::GetPathRoot($full).TrimEnd('\').Length){throw 'A drive root is not a deployment directory.'}
    foreach($root in $ForbiddenRoots){
        if(-not $root){continue};$r=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
        if($full.Equals($r,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'This directory overlaps protected application or source data.'}
    }
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -LiteralPath $cursor -Force
            if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Deployment directories must be real local directories without reparse points.'}
        }
        $cursor=Split-Path -Parent $cursor
    }
    if(-not $AllowExisting -and (Test-Path -LiteralPath $full)){throw 'The run directory already exists; inspect its result before retrying.'}
    return $full
}
function Expand-WtgZip {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Destination,[long]$MaximumBytes=34359738368)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $dest=Resolve-WtgSafeDirectory -Path $Destination
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$total=0
        foreach($entry in $zip.Entries){
            $name=$entry.FullName.Replace('/','\')
            if($name -match '(^[\\/]|:|[\x00-\x1f]|(^|\\)\.\.(\\|$)|[ .](\\|$))'){throw 'Unsafe path in source archive.'}
            $leaf=[IO.Path]::GetFileNameWithoutExtension($name.TrimEnd('\'))
            if($leaf -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'){throw 'Reserved Windows path in archive.'}
            if(-not $names.Add($name)){throw 'Duplicate file path in source archive.'}
            $entryType=($entry.ExternalAttributes -shr 16) -band 0xf000
            if($entryType -eq 0xa000){throw 'Symbolic links are not permitted in source archives.'}
            $total+=$entry.Length;if($total -gt $MaximumBytes){throw 'Archive exceeds the extraction size limit.'}
            $target=[IO.Path]::GetFullPath((Join-Path $dest $name))
            if(-not $target.StartsWith($dest+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Archive path escapes its destination.'}
        }
        $null=New-Item -ItemType Directory -Path $dest
        foreach($entry in $zip.Entries){
            $name=$entry.FullName.Replace('/','\');$target=Join-Path $dest $name
            if($name.EndsWith('\')){$null=New-Item -ItemType Directory -Path $target -Force;continue}
            $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
        }
    }finally{$zip.Dispose()}
    return $dest
}
Export-ModuleMember -Function *-Wtg*

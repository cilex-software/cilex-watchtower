# Windows PowerShell 5.1. Inspection only: this module never writes files or runs a benchmark.
Set-StrictMode -Version 2.0

function Get-WtgRequirementText {
    param($Context,[string]$English,[string]$Russian)
    if ($Context.Language -eq 'ru') { return $Russian }; return $English
}
function New-WtgFinding {
    param([string]$Id,[string]$State,[string]$Message,[bool]$CanOverride=$false)
    [pscustomobject]@{Id=$Id;State=$State;Message=$Message;CanOverride=$CanOverride}
}
function Get-WtgRequirementValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } }
    elseif ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-WtgMachineFacts {
    $facts=@{IsWindows=($env:OS -eq 'Windows_NT');NativeArchitecture=$env:PROCESSOR_ARCHITECTURE;Process64=[Environment]::Is64BitProcess;OsBuild=$null;ProductType=$null;RamBytes=$null;AvailableRamBytes=$null;CpuCount=$null;Graphics=@();Volumes=@{};RebootPending=$null;Identity=$null;SessionId=$null;TaskService=$null;InstallAclReadable=$null;ProfilePresent=$null;ProxyConfigured=$null;MediaFoundationPresent=$null}
    if ($env:PROCESSOR_ARCHITEW6432) { $facts.NativeArchitecture=$env:PROCESSOR_ARCHITEW6432 }
    if (-not $facts.IsWindows) { return $facts }
    try { $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $facts.OsBuild=[int]$os.BuildNumber; $facts.ProductType=[int]$os.ProductType; $facts.AvailableRamBytes=[long]$os.FreePhysicalMemory*1024 } catch {}
    try { $cs=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $facts.RamBytes=[long]$cs.TotalPhysicalMemory; $facts.CpuCount=[int]$cs.NumberOfLogicalProcessors } catch {}
    try { $facts.Graphics=@(Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object Name,DriverVersion,ConfigManagerErrorCode) } catch {}
    try { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object { $facts.Volumes[($_.DeviceID+'\')]=[long]$_.FreeSpace } } catch {}
    try { $identity=[Security.Principal.WindowsIdentity]::GetCurrent(); $facts.Identity=$identity.Name; $facts.SessionId=(Get-Process -Id $PID).SessionId; $facts.ProfilePresent=Test-Path -LiteralPath ([Environment]::GetFolderPath('UserProfile')); $identity.Dispose() } catch {}
    try { $facts.TaskService=(Get-Service -Name Schedule -ErrorAction Stop).Status.ToString() } catch {}
    try {$facts.MediaFoundationPresent=(Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\mfplat.dll') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\mfreadwrite.dll') -PathType Leaf)}catch{}
    # Read the explicit WinINet proxy flag only; never fetch PAC files or expose proxy credentials.
    try {$proxyKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings');try{if($proxyKey){$facts.ProxyConfigured=([int]$proxyKey.GetValue('ProxyEnable',0) -ne 0)}}finally{if($proxyKey){$proxyKey.Dispose()}}}catch{}
    try {
        $pending=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        $sessionKey=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager')
        try { if ($sessionKey -and $sessionKey.GetValueNames() -contains 'PendingFileRenameOperations') { $pending=$true } } finally { if ($sessionKey) {$sessionKey.Dispose()} }
        $facts.RebootPending=$pending
    } catch {}
    return $facts
}
function Get-WtgDiskPlan {
    param($Context,[ValidateSet('Build','Target')][string]$Role='Build',$Manifest)
    $budget=$Manifest.diskBudgetGiB; $allocations=@()
    if ($Role -eq 'Build') {
        $allocations+=@{Path=$Context.CacheDir;Bytes=([long]$budget.downloads+[long]$budget.extractedTools)*1GB}
        $allocations+=@{Path=$Context.WorkDir;Bytes=([long]$budget.sourceAndBuild+[long]$budget.staging)*1GB}
        $allocations+=@{Path=$Context.OutputDir;Bytes=[long]$budget.installerOutput*1GB}
        $allocations+=@{Path=[IO.Path]::GetTempPath();Bytes=2GB}
    } else {
        $allocations+=@{Path=$Context.InstallDir;Bytes=([long]$budget.installedPayload+[long]$budget.rollback+[long]$budget.staging)*1GB}
        $allocations+=@{Path=[IO.Path]::GetTempPath();Bytes=2GB}
    }
    $volumes=@{}
    foreach ($allocation in $allocations) {
        if ([string]::IsNullOrWhiteSpace($allocation.Path)) { continue }
        try { $root=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($allocation.Path)); if (-not $volumes.ContainsKey($root)) { $volumes[$root]=[long]$budget.reservePerVolume*1GB }; $volumes[$root]+=$allocation.Bytes } catch {}
    }
    return $volumes
}
function Test-WtgReadOnlyEndpoint {
    param([string]$Url,[int]$TimeoutSeconds=5)
    # No authentication, query strings, proxy credentials or response bodies are logged.
    $request=$null; $response=$null
    try {
        $uri=[uri]$Url
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return 'InvalidAddress' }
        $request=[Net.HttpWebRequest]::Create($uri); $request.Method='HEAD'; $request.AllowAutoRedirect=$false; $request.Timeout=$TimeoutSeconds*1000; $request.ReadWriteTimeout=$TimeoutSeconds*1000
        $response=$request.GetResponse(); return ('HTTP '+[int]$response.StatusCode)
    } catch [Net.WebException] {
        if ($_.Exception.Response) { return ('HTTP '+[int]$_.Exception.Response.StatusCode) }
        switch ($_.Exception.Status.ToString()) { 'NameResolutionFailure' {return 'DNS'} 'ProxyNameResolutionFailure' {return 'Proxy'} 'TrustFailure' {return 'TLS'} 'SecureChannelFailure' {return 'TLS'} 'Timeout' {return 'Timeout'} default {return 'Unavailable'} }
    } catch { return 'Unknown' } finally { if ($response) {$response.Dispose()}; if ($request) {$request.Abort()} }
}
function Get-WtgRequirements {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[ValidateSet('Build','Target')][string]$Role='Build', $Facts=$null)
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'requirements.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $fixtureFacts=($null -ne $Facts)
    if ($null -eq $Facts) { $Facts=Get-WtgMachineFacts }
    $list=New-Object System.Collections.Generic.List[object]
    function Add-Finding($Id,$State,$En,$Ru,$Override=$false) { $list.Add((New-WtgFinding $Id $State (Get-WtgRequirementText $Context $En $Ru) $Override)) }
    if (-not $Facts.IsWindows) { Add-Finding 'platform.windows' 'BLOCKED' 'This package requires Windows x64. Use a supported Windows computer.' 'Для этого пакета требуется Windows x64. Используйте совместимый компьютер с Windows.'; return $list.ToArray() }
    if ($Facts.NativeArchitecture -ne 'AMD64') { Add-Finding 'platform.architecture' 'BLOCKED' 'This package requires native Windows x64. Other architectures are not supported by this package.' 'Этот пакет предназначен для Windows x64. Другие архитектуры этим пакетом не поддерживаются.' }
    else { Add-Finding 'platform.architecture' 'PASS' 'Windows x64 is available.' 'Windows x64 доступна.' }
    if (-not $Facts.Process64) { Add-Finding 'platform.shell' 'BLOCKED' 'Open 64-bit Windows PowerShell and run the script again.' 'Откройте 64-разрядную Windows PowerShell и запустите скрипт снова.' }
    $floor=$manifest.minimumRuntimeOsBuild; if ($Role -eq 'Build') {$floor=$manifest.minimumBuildOsBuild}
    if ($null -eq $Facts.OsBuild) { Add-Finding 'platform.os' 'UNKNOWN' 'The Windows version could not be checked. Verify it before continuing.' 'Не удалось проверить версию Windows. Проверьте её перед продолжением.' $true }
    elseif ($Facts.OsBuild -lt $floor) { Add-Finding 'platform.os' 'WARNING' ('Windows build '+$Facts.OsBuild+' is below '+$floor+'. Installation may fail; update Windows or explicitly accept this risk.') ('Сборка Windows '+$Facts.OsBuild+' ниже '+$floor+'. Установка может завершиться ошибкой; обновите Windows или подтвердите риск.') $true }
    else { Add-Finding 'platform.os' 'PASS' ('Windows build '+$Facts.OsBuild+' meets the dependency baseline; application compatibility still needs testing.') ('Сборка Windows '+$Facts.OsBuild+' соответствует требованиям библиотек; работу приложения необходимо проверить.') }
    if ($Facts.ProductType -ne 1) { Add-Finding 'platform.server' 'UNKNOWN' 'Windows Server has not been validated. Confirm target suitability before continuing.' 'Windows Server не проверена. Подтвердите пригодность компьютера перед продолжением.' $true }
    $media=Get-WtgRequirementValue $Facts 'MediaFoundationPresent'
    if($null -eq $media){Add-Finding 'platform.media' 'UNKNOWN' 'Windows media components could not be verified. Video playback needs a target test.' 'Не удалось проверить медиакомпоненты Windows. Воспроизведение нужно проверить на компьютере.' $true}
    elseif(-not $media){Add-Finding 'platform.media' 'WARNING' 'Required Windows media components are missing. On Windows N, install Media Feature Pack through Optional features; on other editions repair Windows. https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-n' 'Отсутствуют нужные медиакомпоненты Windows. Для Windows N установите Media Feature Pack через дополнительные компоненты; для других редакций восстановите Windows. https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-n' $true}
    else{Add-Finding 'platform.media' 'PASS' 'Required Windows media component files are present; playback still needs an application test.' 'Нужные файлы медиакомпонентов Windows присутствуют; воспроизведение нужно проверить в приложении.'}
    if ($Facts.OsBuild -and $Facts.OsBuild -lt 22000) { Add-Finding 'platform.lifecycle' 'UNKNOWN' 'Windows 10 update entitlement and security-support status are unverified. Check your edition and support agreement.' 'Право на обновления и поддержка Windows 10 не проверены. Проверьте редакцию и условия поддержки.' $true }
    $capacity=$manifest.($Role.ToLowerInvariant())
    foreach ($item in @(@('memory.installed','RamBytes','physicalRamGiB'),@('memory.available','AvailableRamBytes','availableRamGiB'))) {
        $value=Get-WtgRequirementValue $Facts $item[1]; $required=[long]$capacity.($item[2])*1GB
        if ($null -eq $value) { Add-Finding $item[0] 'UNKNOWN' 'Memory could not be checked. Verify available memory before continuing.' 'Не удалось проверить память. Проверьте доступную память перед продолжением.' $true }
        elseif ($value -lt $required) { Add-Finding $item[0] 'WARNING' ('Memory: '+[Math]::Round($value/1GB,1)+' GiB; provisional '+$Role.ToLower()+' budget: '+($required/1GB)+' GiB. Free memory or explicitly continue.') ('Память: '+[Math]::Round($value/1GB,1)+' ГиБ; предварительный ориентир: '+($required/1GB)+' ГиБ. Освободите память или подтвердите продолжение.') $true }
        else { Add-Finding $item[0] 'PASS' ('Memory meets the provisional '+$Role.ToLowerInvariant()+' budget.') 'Память соответствует предварительному ориентиру.' }
    }
    if ($null -eq $Facts.CpuCount) { Add-Finding 'cpu.capacity' 'UNKNOWN' 'Processor capacity could not be checked.' 'Не удалось проверить процессор.' $true }
    elseif ($Facts.CpuCount -lt $capacity.logicalProcessors) { Add-Finding 'cpu.capacity' 'WARNING' ('Only '+$Facts.CpuCount+' logical processors are available. Work may be slow; the capacity budget is provisional.') ('Доступно логических процессоров: '+$Facts.CpuCount+'. Работа может быть медленной; ориентир предварительный.') $true }
    else { Add-Finding 'cpu.capacity' 'PASS' 'Processor count meets the provisional capacity budget.' 'Число процессоров соответствует предварительному ориентиру.' }
    Add-Finding 'capacity.validation' 'UNKNOWN' 'Hardware thresholds are provisional. Camera workload and CPU instruction compatibility require application tests.' 'Требования к оборудованию предварительные. Нагрузку камер и совместимость процессора нужно проверить в приложении.' $true
    $plan=Get-WtgDiskPlan $Context $Role $manifest
    foreach ($volume in @($plan.Keys | Sort-Object)) {
        $free=$null; if ($Facts.Volumes.ContainsKey($volume)) {$free=$Facts.Volumes[$volume]}
        if ($null -eq $free) { Add-Finding ('disk.'+$volume.TrimEnd('\').Replace(':','')) 'UNKNOWN' ('Free space on '+$volume+' could not be checked. Verify this volume before continuing.') ('Не удалось проверить свободное место на '+$volume+'. Проверьте диск перед продолжением.') $true }
        elseif ($free -lt $plan[$volume]) { Add-Finding ('disk.'+$volume.TrimEnd('\').Replace(':','')) 'WARNING' ($volume+' has '+[Math]::Round($free/1GB,1)+' GiB free; provisional peak budget is '+[Math]::Round($plan[$volume]/1GB,1)+' GiB including backups. Free space or change paths.') ($volume+': свободно '+[Math]::Round($free/1GB,1)+' ГиБ; предварительный пик с резервной копией '+[Math]::Round($plan[$volume]/1GB,1)+' ГиБ. Освободите место или измените пути.') $true }
        else { Add-Finding ('disk.'+$volume.TrimEnd('\').Replace(':','')) 'PASS' ($volume+' has space for the provisional peak budget. Actual sizes will be checked before writing.') ($volume+': места достаточно для предварительного бюджета. Реальные размеры будут проверены перед записью.') }
    }
    if ($null -eq $Facts.RebootPending) { Add-Finding 'system.restart' 'UNKNOWN' 'Pending Windows restart status could not be checked.' 'Не удалось проверить необходимость перезапуска Windows.' $true }
    elseif ($Facts.RebootPending) { Add-Finding 'system.restart' 'WARNING' 'Windows has pending restart operations. Dependencies may require a user-controlled restart.' 'Windows ожидает перезапуска. Для библиотек может потребоваться перезапуск по вашему решению.' $true }
    else { Add-Finding 'system.restart' 'PASS' 'No checked Windows restart indicator is present.' 'Проверенные признаки необходимости перезапуска Windows отсутствуют.' }
    if ($Role -eq 'Target') {
        if (@($Facts.Graphics).Count -eq 0) { Add-Finding 'graphics.adapter' 'UNKNOWN' 'No graphics adapter could be inspected. Rendering needs a target test.' 'Не удалось проверить видеокарту. Отображение нужно проверить на компьютере.' $true }
        elseif (@($Facts.Graphics | Where-Object {$_.ConfigManagerErrorCode -ne 0}).Count) { Add-Finding 'graphics.adapter' 'WARNING' 'Windows reports a graphics-device problem. Check its driver or explicitly continue.' 'Windows сообщает о проблеме видеоустройства. Проверьте драйвер или подтвердите продолжение.' $true }
        else { Add-Finding 'graphics.adapter' 'UNKNOWN' 'A graphics adapter is present; rendering and video decoding are not yet verified.' 'Видеокарта обнаружена; отображение и декодирование видео ещё не проверены.' $true }
        if ($Facts.TaskService -eq 'Running') { Add-Finding 'startup.scheduler' 'PASS' 'Windows Task Scheduler is running.' 'Планировщик заданий Windows работает.' }
        else { Add-Finding 'startup.scheduler' 'BLOCKED' 'Task Scheduler is unavailable. Ask the Windows administrator to restore it.' 'Планировщик заданий недоступен. Обратитесь к администратору Windows.' }
        $target=Get-WtgRequirementValue $Context 'TargetUser' ''
        if ($Facts.SessionId -eq 0 -or ($target -and $target -ine $Facts.Identity)) { Add-Finding 'desktop.identity' 'UNKNOWN' 'The intended user desktop is not the inspecting session. Verify that account and its profile on the target.' 'Рабочий стол нужного пользователя не совпадает с текущим сеансом. Проверьте учётную запись и профиль.' $true }
        else { Add-Finding 'desktop.identity' 'PASS' 'Inspection is running in the current user desktop session.' 'Проверка выполняется в текущем пользовательском сеансе.' }
        if (-not $fixtureFacts) {
            try {
                $nearest=[IO.Path]::GetFullPath($Context.InstallDir)
                while ($nearest -and -not (Test-Path -LiteralPath $nearest)) {$nearest=Split-Path -Parent $nearest}
                if ($nearest) {
                    $null=Get-Acl -LiteralPath $nearest -ErrorAction Stop
                    Add-Finding 'permissions.directory' 'UNKNOWN' 'The destination permissions are readable. Effective write access will be checked during setup.' 'Права папки назначения доступны для проверки. Фактическая запись будет проверена при установке.' $true
                } else {Add-Finding 'permissions.directory' 'UNKNOWN' 'The destination volume is unavailable. Connect it or choose another path.' 'Диск назначения недоступен. Подключите его или выберите другой путь.' $true}
            } catch {Add-Finding 'permissions.directory' 'UNKNOWN' 'The destination permissions could not be inspected. Verify access before installation.' 'Не удалось проверить права папки назначения. Проверьте доступ перед установкой.' $true}
            $profile=Get-WtgRequirementValue $Facts 'ProfilePresent'
            if ($target -and $target -ine $Facts.Identity) {Add-Finding 'desktop.profile' 'UNKNOWN' 'The target account profile will be checked on that user account during installation.' 'Профиль целевой учётной записи будет проверен при установке для этого пользователя.' $true}
            elseif ($profile -eq $true) {Add-Finding 'desktop.profile' 'PASS' 'The current desktop user profile exists.' 'Профиль текущего пользователя существует.'}
            else {Add-Finding 'desktop.profile' 'UNKNOWN' 'The intended desktop profile could not be verified. Sign in with the intended account first.' 'Не удалось проверить профиль рабочего стола. Сначала войдите в нужную учётную запись.' $true}
        }
        Add-Finding 'permissions.install' 'UNKNOWN' 'Installation and task permissions will be verified during setup; read-only inspection cannot prove write access.' 'Права на установку и задания будут проверены при настройке; проверка без изменений не подтверждает запись.' $true
    }
    $offline=(Get-WtgRequirementValue $Context 'DependencyMode' 'Auto') -eq 'Offline'
    $proxy=Get-WtgRequirementValue $Facts 'ProxyConfigured'
    if($null -ne $proxy) {if($proxy){Add-Finding 'network.proxy' 'UNKNOWN' 'Windows has a proxy configured. Dependency downloads will use the existing proxy; access is unverified.' 'В Windows настроен прокси. Загрузки будут использовать текущие настройки; доступ не проверен.' $true}else{Add-Finding 'network.proxy' 'PASS' 'No explicit Windows user proxy is enabled; automatic proxy rules may still apply.' 'Явный пользовательский прокси Windows выключен; автоматические правила могут применяться.'}}
    $skip=Get-WtgRequirementValue $Context 'SkipNetworkChecks' $false
    if ($offline -or $skip) { Add-Finding 'network.check' 'UNKNOWN' 'Network checks were skipped. No connection is assumed.' 'Сетевые проверки пропущены. Подключение не подтверждено.' $true }
    else {
        $endpoints=@(); if ($Role -eq 'Build') {$endpoints+=@{Id='network.repository';Url='https://github.com/'}; $endpoints+=@{Id='network.dependencies';Url='https://download.qt.io/'}}
        $backend=Get-WtgRequirementValue $Context 'BackendUrl' ''; if ($backend) {$endpoints+=@{Id='network.backend';Url=$backend}}
        foreach ($endpoint in $endpoints) {
            $status=Test-WtgReadOnlyEndpoint $endpoint.Url
            if ($status -match '^HTTP (2|3)') { Add-Finding $endpoint.Id 'PASS' 'The endpoint responds; credentials and application access are checked separately.' 'Сервер отвечает; учётные данные и доступ приложения проверяются отдельно.' }
            else { Add-Finding $endpoint.Id 'UNKNOWN' ('Endpoint check: '+$status+'. Check the address, connection or access; this does not prove general internet failure.') ('Проверка сервера: '+$status+'. Проверьте адрес, подключение и доступ; это не означает отсутствие всего интернета.') $true }
        }
    }
    return $list.ToArray()
}
function RoleLabel($Role) { return $Role.ToLowerInvariant() }
Export-ModuleMember -Function Get-WtgRequirements,Get-WtgMachineFacts,Get-WtgDiskPlan,Test-WtgReadOnlyEndpoint

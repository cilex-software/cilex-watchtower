#requires -Version 5.1
# Exercise only the guard-definition function with disposable files and
# in-memory ScheduledTasks capabilities. The updater entry point never runs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$script:checks = 0

function Assert($Value, [string]$Label) {
    if (-not $Value) {
        throw ('FAIL: ' + $Label)
    }
    $script:checks++
}

$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\station-booth.ps1'))
$tokens = $null
$errors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) {
    throw 'Booth updater syntax invalid'
}
$functions = @($tree.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false))
$definition = @($functions | Where-Object Name -eq 'Assert-Guard-Definition')
if ($definition.Count -ne 1) {
    throw 'Guard function missing or ambiguous'
}

$enumName = 'Microsoft.PowerShell.Cmdletization.GeneratedTypes.ScheduledTask.RunLevelEnum'
if (-not ($enumName -as [type])) {
    Add-Type -TypeDefinition @'
namespace Microsoft.PowerShell.Cmdletization.GeneratedTypes.ScheduledTask {
    public enum RunLevelEnum { Limited = 0, Highest = 1 }
}
'@
}
if (-not ('FixtureWrongGuardLevel' -as [type])) {
    Add-Type -TypeDefinition 'public enum FixtureWrongGuardLevel { Limited = 0, Highest = 1 }'
}
$script:runLevelType = $enumName -as [type]

$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wt-booth-guard-' + [Guid]::NewGuid().ToString('N'))))
[IO.Directory]::CreateDirectory($root) | Out-Null
$watchdog = Join-Path $root 'wall-watchdog.ps1'
$script:module = New-Module -ScriptBlock ([scriptblock]::Create($definition[0].Extent.Text + "`nExport-ModuleMember -Function Assert-Guard-Definition"))

try {
    & $module {
        param($Root, $Watchdog)

        $script:fixtureRoot = $Root
        $script:watchdogPath = $Watchdog
        $script:taskPath = '\'
        $script:taskName = 'fixture-guard'
        $script:expectedSID = 'S-1-5-21-1-2-3-1001'
        $script:mutations = New-Object Collections.Generic.List[string]

        function script:Get-ScheduledTask {
            param($TaskPath, $TaskName)

            if ($TaskPath -cne '\' -or $TaskName -cne 'fixture-guard') {
                throw 'FIXTURE_UNEXPECTED_TASK_READ'
            }
            return $script:state.Task
        }

        function script:Export-ScheduledTask {
            param($InputObject)

            if (-not [object]::ReferenceEquals($InputObject, $script:state.Task)) {
                throw 'FIXTURE_UNEXPECTED_TASK_EXPORT'
            }
            return $script:state.Xml
        }

        function script:Hash {
            param($Path)

            if ($Path -cne $script:watchdogPath) {
                throw 'FIXTURE_UNEXPECTED_FILE_READ'
            }
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }

        foreach ($name in @(
            'Disable-ScheduledTask',
            'Enable-ScheduledTask',
            'Stop-ScheduledTask',
            'Start-ScheduledTask',
            'Register-ScheduledTask',
            'Stop-Process',
            'Start-Process',
            'Set-ExecutionPolicy'
        )) {
            $body = [scriptblock]::Create(
                '$script:mutations.Add("' + $name + '")' + [Environment]::NewLine +
                'throw "FIXTURE_MUTATION_FORBIDDEN"'
            )
            Set-Item -Path ('Function:script:' + $name) -Value $body
        }
    } $root $watchdog

    function Xml(
        [string]$Level = '',
        [string]$User = 'S-1-5-21-1-2-3-1001',
        [string]$Logon = 'InteractiveToken',
        [string]$ExtraPrincipal = '',
        [string]$Namespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
    ) {
        return (
            '<Task xmlns="' + $Namespace + '"><Principals><Principal id="Author"><UserId>' +
            $User + '</UserId><LogonType>' + $Logon + '</LogonType>' + $Level +
            '</Principal>' + $ExtraPrincipal + '</Principals></Task>'
        )
    }

    function Reset {
        [IO.File]::WriteAllText($watchdog, '# disposable guard; never executed')
        $action = [pscustomobject]@{
            Execute = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            Arguments = '-NoProfile -File "C:\fixture\wall-watchdog.ps1"'
            WorkingDirectory = 'C:\fixture'
        }
        $task = [pscustomobject]@{
            Principal = [pscustomobject]@{
                RunLevel = [Enum]::Parse($script:runLevelType, 'Limited')
            }
            Actions = @($action.PSObject.Copy())
            Settings = [pscustomobject]@{
                Enabled = $true
            }
            State = 'Running'
        }
        $state = [pscustomobject]@{
            Task = $task
            Xml = (Xml)
        }

        & $module {
            param($State, $Action, $Hash)

            $script:state = $State
            $script:guardBefore = [pscustomobject]@{
                Actions = @($Action)
            }
            $script:runtime = [pscustomobject]@{
                Installed = [pscustomobject]@{
                    WatchdogSHA256 = $Hash
                }
            }
            $script:mutations.Clear()
        } $state $action ((Get-FileHash -LiteralPath $watchdog -Algorithm SHA256).Hash)

        return $state
    }

    function Accept([string]$Name, $State) {
        $result = & $script:module { Assert-Guard-Definition }
        Assert ([object]::ReferenceEquals($result, $State.Task)) ($Name + ': exact task returned')
        Assert ((& $script:module { $script:mutations.Count }) -eq 0) ($Name + ': no mutation')
    }

    function Refuse([string]$Name) {
        $failure = $null
        try {
            $null = & $script:module { Assert-Guard-Definition }
        }
        catch {
            $failure = $_
        }
        Assert ($null -ne $failure -and $failure.Exception.Message -notmatch '^FIXTURE_') ($Name + ': rejected by guard validation')
        Assert ((& $script:module { $script:mutations.Count }) -eq 0) ($Name + ': rejected before mutation')
    }

    $state = Reset
    Accept 'omitted schema default with typed API Limited' $state

    $state = Reset
    $state.Xml = Xml '<RunLevel>LeastPrivilege</RunLevel>'
    Accept 'explicit least privilege with API agreement' $state

    $state = Reset
    $state.Task.State = 'Disabled'
    $state.Task.Settings.Enabled = $false
    Accept 'omitted default remains valid during owned temporary disable' $state

    foreach ($case in @(
        @('explicit highest', '<RunLevel>HighestAvailable</RunLevel>'),
        @('empty run level', '<RunLevel/>'),
        @('unknown run level', '<RunLevel>Limited</RunLevel>'),
        @('whitespace run level', '<RunLevel> </RunLevel>'),
        @('duplicate identical levels', '<RunLevel>LeastPrivilege</RunLevel><RunLevel>LeastPrivilege</RunLevel>'),
        @('duplicate contradictory levels', '<RunLevel>LeastPrivilege</RunLevel><RunLevel>HighestAvailable</RunLevel>'),
        @('foreign namespaced level', '<x:RunLevel xmlns:x="urn:foreign">HighestAvailable</x:RunLevel>'),
        @('level with unexpected attribute', '<RunLevel other="bad">LeastPrivilege</RunLevel>'),
        @('nested run level content', '<RunLevel><Value>LeastPrivilege</Value></RunLevel>')
    )) {
        $state = Reset
        $state.Xml = Xml $case[1]
        Refuse $case[0]
    }

    foreach ($explicit in @($false, $true)) {
        $state = Reset
        $state.Task.Principal.RunLevel = [Enum]::Parse($runLevelType, 'Highest')
        if ($explicit) {
            $state.Xml = Xml '<RunLevel>LeastPrivilege</RunLevel>'
        }
        Refuse ('API highest contradicts XML/default: ' + $explicit)
    }

    foreach ($value in @(
        'Limited',
        0,
        1,
        [FixtureWrongGuardLevel]::Limited,
        [Enum]::ToObject($runLevelType, 999)
    )) {
        $state = Reset
        $state.Task.Principal.RunLevel = $value
        Refuse ('API level is not the defined typed Limited: ' + $value.GetType().Name)
    }

    $state = Reset
    $state.Task.Principal.RunLevel = $null
    Refuse 'API null level'

    $state = Reset
    $state.Task.Principal = [pscustomobject]@{}
    Refuse 'API missing level'

    $state = Reset
    $state.Task.Principal = @($state.Task.Principal, $state.Task.Principal.PSObject.Copy())
    Refuse 'API ambiguous principal'

    $state = Reset
    $state.Xml = Xml '' 'S-1-5-21-1-2-3-1001' 'InteractiveToken' '<Principal id="Second"><UserId>S-1-5-21-1-2-3-1001</UserId><LogonType>InteractiveToken</LogonType></Principal>'
    Refuse 'duplicate principal'

    $state = Reset
    $state.Xml = '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals/></Task>'
    Refuse 'absent principal'

    $state = Reset
    $state.Xml = Xml '' 'S-1-5-21-1-2-3-1001' 'InteractiveToken' '' 'urn:foreign'
    Refuse 'wrong task namespace'

    $state = Reset
    $state.Xml = Xml '' 'S-1-5-21-9-8-7-1001'
    Refuse 'foreign owner still refused'

    $state = Reset
    $state.Xml = Xml '' 'S-1-5-21-1-2-3-1001' 'Password'
    Refuse 'noninteractive logon still refused'

    $state = Reset
    $state.Task.Actions[0].Execute = 'C:\other\powershell.exe'
    Refuse 'changed executable still refused'

    $state = Reset
    $state.Task.Actions[0].Arguments = '-File C:\other\guard.ps1'
    Refuse 'changed arguments still refused'

    $state = Reset
    $state.Task.Actions[0].WorkingDirectory = 'C:\other'
    Refuse 'changed working directory still refused'

    $state = Reset
    $state.Task.Actions = @($state.Task.Actions[0], $state.Task.Actions[0].PSObject.Copy())
    Refuse 'multiple actions still refused'

    $state = Reset
    $state.Task.Actions = @()
    Refuse 'missing action still refused'

    $state = Reset
    [IO.File]::WriteAllText($watchdog, '# changed disposable guard')
    Refuse 'changed guard content still refused'

    # Pin admission ahead of the actual entry's task/process stop commands,
    # independently of these function-only fixtures. Entry code is not run.
    $lastFunctionEnd = ($functions | ForEach-Object { $_.Extent.EndOffset } | Measure-Object -Maximum).Maximum
    $entryCommands = @($tree.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.Extent.StartOffset -gt $lastFunctionEnd
    }, $true))
    $admission = @($entryCommands |
        Where-Object { $_.GetCommandName() -eq 'Assert-Guard-Definition' } |
        Sort-Object { $_.Extent.StartOffset })
    $mutators = @($entryCommands |
        Where-Object { $_.GetCommandName() -in @('Disable-ScheduledTask', 'Stop-Record', 'Stop-Supervised-Scope') } |
        Sort-Object { $_.Extent.StartOffset })
    Assert (
        $admission.Count -gt 0 -and
        $mutators.Count -gt 0 -and
        $admission[0].Extent.StartOffset -lt $mutators[0].Extent.StartOffset
    ) 'entry validates exact guard before first task/process mutation'

    Write-Output ('Booth guard definition: ' + $script:checks + ' checks passed. Only disposable files and in-memory Windows capabilities were used.')
}
finally {
    Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($root)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (
        -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^wt-booth-guard-[0-9a-f]{32}$'
    ) {
        throw 'Disposable guard cleanup target unsafe'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

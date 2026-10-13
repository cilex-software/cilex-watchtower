#requires -Version 5.1
param([string]$WorkRoot=(Join-Path ([IO.Path]::GetTempPath()) ('cilex-source-test-'+[Guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Common.psm1') -Force
Import-Module (Join-Path $root 'Source.psm1') -Force
$passed=0
function Assert($Name,$Condition){if(-not $Condition){throw ('FAILED: '+$Name)};$script:passed++}
function Refuses($Name,[scriptblock]$Action){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};Assert $Name $refused}
$null=New-Item -ItemType Directory -Path $WorkRoot
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$git=(Get-Command git.exe).Source
$ctx=[pscustomobject]@{Repository='https://github.com/example/private.git';RunDir=$WorkRoot;Tools=@{Git=$git};Tag='';DependencyMode='Offline';Language='en'}
Assert 'English fallback' ((Get-WtgLanguage en) -eq 'en')
Assert 'Russian message present' ((Get-WtgMessage Checking -Language ru) -ne (Get-WtgMessage Checking -Language en))
Assert 'empty argument quoted' ((ConvertTo-WtgArgument '') -eq '""')
Assert 'terminal backslash doubled' ((ConvertTo-WtgArgument 'a b\') -eq '"a b\\"')
Refuses 'multiline argument rejected' {ConvertTo-WtgArgument "first`nsecond"}
Refuses 'credential URL rejected' {Assert-WtgRepository 'https://user:secret@github.com/a/b.git'}
Refuses 'query token URL rejected' {Assert-WtgRepository 'https://github.com/a/b.git?token=x'}
Refuses 'shell protocol rejected' {Assert-WtgRepository 'ext::whatever'}
Refuses 'drive root rejected' {Resolve-WtgSafeDirectory 'C:\'}
Refuses 'protected descendant rejected' {Resolve-WtgSafeDirectory (Join-Path $WorkRoot 'x') -ForbiddenRoots @($WorkRoot)}
$jsonPath=Join-Path $WorkRoot 'result.json'
Write-WtgJson $jsonPath @{state='first'};Write-WtgJson $jsonPath @{state='second'}
Assert 'atomic JSON replacement' ((Get-Content -LiteralPath $jsonPath -Raw|ConvertFrom-Json).state -eq 'second')
Register-WtgSecret 'disposable-unit-credential'
Assert 'explicit secret redacted' ((Protect-WtgText 'a disposable-unit-credential b') -eq 'a [REDACTED] b')
Unregister-WtgSecret 'disposable-unit-credential'
Assert 'PAT redaction' ((Protect-WtgText 'ghp_abcdefghijklmnopqrstuvwxyz012345') -eq '[REDACTED]')
$boundedLog=Join-Path $WorkRoot 'bounded.log'
Write-WtgDiagnostic $boundedLog ('START'+('x'*4096)+'END') -MaximumCharacters 1024
$bounded=[IO.File]::ReadAllText($boundedLog)
Assert 'diagnostic size bounded with useful ends' ($bounded.Length -le 1024 -and $bounded.StartsWith('START') -and $bounded.EndsWith('END') -and $bounded.Contains('middle output omitted'))
$probe=Join-Path $WorkRoot 'arguments.ps1'
[IO.File]::WriteAllText($probe,'param([string]$Value) [Console]::WriteLine($Value)',[Text.Encoding]::ASCII)
$value='with spaces "quoted" and trailing\'
$p=Invoke-WtgProcess -FilePath $ps -Arguments @('-NoProfile','-NonInteractive','-File',$probe,'-Value',$value)
Assert 'native argument roundtrip' ($p.StdOut.Trim() -eq $value)

$envProbe=Join-Path $WorkRoot 'env.ps1'
[IO.File]::WriteAllText($envProbe,'[Console]::WriteLine([string]::IsNullOrEmpty($env:WTG_TEST_SECRET));[Console]::WriteLine([string]::IsNullOrEmpty($env:GIT_DIR));[Console]::WriteLine($env:SAFE_BUILD_FLAG)',[Text.Encoding]::ASCII)
$savedSecret=$env:WTG_TEST_SECRET;$savedGit=$env:GIT_DIR
try{
    $env:WTG_TEST_SECRET='disposable-test';$env:GIT_DIR='not-a-repository'
    $p=Invoke-WtgProcess -FilePath $ps -Arguments @('-NoProfile','-NonInteractive','-File',$envProbe) -Environment @{SAFE_BUILD_FLAG='ok'}
    Assert 'ambient credentials and Git hook variables removed' ($p.StdOut.Trim() -eq "True`r`nTrue`r`nok")
}finally{$env:WTG_TEST_SECRET=$savedSecret;$env:GIT_DIR=$savedGit}

# A PS7 parent or compiler environment must not hide the native PS5 modules.
$moduleProbe=Join-Path $WorkRoot 'native-modules.ps1'
[IO.File]::WriteAllText($moduleProbe,'$ErrorActionPreference="Stop";[Console]::WriteLine($PSVersionTable.PSEdition);[Console]::WriteLine((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash);[Console]::WriteLine($env:PSModulePath)',[Text.Encoding]::ASCII)
$probeHash=Get-WtgSha256 $moduleProbe
$nativeModulePath=(Join-Path (Split-Path -Parent $ps) 'Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
$savedModulePath=$env:PSModulePath
$wrongModulePath=Join-Path $WorkRoot 'wrong-engine-modules'
try{
    $env:PSModulePath=$wrongModulePath
    foreach($explicit in @($false,$true)){
        $overrides=@{};if($explicit){$overrides.PSModulePath=$wrongModulePath+'-explicit'}
        $p=Invoke-WtgProcess -FilePath $ps -Arguments @('-NoProfile','-NonInteractive','-File',$moduleProbe) -Environment $overrides
        $lines=@($p.StdOut.Trim() -split '\r?\n')
        Assert ('native hashing survives wrong module path, explicit='+$explicit) ($lines[0] -eq 'Desktop' -and $lines[1] -eq $probeHash -and $lines[2] -eq $nativeModulePath)
        Assert ('parent module path unchanged, explicit='+$explicit) ($env:PSModulePath -eq $wrongModulePath)
    }
}finally{$env:PSModulePath=$savedModulePath}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$bad=Join-Path $WorkRoot 'bad.zip'
$zip=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Create)
try{$null=$zip.CreateEntry('../escape.txt')}finally{$zip.Dispose()}
Refuses 'archive traversal rejected before extraction' {Expand-WtgZip $bad (Join-Path $WorkRoot 'unsafe')}
Assert 'archive did not create unsafe output' (-not (Test-Path -LiteralPath (Join-Path $WorkRoot 'unsafe')))
$duplicates=Join-Path $WorkRoot 'duplicates.zip'
$zip=[IO.Compression.ZipFile]::Open($duplicates,[IO.Compression.ZipArchiveMode]::Create)
try{$null=$zip.CreateEntry('A.txt');$null=$zip.CreateEntry('a.txt')}finally{$zip.Dispose()}
Refuses 'Windows duplicate paths rejected' {Expand-WtgZip $duplicates (Join-Path $WorkRoot 'duplicates')}

# Local repository fixture; commands are isolated from inherited Git hook variables.
$fixture=Join-Path $WorkRoot 'fixture';$null=New-Item -ItemType Directory -Path $fixture
function Git([string[]]$A){Invoke-WtgProcess $git (@('-c','core.hooksPath=NUL')+$A) -WorkingDirectory $WorkRoot}
$null=Git @('init','--quiet',$fixture)
[IO.File]::WriteAllText((Join-Path $fixture 'CMakeLists.txt'),"project(watchtower VERSION 9.8.7 LANGUAGES CXX)`n",[Text.Encoding]::ASCII)
$null=Git @('-C',$fixture,'add','CMakeLists.txt')
$null=Git @('-C',$fixture,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','fixture')
$sha=(Git @('-C',$fixture,'rev-parse','HEAD')).StdOut.Trim()
$run=Join-Path $WorkRoot 'source-run';$null=New-Item -ItemType Directory -Path $run;$ctx.RunDir=$run
$record=Get-WtgSource -Context $ctx -SourceDirectory $fixture -SourceCommit $sha
Assert 'supplied source exact commit' ($record.Commit -eq $sha)
Assert 'source version parsed' ($record.Version -eq '9.8.7')
Assert 'offline source never called latest main' (-not $record.FetchedMain -and $record.Offline)
Assert 'source checkout is detached' ((Git @('-C',$record.Path,'rev-parse','--abbrev-ref','HEAD')).StdOut.Trim() -eq 'HEAD')
$run=Join-Path $WorkRoot 'dirty-run';$null=New-Item -ItemType Directory -Path $run;$ctx.RunDir=$run
[IO.File]::WriteAllText((Join-Path $fixture 'user-note.txt'),'retain me',[Text.Encoding]::ASCII)
Refuses 'dirty source refused' {Get-WtgSource -Context $ctx -SourceDirectory $fixture -SourceCommit $sha}
Assert 'user file preserved' ([IO.File]::ReadAllText((Join-Path $fixture 'user-note.txt')) -eq 'retain me')
Assert 'fixture HEAD preserved' ((Git @('-C',$fixture,'rev-parse','HEAD')).StdOut.Trim() -eq $sha)
$run=Join-Path $WorkRoot 'no-source';$null=New-Item -ItemType Directory -Path $run;$ctx.RunDir=$run
Refuses 'offline main refuses network fallback' {Get-WtgSource -Context $ctx}
Refuses 'bundle requires trusted hash' {Get-WtgSource -Context $ctx -SourceBundle 'missing.bundle' -SourceCommit $sha}

# Exercise the actual protected pipe with a disposable value, never network access.
$run=Join-Path $WorkRoot 'credential-run';$null=New-Item -ItemType Directory -Path $run;$ctx.RunDir=$run
$secure=ConvertTo-SecureString 'unit-test-credential-not-valid-anywhere' -AsPlainText -Force
$session=New-WtgGitSession $ctx $secure
try{
    $client=Join-Path $root 'git-askpass.ps1'
    $probeResult=Invoke-WtgProcess -FilePath $ps -Arguments @('-NoProfile','-NonInteractive','-File',$client,"Username for 'https://github.com/example/private.git':") -Environment $session.Environment
    Assert 'broker returns username' ($probeResult.StdOut.Trim() -eq 'x-access-token')
    $probeResult=Invoke-WtgProcess -FilePath $ps -Arguments @('-NoProfile','-NonInteractive','-File',$client,"Password for 'https://x-access-token@github.com/example/private.git':") -Environment $session.Environment
    Assert 'broker supplies disposable password' ($probeResult.StdOut.Trim() -eq 'unit-test-credential-not-valid-anywhere')
    Refuses 'broker refuses different host' {Invoke-WtgProcess -FilePath $ps -Arguments @('-NoProfile','-NonInteractive','-File',$client,"Password for 'https://evil.invalid/example/private.git':") -Environment $session.Environment}
    $saved=Get-ChildItem -LiteralPath $run -File -Recurse|ForEach-Object {[IO.File]::ReadAllText($_.FullName)}
    Assert 'no credential persisted' (-not (($saved -join '') -match 'unit-test-credential-not-valid-anywhere'))
}finally{$session.Broker.Dispose();$secure.Dispose()}

# Exercise the real source/authentication flow with fake Git responses only.
# No network requests, credential store access or user prompts occur in this fixture.
$authResults=& (Get-Module Source) {
    param($FixtureRoot)
    function script:New-WtgGitSession {
        param($Context,[Security.SecureString]$GhToken)
        return [pscustomobject]@{Environment=@{};Broker=$null;HasToken=[bool]$GhToken}
    }
    function script:Read-Host {
        param([string]$Prompt,[switch]$AsSecureString)
        if(-not $AsSecureString){throw 'Credential fixture expected hidden input.'}
        $script:authPrompts++
        $script:lastAuthPrompt=$Prompt
        return (ConvertTo-SecureString 'disposable-auth-fixture-value' -AsPlainText -Force)
    }
    function script:Invoke-WtgProcess {
        param($FilePath,$Arguments,$Environment,$WorkingDirectory,$TimeoutSeconds,$LogPath,$AllowedExitCodes)
        $label=[IO.Path]::GetFileNameWithoutExtension($LogPath)
        if($label -eq 'source-init'){
            $source=Join-Path $WorkingDirectory 'source';[IO.Directory]::CreateDirectory($source)|Out-Null
            [IO.File]::WriteAllText((Join-Path $source 'CMakeLists.txt'),'project(watchtower VERSION 9.8.7 LANGUAGES CXX)')
        }
        if($label -like 'source-fetch*'){
            $script:authFetches++
            $diagnostic=switch($script:authScenario){
                'denied' {if($script:authFetches -eq 1){'fatal: could not read Username: terminal prompts disabled'}}
                'hidden' {if($script:authFetches -eq 1){'remote: Repository not found.'}}
                'always-denied' {'fatal: Authentication failed'}
                'missing-tag' {"fatal: couldn't find remote ref refs/tags/missing"}
                'network' {'fatal: Could not resolve host: github.com'}
            }
            if($diagnostic){[IO.File]::WriteAllText($LogPath,$diagnostic);throw 'Git fixture exit 128'}
        }
        return [pscustomobject]@{ExitCode=0;StdOut=$(if($label -eq 'source-revision'){'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}else{''});StdErr=''}
    }
    foreach($case in @(
        @{Name='existing credentials';Scenario='ok';NonInteractive=$false;Token=$false;Success=$true;Prompts=0;Fetches=1;Language='en'},
        @{Name='missing credentials';Scenario='denied';NonInteractive=$false;Token=$false;Success=$true;Prompts=1;Fetches=2;Language='en'},
        @{Name='hidden private repository';Scenario='hidden';NonInteractive=$false;Token=$false;Success=$true;Prompts=1;Fetches=2;Language='ru'},
        @{Name='one failed token retry';Scenario='always-denied';NonInteractive=$false;Token=$false;Success=$false;Prompts=1;Fetches=2;Language='en'},
        @{Name='supplied token denied';Scenario='always-denied';NonInteractive=$false;Token=$true;Success=$false;Prompts=0;Fetches=1;Language='en'},
        @{Name='noninteractive denied';Scenario='always-denied';NonInteractive=$true;Token=$false;Success=$false;Prompts=0;Fetches=1;Language='en'},
        @{Name='missing tag';Scenario='missing-tag';NonInteractive=$false;Token=$false;Success=$false;Prompts=0;Fetches=1;Language='en'},
        @{Name='network failure';Scenario='network';NonInteractive=$false;Token=$false;Success=$false;Prompts=0;Fetches=1;Language='en'}
    )){
        $script:authScenario=$case.Scenario;$script:authPrompts=0;$script:authFetches=0;$script:lastAuthPrompt=''
        $run=Join-Path $FixtureRoot $case.Name;[IO.Directory]::CreateDirectory($run)|Out-Null
        $context=[pscustomobject]@{Repository='https://github.com/example/private.git';RunDir=$run;Tools=@{Git='fixture-git.exe'};Tag=$(if($case.Scenario -eq 'missing-tag'){'missing'}else{''});DependencyMode='Auto';Language=$case.Language;NonInteractive=$case.NonInteractive}
        $token=if($case.Token){ConvertTo-SecureString 'disposable-supplied-value' -AsPlainText -Force}else{$null}
        $succeeded=$false;$failure=''
        try{$null=Get-WtgSource -Context $context -GhToken $token;$succeeded=$true}catch{$failure=$_.Exception.Message}finally{if($token){$token.Dispose()}}
        $expectedFailure=if($case.Scenario -eq 'always-denied'){'GitHub refused access'}elseif($case.Scenario -eq 'missing-tag'){'requested tag or branch was not found'}elseif($case.Scenario -eq 'network'){'Git fixture exit 128'}else{''}
        [pscustomobject]@{Name=$case.Name;Correct=($succeeded -eq $case.Success -and $script:authPrompts -eq $case.Prompts -and $script:authFetches -eq $case.Fetches -and ($case.Success -or $failure -match [regex]::Escape($expectedFailure)));Russian=($case.Language -ne 'ru' -or $script:lastAuthPrompt -match 'Введите токен GitHub')}
    }
} (Join-Path $WorkRoot 'auth-fixtures')
foreach($outcome in $authResults){Assert ('authentication: '+$outcome.Name) ($outcome.Correct -and $outcome.Russian)}
$savedAuth=Get-ChildItem -LiteralPath (Join-Path $WorkRoot 'auth-fixtures') -File -Recurse|ForEach-Object {[IO.File]::ReadAllText($_.FullName)}
Assert 'interactive authentication does not persist prompted token' (-not (($savedAuth -join '') -match 'disposable-auth-fixture-value|disposable-supplied-value'))
Write-Output ('PASS '+$passed+' common/source checks. Records: '+$WorkRoot)

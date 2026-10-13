#requires -Version 5.1
<# Run in a real terminal (including ConPTY), then enter fixture-approved at the
   child's prompt. This tests console inheritance, not redirected input. It never
   installs applications, opens an elevated window or changes services. #>
param([string]$WorkRoot=(Join-Path $env:TEMP ('cilex-console-test-'+[Guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
if([Console]::IsInputRedirected -or [Console]::IsOutputRedirected){throw 'Run this console-only fixture in a terminal, without redirecting input or output.'}
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Common.psm1') -Force
[IO.Directory]::CreateDirectory($WorkRoot)|Out-Null
$child=Join-Path $WorkRoot 'prompt-child.ps1'
$log=Join-Path $WorkRoot 'interactive.log'
[IO.File]::WriteAllText($child,@'
$ErrorActionPreference='Stop'
Add-Type 'public static class PromptFixtureDeadline { public static void Start() { var t = new System.Threading.Thread(() => { System.Threading.Thread.Sleep(45000); System.Environment.Exit(93); }); t.IsBackground = true; t.Start(); } }'
[PromptFixtureDeadline]::Start()
$answer=Read-Host 'Enter fixture-approved to complete this isolated console test'
if($answer -ne 'fixture-approved'){exit 7}
[Console]::WriteLine('Child received the reply.')
'@,[Text.Encoding]::ASCII)
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$result=Invoke-WtgProcess -FilePath $shell -Arguments @('-NoProfile','-File',$child) -Interactive -LogPath $log -TimeoutSeconds 50
if($result.ExitCode -ne 0 -or $result.StdOut -or $result.StdErr){throw 'Interactive output was unexpectedly captured or the child failed.'}
if([IO.File]::ReadAllText($log) -notmatch 'not captured.*Exit code: 0'){throw 'Interactive capture limitation was not recorded.'}
Write-Output 'PASS: child prompt was answered through the terminal; child exited; diagnostic limitation recorded.'

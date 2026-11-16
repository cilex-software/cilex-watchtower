Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

function Assert-WtgRepository {
    param([string]$Repository)
    $uri=$null
    if(-not [Uri]::TryCreate($Repository,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $Repository -match '[\x00-\x20]'){
        throw 'Repository must be an HTTPS URL without embedded credentials, query or fragment.'
    }
    if($uri.AbsolutePath -notmatch '^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$'){throw 'Repository URL must identify one owner and repository.'}
    return $uri
}
function Initialize-WtgCredentialBrokerType {
    if('Cilex.Deployment.GitCredentialBroker' -as [type]){return}
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Security;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Threading;
namespace Cilex.Deployment {
 public sealed class GitCredentialBroker : IDisposable {
  private readonly string name;
  private SecureString token;
  private readonly Thread worker;
  private volatile bool stopped;
  private NamedPipeServerStream active;
  public string Name { get { return name; } }
  public GitCredentialBroker(SecureString value) {
   name="cilex-git-"+Guid.NewGuid().ToString("N"); token=value.Copy();
   worker=new Thread(Run); worker.IsBackground=true; worker.Start();
  }
  private NamedPipeServerStream CreatePipe(PipeSecurity acl) {
   var signature=new Type[] {typeof(string),typeof(PipeDirection),typeof(int),typeof(PipeTransmissionMode),typeof(PipeOptions),typeof(int),typeof(int),typeof(PipeSecurity)};
   var ctor=typeof(NamedPipeServerStream).GetConstructor(signature);
   if(ctor!=null) return (NamedPipeServerStream)ctor.Invoke(new object[] {name,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4096,4096,acl});
   // CurrentUserOnly on modern .NET; Framework uses the explicit protected ACL.
   return new NamedPipeServerStream(name,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|(PipeOptions)0x20000000,4096,4096);
  }
  private void Run() {
   while(!stopped) {
    try {
     PipeSecurity acl=new PipeSecurity();
     acl.SetAccessRuleProtection(true,false);
     acl.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User,PipeAccessRights.FullControl,AccessControlType.Allow));
     using(var pipe=CreatePipe(acl)) {
      active=pipe;
      if(stopped) return;
      var wait=pipe.BeginWaitForConnection(null,null);
      while(!wait.AsyncWaitHandle.WaitOne(100)) { if(stopped) return; }
      pipe.EndWaitForConnection(wait); wait.AsyncWaitHandle.Close();
      using(var reader=new StreamReader(pipe)) using(var writer=new StreamWriter(pipe)) {
       writer.AutoFlush=true;
       var request=reader.ReadLineAsync();
       if(!request.Wait(5000)) continue;
       if(request.Result=="username") writer.WriteLine("x-access-token");
       else if(request.Result=="password" && !stopped) {
        IntPtr bytes=Marshal.SecureStringToBSTR(token);
        try { writer.WriteLine(Marshal.PtrToStringBSTR(bytes)); }
        finally { Marshal.ZeroFreeBSTR(bytes); }
       }
      }
     }
    } catch { if(stopped) return; }
    finally { active=null; }
   }
  }
  public void Dispose() {
   stopped=true;
   try { if(active!=null)active.Dispose(); } catch {}
   worker.Join(6000); token.Dispose(); token=null;
  }
 }
}
'@
}
function New-WtgGitSession {
    param($Context,[Security.SecureString]$GhToken)
    $uri=Assert-WtgRepository $Context.Repository
    $environment=@{GIT_TERMINAL_PROMPT='0';GCM_INTERACTIVE='Never';GIT_LFS_SKIP_SMUDGE='1';LC_ALL='C'}
    $broker=$null
    if($GhToken){
        Initialize-WtgCredentialBrokerType
        # Use the signed inbox PowerShell host. The launcher contains no secret.
        $base=Join-Path $Context.RunDir 'git-auth'
        if($base -match '[&|<>^%!\r\n]'){throw 'The source workspace contains characters unsupported by Git askpass. Choose another WorkDir.'}
        $null=New-Item -ItemType Directory -Path $base
        $client=Join-Path $base 'git-askpass.ps1'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'git-askpass.ps1') -Destination $client
        $launcher=Join-Path $base 'askpass.cmd'
        [IO.File]::WriteAllText($launcher,('@setlocal DisableDelayedExpansion'+"`r`n"+'@"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File "%WTG_GIT_CLIENT%" %*'+"`r`n"),[Text.Encoding]::ASCII)
        $broker=New-Object Cilex.Deployment.GitCredentialBroker($GhToken)
        $environment.GIT_ASKPASS=$launcher;$environment.WTG_GIT_PIPE=$broker.Name;$environment.WTG_GIT_HOST=$uri.Host;$environment.WTG_GIT_CLIENT=$client
    }
    return [pscustomobject]@{Environment=$environment;Broker=$broker;HasToken=[bool]$GhToken}
}
function Invoke-WtgGit {
    param($Context,$Session,[string[]]$Arguments,[string]$Label='git',[int[]]$AllowedExitCodes=@(0))
    $options=@('-c','core.hooksPath=NUL','-c','protocol.ext.allow=never','-c','protocol.file.allow=never','-c','credential.useHttpPath=true','-c','http.sslVerify=true','-c','http.followRedirects=false')
    if($Session.HasToken){$options+=@('-c','credential.helper=')}
    $log=Join-Path $Context.RunDir ($Label+'.log')
    try{return Invoke-WtgProcess -FilePath $Context.Tools.Git -Arguments ($options+$Arguments) -Environment $Session.Environment -WorkingDirectory $Context.RunDir -TimeoutSeconds 1200 -LogPath $log -AllowedExitCodes $AllowedExitCodes}
    catch{
        $diagnostic=if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{''}
        if($diagnostic -match '(?i)authentication failed|could not read (username|password)|\b(401|403)\b|SAML SSO|repository not found'){
            $failure=New-Object InvalidOperationException (Get-WtgMessage GitDenied -Language $Context.Language)
            $failure.Data['WtgGitAuthenticationDenied']=$true
            throw $failure
        }
        if($diagnostic -match '(?i)couldn.t find remote ref|not a valid ref'){
            throw (Get-WtgMessage GitMissingRef -Language $Context.Language)
        }
        throw
    }
}
function Get-WtgSource {
    param($Context,[Security.SecureString]$GhToken,[string]$SourceDirectory,[string]$SourceCommit,[string]$SourceBundle,[string]$SourceSha256)
    $null=Assert-WtgRepository $Context.Repository
    if($SourceCommit -and $SourceCommit -notmatch '^[a-fA-F0-9]{40}$'){throw 'SourceCommit must be a full Git commit identifier.'}
    if($Context.Tag -and ($SourceDirectory -or $SourceBundle)){throw 'Tag cannot be combined with an offline/local source input.'}
    if($SourceDirectory -and $SourceBundle){throw 'Choose one source input.'}
    $offline=$Context.DependencyMode -eq 'Offline'
    if($offline -and -not ($SourceDirectory -or $SourceBundle)){throw (Get-WtgMessage OfflineSource -Language $Context.Language)}
    if(($SourceDirectory -or $SourceBundle) -and -not $SourceCommit){throw 'An explicit full SourceCommit is required for supplied source.'}
    $session=New-WtgGitSession -Context $Context -GhToken $GhToken
    $ownsPromptToken=$false
    $source=Join-Path $Context.RunDir 'source'
    try {
        $null=Invoke-WtgGit $Context $session @('init','--quiet',$source) 'source-init'
        if($SourceDirectory){
            $sourceInput=[IO.Path]::GetFullPath($SourceDirectory)
            if(-not (Test-Path -LiteralPath $sourceInput -PathType Container)){throw 'Supplied source directory is missing.'}
            $dirty=Invoke-WtgGit $Context $session @('-C',$sourceInput,'status','--porcelain','--untracked-files=normal') 'source-input-status'
            if($dirty.StdOut.Trim()){
                Write-Host 'Local changes are present and EXCLUDED. Only the committed source will be bundled:'
                Write-Host $dirty.StdOut.Trim()
            }else{Write-Host 'Local changes: none. Building committed code only.'}
            $head=Invoke-WtgGit $Context $session @('-C',$sourceInput,'rev-parse','HEAD') 'source-input-head'
            if($head.StdOut.Trim() -ne $SourceCommit){throw 'Supplied source HEAD differs from SourceCommit.'}
            $bundle=Join-Path $Context.RunDir 'provided-source.bundle'
            $null=Invoke-WtgGit $Context $session @('-C',$sourceInput,'bundle','create',$bundle,'HEAD') 'source-bundle-create'
            $null=Invoke-WtgGit $Context $session @('-C',$source,'bundle','verify',$bundle) 'source-bundle-check'
            $null=Invoke-WtgGit $Context $session @('-c','protocol.file.allow=always','-C',$source,'fetch','--no-tags',$bundle,'HEAD') 'source-local-fetch'
            $ref='FETCH_HEAD'
        }elseif($SourceBundle){
            if(-not $SourceSha256 -or $SourceSha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'A trusted SourceSha256 is required with SourceBundle.'}
            if((Get-WtgSha256 $SourceBundle) -ne $SourceSha256.ToLowerInvariant()){throw 'Source bundle hash does not match.'}
            $null=Invoke-WtgGit $Context $session @('-C',$source,'bundle','verify',[IO.Path]::GetFullPath($SourceBundle)) 'source-bundle-check'
            $null=Invoke-WtgGit $Context $session @('-c','protocol.file.allow=always','-C',$source,'fetch','--no-tags',[IO.Path]::GetFullPath($SourceBundle),'HEAD') 'source-local-fetch'
            $ref='FETCH_HEAD'
        }else{
            $null=Invoke-WtgGit $Context $session @('-C',$source,'remote','add','origin',$Context.Repository) 'source-remote'
            if($Context.Tag){
                $ref='refs/tags/'+$Context.Tag
                $null=Invoke-WtgGit $Context $session @('check-ref-format',$ref) 'source-tag-check'
                $spec='+'+$ref+':'+$ref
            }else{$ref='refs/remotes/origin/main';$spec='+refs/heads/main:'+ $ref}
            try {
                $null=Invoke-WtgGit $Context $session @('-C',$source,'fetch','--no-tags','origin',$spec) 'source-fetch'
            }catch{
                # Existing credentials get the first attempt. Prompt once only for missing
                # access; network and missing-tag errors must keep their original diagnosis.
                $denied=$_.Exception.Data.Contains('WtgGitAuthenticationDenied') -and $_.Exception.Data['WtgGitAuthenticationDenied'] -eq $true
                $nonInteractive=$Context.PSObject.Properties['NonInteractive'] -and [bool]$Context.NonInteractive
                if(-not $denied -or $session.HasToken -or $nonInteractive){throw}
                $prompt=if($Context.Language -eq 'ru'){'Нужен доступ к исходному коду. Введите токен GitHub с правом чтения репозитория (ввод скрыт)'}else{'Source access is required. Enter a GitHub token with repository read access (input is hidden)'}
                $GhToken=Read-Host $prompt -AsSecureString
                $ownsPromptToken=$true
                if(-not $GhToken -or -not $GhToken.Length){throw (Get-WtgMessage GitDenied -Language $Context.Language)}
                $session=New-WtgGitSession -Context $Context -GhToken $GhToken
                $null=Invoke-WtgGit $Context $session @('-C',$source,'fetch','--no-tags','origin',$spec) 'source-fetch-with-token'
            }
        }
        $resolved=Invoke-WtgGit $Context $session @('-C',$source,'rev-parse','--verify',($ref+'^{commit}')) 'source-revision'
        $commit=$resolved.StdOut.Trim()
        if($commit -notmatch '^[a-f0-9]{40}$' -or ($SourceCommit -and $commit -ne $SourceCommit)){throw 'Source revision does not match the requested commit.'}
        $null=Invoke-WtgGit $Context $session @('-C',$source,'checkout','--quiet','--detach',$commit) 'source-checkout'
        if(Test-Path -LiteralPath (Join-Path $source '.gitmodules')){
            if($offline -or $SourceDirectory -or $SourceBundle){throw 'This source needs submodules. Supply a complete authenticated online checkout; incomplete offline sources were not built.'}
            $null=Invoke-WtgGit $Context $session @('-C',$source,'submodule','update','--init','--recursive') 'source-submodules'
        }
        $attrs=Join-Path $source '.gitattributes'
        if((Test-Path -LiteralPath $attrs) -and [IO.File]::ReadAllText($attrs) -match 'filter=lfs'){
            if($offline -or $SourceDirectory -or $SourceBundle){throw 'This revision requires LFS content. An incomplete offline source cannot be built.'}
            $null=Invoke-WtgGit $Context $session @('-C',$source,'lfs','pull') 'source-lfs'
        }
        $cmake=Join-Path $source 'CMakeLists.txt'
        if(-not (Test-Path -LiteralPath $cmake)){throw 'The selected source is not a Watchtower source tree.'}
        $version=[regex]::Match([IO.File]::ReadAllText($cmake),'(?s)project\(watchtower\s+VERSION\s+(\d+\.\d+\.\d+)')
        if(-not $version.Success){throw 'Watchtower version is missing from the selected source.'}
        $record=[pscustomobject]@{Path=$source;Commit=$commit;Tag=$Context.Tag;Repository=$Context.Repository;Version=$version.Groups[1].Value;FetchedMain=([bool](-not $Context.Tag -and -not ($SourceDirectory -or $SourceBundle)));Offline=$offline}
        if($record.FetchedMain){Write-Host 'Remote main was fetched successfully; comparing it with existing successful builds.'}
        Write-WtgJson -Path (Join-Path $Context.RunDir 'source.json') -Value $record
        return $record
    }finally{
        if($session.Broker){$session.Broker.Dispose()}
        if($ownsPromptToken -and $GhToken){$GhToken.Dispose()}
    }
}
Export-ModuleMember -Function Assert-WtgRepository,Get-WtgSource,New-WtgGitSession

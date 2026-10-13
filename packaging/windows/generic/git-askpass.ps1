# The token is obtained from a short-lived, current-user-only named pipe.
# No credential is stored in this file, an environment variable or arguments.
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$PromptParts)
$ErrorActionPreference='Stop'
try {
    $promptText=$PromptParts -join ' '
    $match=[regex]::Match($promptText,"https://[^'\s]+")
    if(-not $match.Success){exit 1}
    $uri=[Uri]$match.Value
    if($uri.Host -ne $env:WTG_GIT_HOST -or $uri.Scheme -ne 'https'){exit 1}
    $kind=if($promptText -match '^(?i)Username'){ 'username' }elseif($promptText -match '^(?i)Password'){ 'password' }else{exit 1}
    if($env:WTG_GIT_PIPE -notmatch '^cilex-git-[a-f0-9]{32}$'){exit 1}
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.',$env:WTG_GIT_PIPE,[IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(10000)
    $reader=New-Object IO.StreamReader($pipe)
    $writer=New-Object IO.StreamWriter($pipe)
    $writer.AutoFlush=$true;$writer.WriteLine($kind)
    $reply=$reader.ReadLine()
    if(-not $reply){exit 1}
    [Console]::Out.WriteLine($reply)
    $reply=$null
    exit 0
}catch{exit 1}finally{if($pipe){$pipe.Dispose()}}

' start-labs.vbs - run the office's Labs wall guard with NO window at all. A scheduled task
' in the user's own session starts this; wscript has no console, and Run(...,0,True) starts
' PowerShell hidden and WAITS, so the task stays Running while the guard runs. The guard
' starts the Labs worker itself (through cmd, so a Stop can never kill its console).
Set sh = CreateObject("WScript.Shell")
py = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python\Python312\python.exe")
ff = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.2-full_build\bin")
c = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\wt-labs\guard3.ps1 -BaseRate 12.3 -BasePipes 1 -Labs C:\wt-labs -Python """ & py & """ -GuardDir C:\wt-labs\guard -StartWorker -FfmpegDir """ & ff & """"
sh.Run c, 0, True
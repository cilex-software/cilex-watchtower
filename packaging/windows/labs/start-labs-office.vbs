' start-labs.vbs - run the office's Labs wall guard with NO window at all. A scheduled task
' in the user's own session starts this; wscript has no console, and Run(...,0,True) starts
' PowerShell hidden and WAITS, so the task stays Running while the guard runs. The guard
' starts the Labs worker itself (through cmd, so a Stop can never kill its console).
' FILL (worker-0.3.10, operator decision 2026-09-30: "use full capacity of this PC to the
' limit" for Vehicles): WT_LABS_FILL=1 goes into THIS process's environment, which the guard
' and the worker it starts inherit. Office only -- the booth's launcher never sets it.
Set sh = CreateObject("WScript.Shell")
sh.Environment("Process")("WT_LABS_FILL") = "1"
' worker-0.3.12 applies these to itself, each unit and each decoder (older workers ignore them):
' Normal priority, and the power-throttling opt-out ("high QoS") that lets Windows place the
' Labs processes on the P-cores. Operator decision 2026-09-30: "Normal + performance".
sh.Environment("Process")("WT_LABS_PRIORITY") = "normal"
sh.Environment("Process")("WT_LABS_HIGHQOS") = "1"
py = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python\Python312\python.exe")
ff = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.2-full_build\bin")
' -WorkerPriority Normal (operator decision 2026-09-30): at Idle the i5-14400 kept the Labs
' tree on its 4 E-cores. The wall app runs at Normal too (its task's priority was raised
' from the Below Normal default), and the guard holds Labs if the worker ever outranks it.
c = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\wt-labs\guard3.ps1 -BaseRate 12.3 -BasePipes 1 -Labs C:\wt-labs -Python """ & py & """ -GuardDir C:\wt-labs\guard -StartWorker -WorkerPriority Normal -FfmpegDir """ & ff & """"
sh.Run c, 0, True
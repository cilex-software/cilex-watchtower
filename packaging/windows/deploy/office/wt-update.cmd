@echo off
rem The one-shot service's binPath (a powershell.exe binPath never runs; cmd.exe does).
rem The job runs DETACHED: the service manager gives a service 30 s to report and then
rem kills its process, and the job (probe + swap + up to 45 s of supervision checks) takes
rem longer. `start` hands it to a separate process and this wrapper returns at once.
echo wrapper started %DATE% %TIME% > C:\Users\Public\Downloads\wt-update.out
start "wt-update" /b powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Public\Downloads\wt-update-job.ps1
echo wrapper handed off %DATE% %TIME% >> C:\Users\Public\Downloads\wt-update.out

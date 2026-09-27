@echo off
echo wrapper started %DATE% %TIME% > C:\Users\Public\Downloads\wt-update.out
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Public\Downloads\wt-update-job.ps1 >> C:\Users\Public\Downloads\wt-update.out 2>&1
echo wrapper finished %DATE% %TIME% >> C:\Users\Public\Downloads\wt-update.out

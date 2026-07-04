; Cilex Watchtower - NSIS installer (per-user, no elevation).
; Packages the deployed dist (deploy.ps1: exe + Qt + GStreamer LGPL subset + ffmpeg + licenses)
; into a setup.exe. Build (after deploy.ps1 populated DIST_DIR):  makensis installer.nsi
;
; Per-user by design: installs to %LOCALAPPDATA%\Programs, RequestExecutionLevel user — matches
; the app's asInvoker manifest, so NO UAC prompt and no admin needed. (WiX/MSIX are alternatives.)

!define APPNAME  "Cilex Watchtower"
!define COMPANY  "Cilex Vision"
!define VERSION  "0.1.0"                  ; keep in sync with project(VERSION) / watchtower.rc
!define EXE      "watchtower.exe"
!define DIST_DIR "..\..\build-windows\dist"
!define REGKEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"

Name "${APPNAME}"
OutFile "CilexWatchtower-${VERSION}-setup.exe"
; Per-user install location; the user can change it on the Directory page.
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "${REGKEY}" "InstallLocation"
RequestExecutionLevel user                ; no elevation — per-user install
Unicode true
SetCompressor /SOLID lzma
BrandingText "${COMPANY}"

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

; --- upgrade-in-place: if a prior version is registered, uninstall it silently first ---
Function .onInit
    ReadRegStr $R0 HKCU "${REGKEY}" "UninstallString"
    StrCmp $R0 "" done
    ReadRegStr $R1 HKCU "${REGKEY}" "InstallLocation"
    StrCmp $R1 "" done
    ; run the old uninstaller silently, keeping the install dir, then continue
    ExecWait '"$R0" /S _?=$R1'
    Delete "$R0"
  done:
FunctionEnd

Section "Install"
    ; Clean slate so a smaller/renamed next build never leaves stale DLLs behind.
    ; User data lives in the profile (QSettings/registry + SQLite under AppData), NOT here.
    RMDir /r "$INSTDIR"
    SetOutPath "$INSTDIR"
    File /r "${DIST_DIR}\*.*"

    CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${EXE}"
    CreateShortcut "$DESKTOP\${APPNAME}.lnk"    "$INSTDIR\${EXE}"
    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; Add/Remove Programs (per-user hive). NoModify/NoRepair = a plain uninstall entry.
    WriteRegStr   HKCU "${REGKEY}" "DisplayName"     "${APPNAME}"
    WriteRegStr   HKCU "${REGKEY}" "DisplayVersion"  "${VERSION}"
    WriteRegStr   HKCU "${REGKEY}" "Publisher"       "${COMPANY}"
    WriteRegStr   HKCU "${REGKEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr   HKCU "${REGKEY}" "DisplayIcon"     "$INSTDIR\${EXE}"
    WriteRegStr   HKCU "${REGKEY}" "UninstallString" "$INSTDIR\uninstall.exe"
    WriteRegDWORD HKCU "${REGKEY}" "NoModify" 1
    WriteRegDWORD HKCU "${REGKEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
    Delete "$SMPROGRAMS\${APPNAME}.lnk"
    Delete "$DESKTOP\${APPNAME}.lnk"
    DeleteRegKey HKCU "${REGKEY}"
    RMDir /r "$INSTDIR"
SectionEnd

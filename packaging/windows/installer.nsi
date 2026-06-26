; Cilex Watchtower - NSIS installer skeleton.
; One option of several: WiX (MSI) and windeployqt --appx (MSIX/Store, Qt 6.11+) are alternatives;
; see README.md. Packages the deployed dist folder (windeployqt + GStreamer) into a setup.exe.
;
; Build (after deploy.ps1 has populated DIST_DIR):  makensis installer.nsi

!define APPNAME  "Cilex Watchtower"
!define COMPANY  "Cilex Vision"
!define VERSION  "0.1.0"
!define EXE      "watchtower.exe"
!define DIST_DIR "..\..\build-windows"   ; TODO: point at the deployed dist (where watchtower.exe + DLLs live)

Name "${APPNAME}"
OutFile "CilexWatchtower-${VERSION}-setup.exe"
InstallDir "$PROGRAMFILES64\${APPNAME}"
RequestExecutionLevel admin              ; needed to write Program Files; the app itself runs asInvoker
Unicode true
SetCompressor /SOLID lzma

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "Install"
    SetOutPath "$INSTDIR"
    File /r "${DIST_DIR}\*.*"                       ; the whole deployed dist (exe + Qt + GStreamer)
    CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${EXE}"
    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; Add/Remove Programs entry
    WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayName"     "${APPNAME}"
    WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayVersion"  "${VERSION}"
    WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "Publisher"       "${COMPANY}"
    WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "UninstallString" "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
    Delete "$SMPROGRAMS\${APPNAME}.lnk"
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
    RMDir /r "$INSTDIR"
SectionEnd

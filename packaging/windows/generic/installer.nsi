; Generic offline wrapper. Install.psm1 owns transactional installation,
; startup, registration and the file-bounded uninstaller.
Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"
!ifndef PACKAGE_DIR
!error "PACKAGE_DIR is required"
!endif
!ifndef OUTPUT_FILE
!error "OUTPUT_FILE is required"
!endif
!ifndef MANIFEST_SHA256
!error "MANIFEST_SHA256 is required"
!endif
Name "Cilex Watchtower ${VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\Cilex Watchtower"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetDatablockOptimize on
ShowInstDetails show
BrandingText "Cilex Watchtower"
VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "Cilex Watchtower"
VIAddVersionKey /LANG=1033 "FileDescription" "Cilex Watchtower offline installation"
VIAddVersionKey /LANG=1033 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Cilex Vision"

Var CommandLine
Var ExtractPath
Var TargetAccount
Var StartupChoice
Var ScopeChoice
Var LanguageChoice
Var SilentChoice
Var ResultPath
Var BackendUrl
Var ExitCode
Var RequirementOverrides
Var ConsentUnattended
Var AutologonPath
Var ExplicitDirectory
Var UseTargetDefault

!define MUI_PAGE_CUSTOMFUNCTION_PRE DirectoryPre
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Russian"

Function .onInit
    ${IfNot} ${RunningX64}
      SetErrorLevel 1
      Abort
    ${EndIf}
    ${GetParameters} $CommandLine
    ${GetOptions} $CommandLine "/EXTRACTONLY=" $ExtractPath
    ${GetOptions} $CommandLine "/TARGETUSER=" $TargetAccount
    ${GetOptions} $CommandLine "/STARTUPMODE=" $StartupChoice
    ${GetOptions} $CommandLine "/SCOPE=" $ScopeChoice
    ${GetOptions} $CommandLine "/LANGUAGE=" $LanguageChoice
    ${GetOptions} $CommandLine "/RESULT=" $ResultPath
    ${GetOptions} $CommandLine "/BACKEND=" $BackendUrl
    ${GetOptions} $CommandLine "/OVERRIDEREQUIREMENTS=" $RequirementOverrides
    ${GetOptions} $CommandLine "/AUTOLOGONPATH=" $AutologonPath
    ; NSIS removes its /D= option from $CMDLINE/GetParameters. Read the raw
    ; Windows command line solely to retain that explicit destination choice.
    System::Call 'kernel32::GetCommandLineW() w .r0'
    ${GetOptions} $0 "/D=" $ExplicitDirectory
    ClearErrors
    ${GetOptions} $CommandLine "/CONSENTUNATTENDED" $ConsentUnattended
    IfErrors no_consent has_consent
  no_consent:
    StrCpy $ConsentUnattended "False"
    Goto consent_done
  has_consent:
    StrCpy $ConsentUnattended "True"
  consent_done:
    StrCpy $UseTargetDefault "False"
    StrCmp $TargetAccount "" target_default_done
    StrCmp $ExplicitDirectory "" 0 target_default_done
    StrCpy $UseTargetDefault "True"
  target_default_done:
    StrCmp $ScopeChoice "Machine" 0 +3
      StrCmp $INSTDIR "$LOCALAPPDATA\Programs\Cilex Watchtower" 0 +2
        StrCpy $INSTDIR "$PROGRAMFILES64\Cilex Watchtower"
    StrCpy $SilentChoice "False"
    IfSilent 0 +2
      StrCpy $SilentChoice "True"
    StrCmp $LanguageChoice "ru" 0 +2
      StrCpy $LANGUAGE 1049
    StrCmp $LanguageChoice "en" 0 +2
      StrCpy $LANGUAGE 1033
FunctionEnd

Function DirectoryPre
    ; Another user's default must be resolved by the target helper, not from
    ; the account launching this wrapper. /D= remains the explicit override.
    StrCmp $UseTargetDefault "True" 0 +2
      Abort
FunctionEnd

Section "Install"
    InitPluginsDir
    SetOutPath "$PLUGINSDIR\package"
    File /r "${PACKAGE_DIR}\*.*"
    SetOutPath "$PLUGINSDIR"
    ; The embedded manifest hash binds both payload and helper files.
    ; No token, sign-in password or remote credential is accepted here.
    ; The target is x64: use native PowerShell and registry views, not WOW64.
    ${DisableX64FSRedirection}
    ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -File "$PLUGINSDIR\package\helpers\installer-entry.ps1" -PackagePath "$PLUGINSDIR\package" -ExpectedManifestSha256 "${MANIFEST_SHA256}" -InstallDir "$INSTDIR" -TargetUser "$TargetAccount" -StartupMode "$StartupChoice" -InstallScope "$ScopeChoice" -Language "$LanguageChoice" -ExtractOnly "$ExtractPath" -Silent "$SilentChoice" -ResultPath "$ResultPath" -BackendUrl "$BackendUrl" -OverrideRequirements "$RequirementOverrides" -ConsentUnattended "$ConsentUnattended" -AutologonPath "$AutologonPath" -UseTargetDefault "$UseTargetDefault"' $ExitCode
    ${EnableX64FSRedirection}
    SetErrorLevel $ExitCode
    StrCmp $ExitCode 0 completed
    StrCmp $ExitCode 2 completed
    StrCmp $ExitCode 3010 completed
    Abort
  completed:
SectionEnd

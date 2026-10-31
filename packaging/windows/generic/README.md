# Install Cilex Watchtower on Windows

[`deploy-watchtower.ps1`](../deploy-watchtower.ps1) builds the latest version and installs **Watchtower and Warden**, which keeps Watchtower running. Choose local or remote installation below, or create an installer to share. The script asks for the choices it needs; you do not need to fill in a long list of options.

These instructions describe the current tools. A complete graphical setup
wizard is planned, with [the requirements saved here](../../../docs/plans/2026-10-13-generic-windows-deployment-specification.md#17-graphical-wizard-and-office-installation-lessons).
The current setup EXE has limited screens and still uses helper prompts.

## Before you start

1. Download and extract the repository from GitHub, or use the complete deployment ZIP supplied to you. Keep its folders together; copying only the script will not work.
2. Open the extracted `packaging\windows` folder in File Explorer. Click the address bar, type `powershell`, and press Enter.
3. Use a Windows 64-bit computer with internet access for the build. Missing build tools are prepared with your approval. The first build can take a while.

If GitHub access is needed, the script asks for a **GitHub token with read access to this repository**. Enter it only at the hidden prompt. This is separate from your Windows password.

## 1. Install on this computer

Sign into the Windows account that will use Watchtower, then run:

```powershell
.\deploy-watchtower.ps1
```

The default location is `%LOCALAPPDATA%\Programs\Cilex Watchtower` for that user. To choose another folder:

```powershell
.\deploy-watchtower.ps1 -InstallDir 'D:\Apps\Cilex Watchtower'
```

## 2. Install on another computer

Run these commands on the computer doing the build:

```powershell
$admin = Get-Credential
.\deploy-watchtower.ps1 -TargetUser 'OFFICE-PC\Operator' -Credential $admin -RemoteStagePath '\\OFFICE-PC\C$\CilexWatchtower-Deploy'
```

Change just these details:

| Detail | What to enter |
| --- | --- |
| Credential window | An administrator account on the other computer, such as `OFFICE-PC\Admin`, and its Windows password. `$admin` stores this login for the command. |
| `OFFICE-PC` | The other computer's Windows name. Replace it in both places. |
| `Operator` | The Windows account that will display Watchtower. It can be different from the administrator account. |
| `C$\CilexWatchtower-Deploy` | A temporary transfer folder on the other computer's C: drive. This is **not** the final application folder. Usually leave it as shown. |

The other computer must already allow administrator access over the network. Its Watchtower account must exist and have signed into Windows at least once. Leave that account signed in to see Watchtower start immediately.

The script reads the computer name from the network path, builds here, and installs there. The default application folder belongs to the specified Watchtower user. To choose a different final folder **on the other computer**, add:

```powershell
.\deploy-watchtower.ps1 -TargetUser 'OFFICE-PC\Operator' -Credential $admin -RemoteStagePath '\\OFFICE-PC\C$\CilexWatchtower-Deploy' -InstallDir 'D:\Apps\Cilex Watchtower'
```

Use this command instead of the previous installation command; it reuses the login stored in `$admin`.

## Answer the setup prompts

- **Startup:** choose `1` to start Watchtower after Windows sign-in, or `2` for automatic return after reboot. Option 2 needs automatic Windows sign-in to be set up and tested. The script does not reboot the computer.
- **Server address:** enter your Cilex Vision address, or press Enter to configure it later. Existing station settings are preserved.
- **Requirements and downloads:** review any warning and approve the required tools. Remote-computer warnings are presented here too.

You do **not** need `-StartupMode` or `-DeferEnrollment` in the normal command: these choices are prompted. They are optional shortcuts, not extra installation steps.

You also do **not** need both `-TargetHost` and `-ExpectedHost` for the example above. `TargetHost` is the address used to connect; `ExpectedHost` is the Windows computer name checked after connecting. Specify the latter only when the address is an IP or an alias instead of that name.

## Other useful choices

Append an option to either installation command:

| What you want | Option to add |
| --- | --- |
| Use a particular release | `-Tag 'EXISTING-TAG'` — replace with an actual repository tag. |
| Choose the application folder | `-InstallDir 'D:\Apps\Cilex Watchtower'` |
| Show English or Russian messages | `-Language en` or `-Language ru` |
| Preview the command without installing | `-WhatIf` |

For an existing installation created by an older installer, see [upgrading an older setup](ADVANCED.md#adopting-a-pre-existing-office-installation). Do not add adoption options unless that section applies.

## Create an installer to share

From the same `packaging\windows` PowerShell window, run:

```powershell
.\deploy-watchtower.ps1 -Mode BuildInstaller
```

Follow the prompts. This builds the latest version into **one setup `.exe` containing Watchtower, Warden and their required libraries**. It only creates the installer; it does not install the applications on this computer.

When it finishes, paste this into File Explorer's address bar to find the installer:

```text
%LOCALAPPDATA%\Cilex\Deploy\output
```

Copy the generated setup `.exe` to another supported 64-bit Windows computer, double-click it, and follow its setup prompts.

To save the installer somewhere else, use this command instead, replacing the example folder with your preferred location:

```powershell
.\deploy-watchtower.ps1 -Mode BuildInstaller -OutputDir 'D:\CilexInstallers'
```

Installation on a completely fresh PC remains unverified.

## If something needs attention

Follow the final message. If it reports unfinished setup or checks, installation is not fully verified. It prints the location of the result and logs for support.

The Office update and application recovery have been tested. Fresh-machine/offline installation and automatic startup after reboot remain unverified. See the [test record](../../../docs/verification/2026-10-13-generic-deployment/README.md).

[Advanced guide](ADVANCED.md): offline installers, existing packages, network access, recovery and troubleshooting.

## All command options

There are **no mandatory options for local interactive installation**. For the short remote command, supply the desktop account and network staging path; supply `-Credential` when your current Windows login does not already have remote administrator access. Other choices are prompted or have defaults.

<details>
<summary>Open the full option reference — normal installations only need the two examples above</summary>

The examples below are **options to add after `.\deploy-watchtower.ps1`**, not separate commands. Replace example names and paths with your own. Omit an option to use the stated default. Unless a row says otherwise, optional values are unset and switches are off.

### Installation choices

| Option | When to use it; default | Example to add |
| --- | --- | --- |
| `-Mode` | Normally inferred: local `Install`, or `RemoteInstall` for a remote destination. Also supports `Check` (inspect), `Build` (build only), and `BuildInstaller` (create a setup EXE). | `-Mode BuildInstaller` |
| `-InstallDir` | Choose where Watchtower is installed **on the destination PC**. Default: the desktop user's `%LOCALAPPDATA%\Programs\Cilex Watchtower`. | `-InstallDir 'D:\Apps\Cilex Watchtower'` |
| `-InstallScope` | `User` is the default. `Machine` installs under `%ProgramFiles%\Cilex Watchtower` unless a directory is supplied; administrator approval is required. Both use one designated desktop account. | `-InstallScope Machine` |
| `-TargetUser` | The Windows account that will display Watchtower. Local default: the current account. Required remotely; this can differ from the administrator used to connect. The account must already have a Windows profile. | `-TargetUser 'OFFICE-PC\Operator'` |
| `-StartupMode` | The script **asks** if omitted. `AfterSignIn` starts Watchtower after someone signs in. `UnattendedReboot` also requires automatic Windows sign-in and a later reboot test. | `-StartupMode AfterSignIn` or `-StartupMode UnattendedReboot` |
| `-BackendUrl` | Supply the Cilex server address instead of entering it when asked. Existing settings are preserved; a conflicting address is rejected. | `-BackendUrl 'https://vision.example.org'` |
| `-DeferEnrollment` | Skip the server-address question and finish server registration/login later. Existing working settings are preserved. This does not mean a fresh installation is ready to show cameras. | `-DeferEnrollment` |
| `-Language` | `Auto` uses Russian for Russian Windows display language, English otherwise. Choose `ru` or `en` to override. | `-Language en` |

### Connecting to another PC

| Option | When to use it; default | Example to add |
| --- | --- | --- |
| `-RemoteStagePath` | Temporary transfer folder. A network path selects remote installation and supplies its computer name. Default when `TargetHost` is supplied: `\\COMPUTER\C$\CilexWatchtower-Deploy`. This is **not** the final application folder. | `-RemoteStagePath '\\OFFICE-PC\C$\CilexWatchtower-Deploy'` |
| `-Credential` | An administrator account for the remote connection. Omit if the current account already has access. Passwords are entered in the Windows prompt. | `-Credential (Get-Credential)` |
| `-TargetHost` | Connection name or IP address. Omit when the network staging path already contains it. | `-TargetHost 'OFFICE-PC'` |
| `-ExpectedHost` | The actual Windows computer name, used to prevent installation on the wrong PC. Normally inferred from `TargetHost`; supply only when connecting by IP or an alias that differs from that name. | `-TargetHost '192.168.1.20' -ExpectedHost 'OFFICE-PC'` |
| `-Transport` | Remote connection method. A supplied network staging path chooses `SMBService`; otherwise `WinRM`. Both require existing authorized access. Usually omit. | `-Transport WinRM -TargetHost 'OFFICE-PC' -TargetUser 'OFFICE-PC\Operator'` |
| `-RemoteStageLocalPath` | Only needed for a custom share whose local folder cannot be inferred. For `C$` or `D$`, omit it. | `-RemoteStagePath '\\OFFICE-PC\DeployShare\Cilex' -RemoteStageLocalPath 'D:\DeployShare\Cilex'` |

`-TargetHost` is **how to connect**; `-ExpectedHost` is **which PC must answer**. They need not be repeated when using the PC's normal name.

### Source code and private-repository access

| Option | When to use it; default | Example to add |
| --- | --- | --- |
| `-GhToken` / `-gh_token` | Give the script GitHub read access if it cannot use existing Git credentials. Enter the token in the hidden prompt; never paste it directly into the command. | `-GhToken (Read-Host 'GitHub token' -AsSecureString)` |
| `-Tag` | Build an exact existing release tag instead of the latest `main`. The script refuses nonexistent tags. | `-Tag (Read-Host 'Existing release tag')` |
| `-Repository` | Use another compatible repository. Default: `https://github.com/romayankin/cilex-watchtower.git`. HTTPS only; no credentials in the URL. | `-Repository 'https://github.com/YOUR-ORG/cilex-watchtower.git'` |
| `-SourceDirectory` | Build from an existing **clean** source checkout. Requires `SourceCommit`; cannot be combined with `Tag` or `SourceBundle`. | `-SourceDirectory 'D:\Source\cilex-watchtower' -SourceCommit $commit` |
| `-SourceCommit` | A full 40-character commit ID. Required with supplied source; otherwise optional, to require that the fetched version matches this exact commit. | `-SourceCommit $commit` |
| `-SourceBundle` | Build from a Git bundle, usually offline. Requires `SourceSha256` and `SourceCommit`; cannot be combined with `Tag` or `SourceDirectory`. | `-SourceBundle 'D:\Offline\watchtower.bundle' -SourceSha256 $sourceHash -SourceCommit $commit` |
| `-SourceSha256` | The trusted SHA-256 supplied with a source bundle. It confirms you have the intended file. | `-SourceBundle 'D:\Offline\watchtower.bundle' -SourceSha256 $sourceHash -SourceCommit $commit` |

For the supplied-source examples, obtain the commit and hash from the maintainer, then enter them:

```powershell
$commit = Read-Host 'Full source commit supplied by the maintainer'
$sourceHash = Read-Host 'Source bundle SHA-256 supplied by the maintainer'
```

### Installing a package that was already built

Skip these options when the script builds the application itself; it handles package verification automatically.

| Option | When to use it; default | Example to add |
| --- | --- | --- |
| `-PackagePath` | Install a complete generated package folder, ZIP or setup EXE instead of downloading source and rebuilding. Do not combine with source options or `GhToken`. | `-PackagePath 'D:\Packages\package' -PackageManifestSha256 $manifestHash` |
| `-PackageManifestSha256` | Confirm a package folder matches the trusted manifest supplied by its builder. Optional for a directory, recommended when transferring one separately. | `-PackagePath 'D:\Packages\package' -PackageManifestSha256 $manifestHash` |
| `-PackageSha256` | Required with a supplied ZIP or setup EXE. Use the trusted file hash supplied by its builder. | `-PackagePath 'D:\Packages\watchtower.zip' -PackageSha256 $packageHash` |

Enter the relevant hash only when using one of these examples:

```powershell
$manifestHash = Read-Host 'Manifest SHA-256 supplied by the builder'
$packageHash = Read-Host 'ZIP or EXE SHA-256 supplied by the builder'
```

### Downloads, build folders and setup files

| Option | When to use it; default | Example to add |
| --- | --- | --- |
| `-DependencyMode` | `Auto` downloads missing tools. `Manual` gives download instructions. `Offline` makes no download requests and requires verified cached tools plus supplied source. | `-DependencyMode Manual` |
| `-CacheDir` | Folder for downloaded tools. Default: `%LOCALAPPDATA%\Cilex\Deploy\cache`. | `-CacheDir 'D:\CilexBuild\cache'` |
| `-WorkDir` | Folder for builds and run logs. Default: `%LOCALAPPDATA%\Cilex\Deploy\work`. | `-WorkDir 'D:\CilexBuild\work'` |
| `-OutputDir` | Folder for setup EXEs and bootstrap ZIPs. Default: `%LOCALAPPDATA%\Cilex\Deploy\output`. | `-OutputDir 'D:\CilexInstallers'` |
| `-BuildJobs` | Simultaneous build jobs, from 1 to 64. Default: `2`. More jobs need more memory. | `-BuildJobs 4` |
| `-Tools` | Use specific existing build tools instead of detecting them. Supply a PowerShell table; normal installations do not need this. | `-Tools @{ Git = 'D:\Tools\Git\cmd\git.exe' }` |
| `-CreateBootstrapBundle` | Also create a ZIP of the deployment scripts after the operation. This is a tool bundle, **not** the application installer. | `-Mode BuildInstaller -CreateBootstrapBundle` |
| `-SigningThumbprint` | Sign a generated setup EXE using your installed code-signing certificate with an accessible private key in `Cert:\CurrentUser\My`. Default: unsigned. | `-Mode BuildInstaller -SigningThumbprint $thumbprint` |
| `-TimestampUrl` | Optional HTTPS timestamp service when signing; unavailable offline. Use the address provided by your certificate issuer. | `-Mode BuildInstaller -SigningThumbprint $thumbprint -TimestampUrl $timestampUrl` |

`Tools` accepts executable paths for `Git`, `CMake`, `Ninja`, `Python`, `PkgConfig`, `Makensis`, `FFmpeg` and `VCRedist`; a batch-file path for `VsDevCmd`; and SDK folders for `QtRoot` and `GStreamerRoot`. Compatibility checks still apply. Keep build folders separate from the installation folder.

For signing, set the two values before running the example:

```powershell
$thumbprint = Read-Host 'Installed code-signing certificate thumbprint'
$timestampUrl = Read-Host 'HTTPS timestamp address from your certificate issuer'
```

### Checks, unattended commands and recovery

| Option | When to use it; default | Example to add |
| --- | --- | --- |
| `-CheckRole` | With `Mode Check`, inspect `Target` requirements (default) or `Build` requirements. These checks run on the current PC. | `-Mode Check -CheckRole Build` |
| `-Json` | Print `Mode Check` findings in a machine-readable format. Changing runs already save a JSON result file. | `-Mode Check -Json` |
| `-WhatIf` | Show the planned operation without downloading, installing or changing anything. It is a preview, not a full compatibility test. | `-WhatIf` |
| `-Confirm` | Add PowerShell's confirmation before executing the operation. Normally unnecessary because the script already asks you to accept its plan. | `-Confirm` |
| `-OverrideRequirements` | Accept only named warnings you reviewed. Usually answer the interactive question instead. Never bypasses integrity, permission or hard compatibility failures. | `-OverrideRequirements @('capacity.validation')` |
| `-NonInteractive` | Run without questions. All required choices and warning acceptances must already be supplied. This cannot complete Windows sign-in dialogs. | `-NonInteractive -AcceptPlan -AcceptLicenses -StartupMode AfterSignIn -DeferEnrollment` |
| `-AcceptPlan` | Skip the installation/build-plan confirmation. Does not accept licenses or requirement warnings. | `-AcceptPlan` |
| `-AcceptLicenses` | Accept required dependency licenses without asking. Use only after reviewing them. | `-AcceptLicenses` |
| `-VerifyOnly` | Inspect the installed application's startup and health without reinstalling or restarting it. Saves a report. Use the original installation/account options; run in the desktop account to check window visibility. | `-VerifyOnly -InstallDir 'D:\Apps\Cilex Watchtower'` |
| `-ResumeRunId` | Retrieve and check the recorded result after an interrupted **remote** run. Use its original connection, account, installation and startup options. This does not restart a failed installation. | `-ResumeRunId '20261013-120000-ab123456'` |
| `-ConfirmNoManualSignIn` | With `VerifyOnly`, confirm you personally observed that nobody signed in after the reboot. Does not itself prove startup succeeded. | `-VerifyOnly -ConfirmNoManualSignIn` |
| `-AdoptExisting` | Deliberately migrate an older compatible installation not managed by this script. Requires its exact existing Warden task name and installation directory. | `-AdoptExisting -LegacyTaskName 'CilexWarden' -InstallDir 'D:\Apps\Cilex Watchtower'` |
| `-LegacyTaskName` | Identify the startup task being migrated with `AdoptExisting`. No task is guessed. | `-AdoptExisting -LegacyTaskName 'CilexWarden' -InstallDir 'D:\Apps\Cilex Watchtower'` |
| `-ConsentUnattended` | Explicitly consent to automatic sign-in setup when using `UnattendedReboot`. Does not set a password, complete the setup dialog or reboot. | `-StartupMode UnattendedReboot -ConsentUnattended` |
| `-AutologonPath` | For **local interactive** setup, open an already downloaded, verified Microsoft Autologon tool. Enter credentials only in its window. | `-StartupMode UnattendedReboot -AutologonPath 'C:\Tools\Autologon64.exe'` |

The noninteractive example may also need `GhToken`, target information, package/source options and the exact `OverrideRequirements` findings reported for that run. There is no accept-all switch.

For automatic sign-in, Microsoft Autologon is available from its [official download page](https://learn.microsoft.com/sysinternals/downloads/autologon). Remote installation can report that setup is still required; complete it at the destination PC. No option automatically reboots a computer.

PowerShell's standard common parameters are also available; see `Get-Help about_CommonParameters`. They are not additional installation settings.

</details>

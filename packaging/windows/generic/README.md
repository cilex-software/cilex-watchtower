# Generic Windows deployment

Entry point: [`../deploy-watchtower.ps1`](../deploy-watchtower.ps1).

This is the separate build, packaging and installation workflow for Windows x64
computers. It can prepare missing build tools, fetch a private source repository,
build Watchtower and packaged Warden, install locally or remotely, and create an
offline installer. It has no Booth or Office address, account or tool path baked
into its defaults.

The existing [`build-and-update.ps1`](../deploy/build-and-update.ps1) remains the
maintenance script for the already configured Security Booth and Office. The
generic workflow does not replace that script.

**Validation status:** The final full suite passed **487 checks through Windows
PowerShell 5.1, plus eight Python checks**, including the native launcher and
PowerShell 7-to-5.1 compatibility repair. A real source build, isolated startup,
export/decoding and installer extraction also passed. The revised Office update installed Watchtower **1.1.779**
and Warden **1.4.10**. The visible window, correct supervision and 31 advancing
camera feeds passed the 150-second startup check with no stream errors. Both
authorized Office recovery tests passed: Watchtower returned automatically in
4.2 seconds; after supervisor failure, one replacement group returned in
57.8 seconds. Both then passed another 150-second health check. Office automatic
sign-in setup was not completed; its account and security settings are unchanged.
Clean-machine/offline installation and reboot startup remain unverified. The
guard's Watchtower remained running. See the
[verification record](../../../docs/verification/2026-10-13-generic-deployment/README.md)
for exact evidence and remaining checks. Hardware and camera-capacity thresholds
remain provisional. A configured startup task is not proof of unattended reboot
success.

## Get the script and choose the right computer

The build computer needs Windows x64 and Windows PowerShell 5.1 or newer. The
script does not require PowerShell 7, winget, Chocolatey, Git or Qt to be present
at first launch. It provisions missing build dependencies where supported.
Use a normal PowerShell window initially; setup requests elevation where needed.
Windows security policy must permit the approved tools and scripts to run.
In particular, a Windows PowerShell `Restricted` policy can block both the
bootstrap and the offline installer's script helpers. The installer reports the
block and does not change policy or add a bypass. Use your organization's approved
script-execution/signing route; an operator-approved temporary exception is a
separate decision, not a deployment default.

The installation target receives the runtime package. It does not need a compiler,
Qt SDK, Python installation or GitHub token. It needs a supported Windows desktop
and the account that will display Watchtower. Sign into that account at least once
so Windows creates its profile.

Because the repository is private, obtain the script using either route:

1. An authorized maintainer provides `CilexWatchtower-bootstrap-RUN-ID.zip` and its
   SHA-256 through a trusted channel. Verify the hash, extract the ZIP, and open
   PowerShell in its `packaging\windows` directory.
2. Sign into the private GitHub repository in a browser and download its source
   ZIP, or use an existing authorized checkout. Keep the `packaging\windows`
   directory and its subdirectories together. Open PowerShell there.

Do not copy just `deploy-watchtower.ps1`: it imports the adjacent `generic` modules
and uses the retained verification helpers in `deploy`.

```powershell
# Compare this value with the SHA-256 received from the maintainer.
Get-FileHash 'C:\Downloads\CilexWatchtower-bootstrap-RUN-ID.zip' -Algorithm SHA256

# From the extracted bundle or repository's packaging\windows directory:
.\deploy-watchtower.ps1 -Mode Check -CheckRole Build
.\deploy-watchtower.ps1 -Mode Check -CheckRole Target
```

`Check` and `-WhatIf` do not create files, download tools, launch Watchtower or
change settings. Online Check can make bounded endpoint requests; add
`-DependencyMode Offline` to skip those requests. `Check -TargetHost ...` currently
still checks the initiating computer and explicitly reports remote checks as
deferred. A remote installation checks the actual target before changing it.

## Main operations

| Mode | Result |
| --- | --- |
| `Check` | Read-only Build or Target assessment. |
| `Build` | Exact source revision, compiled applications, packaged dependencies and build checks. |
| `Install` | Build then install locally, or install a verified package directory, ZIP or generated setup EXE. |
| `RemoteInstall` | Build locally or reuse a package; transfer, verify and install on the target. |
| `BuildInstaller` | Build and produce one self-contained Windows setup EXE; do not install Watchtower on the build computer. |

Default installation: `%LOCALAPPDATA%\Programs\Cilex Watchtower`, resolved for the
intended desktop account. `-InstallScope Machine` selects
`%ProgramFiles%\Cilex Watchtower` by default. Both scopes still use one designated
desktop account and ordinary user privileges for Watchtower/Warden.

Default build data locations are under `%LOCALAPPDATA%\Cilex\Deploy`:

| Directory | Contents |
| --- | --- |
| `cache` | Verified downloads, privately extracted tools, dependency lock. |
| `work\RUN-ID` | Source snapshot, build, tests, logs, result and installation requests. |
| `output` | Offline installers, bootstrap ZIPs and their hash records. |

Use `-CacheDir`, `-WorkDir` and `-OutputDir` to choose other local disks. Keep them
separate from the installed application. Use reasonably short paths: Windows
tools can still impose path-length limits. Existing source checkouts and their
uncommitted work are preserved.

### Build and install the latest main locally

```powershell
$repoToken = Read-Host 'GitHub token' -AsSecureString
.\deploy-watchtower.ps1 -Mode Install -GhToken $repoToken `
    -StartupMode AfterSignIn -BackendUrl 'https://vision.example.org'
```

Replace the example backend address with your actual server. Use
`-DeferEnrollment` instead of `-BackendUrl` to configure the backend later.
Windows startup, application login and Warden station registration are separate
steps. The script does not invent a station token or copy another station's login.

The script fetches main once, records its complete commit identifier and builds
that exact snapshot. A subsequent main update does not alter a build already in
progress. The script never commits, pushes or tags source code.

### Build an exact release tag and an offline installer

```powershell
$repoToken = Read-Host 'GitHub token' -AsSecureString
$releaseTag = Read-Host 'Exact existing Git tag'
.\deploy-watchtower.ps1 -Mode BuildInstaller -Tag $releaseTag `
    -GhToken $repoToken -OutputDir 'D:\CilexInstallers' -CreateBootstrapBundle
```

A missing tag fails; it does not fall back to main. Older tags that require a
different toolchain or lack the supported isolated-startup hook are refused
rather than treated as compatible automatically.

The installer is named
`CilexWatchtower-VERSION-COMMIT-windows-x64-setup.exe`. Its adjacent `.json` record
contains its SHA-256 and signing status. `-CreateBootstrapBundle` also packages
the reusable deployment scripts and manifests after the requested operation
finishes. The bootstrap ZIP is a build/deployment tool bundle, not the application
runtime installer.

To sign an installer, supply `-SigningThumbprint` for a code-signing certificate
with an accessible private key in `Cert:\CurrentUser\My`. Optional `-TimestampUrl`
must use HTTPS. Offline operation cannot request a network timestamp. Without a
certificate, the result explicitly reports `Unsigned`; the script does not alter
Windows policy to admit it.

### Custom destination and installing a built package

```powershell
.\deploy-watchtower.ps1 -Mode Install `
    -PackagePath 'D:\CilexBuild\package' `
    -PackageManifestSha256 'TRUSTED_64_CHARACTER_MANIFEST_SHA256' `
    -InstallDir 'D:\Apps\Cilex Watchtower' `
    -StartupMode AfterSignIn -DeferEnrollment
```

`package` must be the complete generated directory containing `manifest.json`,
`payload` and the helper files. Copy the trusted manifest hash from the build
record. For a ZIP containing that directory's contents, pass `-PackageSha256`
with the ZIP's trusted SHA-256. Verification checks declared files and rejects
unlisted files, bad hashes, unsafe archive paths and linked directories.

The local and remote `-PackagePath` routes accept an extracted package directory,
ZIP or generated setup EXE. A supplied EXE requires its trusted `-PackageSha256`;
the script uses the installer's controlled extraction mode before installation.
You can also run the generated EXE directly for local interactive installation.

An offline setup EXE contains Watchtower, native Warden, Qt/QML plugins,
GStreamer and its required dependencies, LGPL FFmpeg export tools and the Visual
C++ runtime installer. It does not contain Windows, graphics drivers or station
credentials. Local installation/startup does not require internet; cameras and
backend features still require their normal connections. Use the installer's
interactive prompts to select startup and finish configuration.

For an approved silent installation, explicitly accept the findings reported by
the target's Check. The EXE accepts `/OVERRIDEREQUIREMENTS=id1,id2` together with
`/S`, `/STARTUPMODE=AfterSignIn` (or `UnattendedReboot`), `/TARGETUSER=...`,
`/LANGUAGE=en` or `ru`, and optional `/BACKEND=...`. There is no accept-everything
wildcard. `/CONSENTUNATTENDED` records the separate automatic-sign-in consent;
`/AUTOLOGONPATH=...` selects an already verified Microsoft tool for interactive
setup. Silent operation cannot enter Windows credentials or make that UI step
complete. `/D=...` chooses an explicit directory; without it, a supplied target
account uses its own profile's default directory.

## Requirement warnings and languages

`-Language Auto` uses Russian for a Russian Windows user display language and
English otherwise. Explicit `-Language ru` or `-Language en` overrides it.

| Assessment | Current profile |
| --- | --- |
| Architecture | Native Windows x64; 64-bit PowerShell. |
| Runtime OS dependency baseline | Windows 10 build 17763 / version 1809 or newer; application compatibility still needs testing. |
| Build OS dependency baseline | Windows 10 build 19044 / version 21H2 or newer. |
| Build capacity guideline | 8 GiB installed RAM, 4 GiB available RAM, four logical processors; provisional. |
| Runtime capacity guideline | 4 GiB installed RAM, 2 GiB available RAM, two logical processors; provisional. |
| GPU and stream capacity | Adapter inspection only; rendering, codec support and chosen camera workload need actual application tests. |

Windows Server/ARM64 are not validated by this profile. Windows support
entitlement is separate from software execution: a compatible OS build does not
prove that its edition still receives security updates.

The check also looks for Windows Media Foundation components. Windows N editions
may require [Media Feature Pack](https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-n)
through Windows Optional features. These are Windows components and are not
copied from another machine into the application package. Missing components
produce an explicit warning and require repair before playback can be verified.

Storage is assessed per volume using provisional peak budgets for downloads,
SDK extraction, source/build output, staging, installed files, rollback and a
reserve. The current conservative estimates can overstate an existing build
computer's additional need because compatible tools/cache may already exist.
Actual download and extraction space is checked again before writing. Storage
needed for future recordings or exports is additional.

Interactive warnings offer retry, continue or cancel. Continuing records the
accepted finding identifiers. Noninteractive operation requires an explicit
`-OverrideRequirements` list. Obtain those identifiers from `Check`, read their
meaning, and accept only the intended findings:

```powershell
.\deploy-watchtower.ps1 -Mode Check -CheckRole Build -Json

# Example only: use the findings actually returned on your computer.
$acceptedFindings = @('capacity.validation', 'system.restart')
.\deploy-watchtower.ps1 -Mode Build -GhToken $repoToken `
    -NonInteractive -AcceptPlan -AcceptLicenses `
    -OverrideRequirements $acceptedFindings
```

An override permits an attempt on a machine below a guideline. It cannot enable
a 64-bit program on 32-bit Windows, create missing disk space, bypass access
denials or skip integrity/security-policy checks. Unreadable checks remain
`UNKNOWN`; they never become a pass merely because they were accepted.

## Dependencies, manual downloads and offline builds

[`dependencies.json`](dependencies.json) is the pinned download catalog;
[`requirements.json`](requirements.json) records the platform and provisional
capacity profile. The current build profile uses Qt 6.12.0 MSVC 2022, GStreamer
1.26.11 MSVC and Python 3.12 with isolated Warden packaging tools. Exact artifact
URLs, hashes, licenses and English/Russian manual instructions are in the catalog.

Compatible existing tools are detected first. Missing tools are downloaded over
HTTPS, verified and prepared in the private cache where possible. Visual Studio
and Windows prerequisites can require administrator approval. No dependency
installer is allowed to reboot automatically. A requested restart is reported
for the operator to perform before resuming.

| Dependency mode | Behavior |
| --- | --- |
| `Auto` | Use compatible existing tools/cache; otherwise download the pinned package. |
| `Manual` | Show the required version, official download links and precise cache destination; wait for the file or cancel. |
| `Offline` | Make no download requests; use verified cache and supplied source; report missing inputs. |

Download failures distinguish endpoint, DNS, TLS, proxy and authorization issues.
The script offers retry, manual provision or cancellation. Cached files retain
their content-addressed names. Copy files to the exact printed destination; do
not rename a different version to make it appear compatible. Interrupted partial
downloads are restarted and reverified, not accepted as complete.

Visual Studio's small bootstrap EXE is **not** a complete offline C++ installer.
For a disconnected build computer, prepare an official Visual Studio offline
layout and install it manually first. Supply the resulting `VsDevCmd` path when
needed. Qt SDKs and runtime libraries can come from the verified dependency cache;
they do not come from an existing Watchtower installation.

Publisher archives may eventually be removed. If an exact pinned package is no
longer published, supply its previously verified cache file or review and update
the catalog. The script never silently replaces the pin with “latest.”

To build offline, also provide either a clean checkout at an explicit full commit
or a Git bundle with a trusted SHA-256:

```powershell
$commit = Read-Host 'Full 40-character source commit'
.\deploy-watchtower.ps1 -Mode Build -DependencyMode Offline `
    -SourceDirectory 'D:\VerifiedSource\cilex-watchtower' -SourceCommit $commit

$sourceHash = Read-Host 'Trusted source bundle SHA-256'
.\deploy-watchtower.ps1 -Mode BuildInstaller -DependencyMode Offline `
    -SourceBundle 'D:\Offline\watchtower.bundle' `
    -SourceSha256 $sourceHash -SourceCommit $commit
```

The supplied checkout must be clean and its HEAD must match `SourceCommit`.
Local/offline source is not called “latest main.” Offline revisions requiring
unprovided Git submodules or LFS content fail rather than building incomplete
source. Automatic provisioning uses MinGit; a future source requiring LFS also
needs a compatible Git LFS installation.

Custom tool locations can be supplied as a PowerShell hashtable:

```powershell
$toolPaths = @{
    QtRoot = 'D:\SDK\Qt\6.12.0\msvc2022_64'
    GStreamerRoot = 'D:\SDK\GStreamer\1.0\msvc_x86_64'
    VsDevCmd = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat'
}
.\deploy-watchtower.ps1 -Mode Build -GhToken $repoToken -Tools $toolPaths
```

Other keys are `Git`, `CMake`, `Ninja`, `Python`, `PkgConfig`, `Makensis`, `FFmpeg`
and `VCRedist`. File-valued keys require absolute executable paths; `QtRoot` and
`GStreamerRoot` require SDK directories. Version/path checks still apply.
Warden packaging uses a separate Python environment; the script does not install
its Python packages into an existing user's interpreter.

## Private repository credentials

Use `-GhToken $repoToken` or its alias `-gh_token $repoToken`, where `$repoToken`
comes from `Read-Host -AsSecureString`. Repository read access is sufficient.
Existing authorized Git credentials can be used without passing a token.
The noninteractive Git operation does not open a login dialog; establish access
first or provide the secure value.

Do not paste a token directly into command history, put it in the repository URL,
save it in a script, or pass it as a plaintext command-line argument. Token values
are not included in the installer, build manifests or remote requests. The
credential helper passes the token only to the expected GitHub authentication
operation; build tools and installation targets do not receive it.

## Network installation

The target must already permit an authenticated administrative connection. The
script does not enable remoting, change firewalls, weaken authentication or change
security policy to establish it.

- `WinRM`: uses Kerberos for hostnames. IP-address connections require an existing
  HTTPS remoting endpoint and suitable certificate/trust configuration.
- `SMBService`: uses the administrative file share and Service Control Manager.
  SMB signing or encryption must already protect the connection. The current
  Windows identity or `Get-Credential` provides administrative access.

For an IP address, supply `-ExpectedHost` with the actual Windows computer name.
The target identity is verified before installation. `-TargetUser` identifies
the desktop account, not necessarily the administrator supplying network access.

```powershell
$admin = Get-Credential
$manifestHash = Read-Host 'Trusted package manifest SHA-256'
$acceptedTargetFindings = @() # Fill only after reviewing target requirements.

.\deploy-watchtower.ps1 -Mode RemoteInstall `
    -PackagePath 'D:\CilexBuild\package' -PackageManifestSha256 $manifestHash `
    -TargetHost 'OFFICE-PC' -ExpectedHost 'OFFICE-PC' `
    -TargetUser 'OFFICE-PC\Operator' -Credential $admin -Transport SMBService `
    -RemoteStagePath '\\OFFICE-PC\C$\CilexWatchtower-Deploy' `
    -InstallDir 'D:\Apps\Cilex Watchtower' `
    -StartupMode AfterSignIn -DeferEnrollment `
    -OverrideRequirements $acceptedTargetFindings
```

For a generated setup EXE, use `-PackagePath 'D:\Installers\...-setup.exe'` plus
its trusted `-PackageSha256` instead. These sample names and hashes must be
replaced with real values.

The administrative share path
`\\OFFICE-PC\C$\CilexWatchtower-Deploy\RUN-ID` refers to
`C:\CilexWatchtower-Deploy\RUN-ID` **on OFFICE-PC**. It is the default staging
directory. `D:\Apps\Cilex Watchtower` is the final local directory on that target.
For an ordinary share, also provide `-RemoteStageLocalPath` with the verified
corresponding target-local directory. Running Watchtower directly from a UNC
share is unsupported.

The staging folder and its parents must already be safe from modification by
ordinary users; new folders receive administrator-only permissions. Custom share
paths are checked against their actual Windows location. For example,
`\\OFFICE-PC\C$\ProgramData\CilexWatchtower\Deploy` maps to
`C:\ProgramData\CilexWatchtower\Deploy`, but standard ProgramData permissions
can make that location unsuitable. Unsafe paths are refused without changing
their permissions. Use the default staging path instead.

Remote helpers cannot answer interactive requirement prompts. Run `Check` on the
target first when practical, review the findings and pass their accepted IDs.
Otherwise, the initial remote preflight can stop with the findings requiring
acceptance; resolve or explicitly accept them before retrying. Source access and
the build happen on the initiating computer; the GitHub token is not transferred.

If a connection drops, keep the reported run ID and result paths. Use
`-ResumeRunId` to reconcile that remote run. A run without a completed result is
not blindly relaunched. Inspect its state before starting another operation.

```powershell
.\deploy-watchtower.ps1 -Mode RemoteInstall `
    -TargetHost 'OFFICE-PC' -ExpectedHost 'OFFICE-PC' `
    -TargetUser 'OFFICE-PC\Operator' -Credential $admin -Transport SMBService `
    -InstallScope User -InstallDir 'D:\Apps\Cilex Watchtower' `
    -StartupMode AfterSignIn `
    -ResumeRunId 'PREVIOUS-RUN-ID'
```

Repeat the original target account, installation scope, startup mode and any
custom installation/staging paths. A prior verification run also requires
`-VerifyOnly`; that mode does not need a startup choice. If supplied, the package
manifest hash must match the original request. Reconciliation checks the protected
records and live target identity before reading the earlier result; it does not
require source code or a package and never starts a second install. An unknown or
incomplete outcome is refused. `ResumeRunId` is separate from a new `VerifyOnly`
check.

If remote access cannot be established, transfer the offline installer and run
it locally under the intended account.

### Adopting a pre-existing Office installation

Ordinary upgrades recognize the marker created by this generic installer. A
pre-existing installation without that marker is not overwritten by default.
The explicit adoption route is:

```powershell
# Add these arguments to the reviewed local/remote installation command:
-AdoptExisting -LegacyTaskName 'wt-warden'
```

Adoption is limited to the supported native-Warden layout and an existing
interactive task that launches that exact Warden with `run`. It verifies the
account, paths and competing startup tasks, saves the prior setup, and rejects
ambiguous ownership. The current Python-Warden Booth arrangement is not an
automatic adoption target. Do not use adoption just to silence a directory or
ownership error. Labs pauses/holds and unrelated services remain outside scope.

## Startup and unattended reboot

Choose `-StartupMode AfterSignIn` to start Warden when the designated account
signs into Windows. A native launcher keeps the Warden/Watchtower process group
together; Warden launches Watchtower visibly in that desktop. The scheduled task
checks every minute and ignores an overlapping start. The launcher prevents a
failed supervisor from leaving the old application running beside a replacement.
This choice alone does not make a logged-out computer show the camera wall
after reboot.

The scheduled task starts a small native launcher that keeps Warden and
Watchtower together. If that launcher or Warden stops, the old process group is
closed before recovery. The task checks every minute and ignores extra starts
while it is already running. An update restores the original task's enabled or
disabled state if it has to roll back.

Choose `-StartupMode UnattendedReboot` only when automatic Windows sign-in is
intended. Setup requires specific consent because the account's desktop becomes
available after reboot. `-ConsentUnattended` records that choice for this run;
it is not a password and does not create automatic sign-in by itself.

The implementation checks public automatic-sign-in settings and provides the
official [Microsoft Autologon](https://learn.microsoft.com/sysinternals/downloads/autologon)
route when setup is needed. With `-AutologonPath`, it verifies the Microsoft
signature and opens the approved tool for interactive credential entry. Enter
the password only in that tool's window. Missing consent, a logon notice,
unavailable interactive setup or unconfirmed sign-in settings remain explicit
deferred/blocked startup states. No password value or LSA secret is read back.
If the approved sign-in tool cannot configure the account, leave setup incomplete
and use an operator-approved Windows route. The deployment does not change the
account password or security policy to make setup succeed.

The script never reboots automatically. After an operator-authorized reboot,
verify the installation without rebuilding or reinstalling:

```powershell
.\deploy-watchtower.ps1 -Mode Install -VerifyOnly `
    -InstallDir 'D:\Apps\Cilex Watchtower' -TargetUser 'COMPUTER\Operator'
```

Add `-ConfirmNoManualSignIn` only after observing that nobody signed in manually
after that reboot. This confirmation, a new boot, verified public automatic-sign-in
settings and a visible healthy desktop are all required for `RebootVerified=true`.
Without that evidence, successful processes alone leave automatic startup unproven.

The remote equivalent uses `-Mode RemoteInstall -VerifyOnly` and the same target
and transport information. Runtime verification checks owner, Windows session,
Warden parentage and stable startup. Configured stations must also show advancing
video; a fresh offline station may need login and camera configuration before
video can be verified. A new boot timestamp proves that a restart occurred;
automatic sign-in still requires the corresponding configuration and desktop
evidence.
An older installation record is ignored when it does not match the currently
installed package; current runtime checks still run, but reboot verification
remains incomplete.

During installation from another Windows session, a temporary task checks the
window in the intended user's desktop and is then removed. A blocked observer or
unconfirmed cleanup is reported as a deferred check. Read-only `VerifyOnly` never
creates that task: run it in the intended desktop to verify window visibility.
Remote read-only verification can confirm processes and video while leaving
window visibility and complete unattended startup unverified.

Existing station credentials and settings are preserved. A deferred backend or
enrollment check does not mean an existing working station needs a new token.

Source acquisition was additionally exercised against the private repository:
the existing `windows-latest` tag resolved to
`73ef50c7419aeec59faa48453df80857289998fe` (version 1.1.44), and a nonexistent tag
was refused without fetching or checking out main. This verifies tag selection,
not the build compatibility of that historical release.

## Results, repair and limitations

Every changing run records `work\RUN-ID\result.json`. Read that file first after
an interruption or error. It identifies the selected source, product versions,
checks, accepted warnings, artifacts, installation result and remaining work.
Detailed logs are stored alongside it. Installer and bootstrap output have
separate hash records. Keep them with the files when transferring to another PC.
Each captured tool log is limited to two million characters, retaining the start
and end if truncated. Run records, build trees and rollback backups are preserved
for review; remove obsolete runs deliberately after their outcome is confirmed.

| Exit code | Meaning |
| --- | --- |
| `0` | Requested check/build/installer operation passed its implemented checks. |
| `2` | Warnings or deferred verification/configuration remain. |
| `3` | Cancellation or a required interactive choice/plan is missing. |
| `10` | Requirements blocked or explicit warning acceptance is missing. |
| `11` | Dependency preparation failed. |
| `12` | Source acquisition failed. |
| `13` | Build or packaging failed. |
| `14` | Local/remote installation failed. |
| `3010` | A prerequisite requires an operator-controlled Windows restart. |
| `1` | General validation or other unclassified failure. |

Windows prerequisite helpers can additionally report restart-required state.
Consult the retained result before retrying; do not infer success solely from a
new executable appearing on disk. Installation currently returns a deferred
summary while backend enrollment and reboot verification are separate.

Updates stage and verify new files before replacement and preserve rollback data.
Failures attempt to restore the prior owned installation and startup setup.
Only the identified installation's processes/tasks are controlled. A partial
dependency extraction is preserved for inspection rather than overwritten
silently. Another deployment sharing the work directory or cache is refused
while the corresponding lock is held.

Use Windows Installed Apps/Add or Remove Programs for the registered uninstaller.
It removes owned program/startup resources and preserves settings by default.
Modified or unrecognized files are retained rather than forcibly deleted. Shared
prerequisites are not removed automatically. This version does not provide a
general “erase all station data” option.

Run the safe fixture suites from the repository with
`packaging\windows\generic\tests\run-tests.ps1`. Supply `-PythonPath` and
`-MakensisPath` to include runtime-closure and compiled installer checks. Supply
`-VsDevCmdPath` to compile and test the native startup launcher. The runner
reports these optional checks as skipped when their tool paths are absent.
These tests use temporary fixtures; they do not install on a station or reboot it.

The script's test gates include package integrity, dependency closure, isolated
startup and controlled media export/decode checks. They do not establish every
GPU, camera codec, Windows edition, backend or future operating condition.
Fresh-machine/offline and reboot validation require the corresponding test
environment; hardware guidelines must not be described as measured minima.

The detailed requirements are in the
[technical specification](../../../docs/plans/2026-10-13-generic-windows-deployment-specification.md).

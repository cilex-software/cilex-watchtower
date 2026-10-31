# Technical specification: generic Cilex Watchtower deployment for Windows

Status: implementation available; acceptance testing is incomplete. See the
[implementation guide](../../packaging/windows/generic/README.md) for current
behavior, verification evidence and remaining limits.
Date: 13 October 2026.

Operator update, 31 October 2026: the normal installation experience MUST be a
graphical wizard; the command-line interface remains an advanced interface.
[Section 17](#17-graphical-wizard-and-office-installation-lessons) records the
required experience and lessons from the successful Office deployment.
The full wizard is a future implementation task, not a completed feature.

## 1. Objective and scope

Create a separate deployment script that prepares a Windows build computer,
obtains Cilex Watchtower source code, builds Watchtower and Warden, and installs
them locally or on another Windows computer. It must also produce a single
self-contained offline installer when requested.

The existing `packaging/windows/deploy/build-and-update.ps1` remains unchanged.
It maintains the already configured Security Booth and Office stations and is
not the foundation of a claim that fresh-machine installation already works.

The new script must not depend on Booth/Office names, addresses, accounts,
installed applications, runtime libraries, saved credentials or startup tasks.
Reusable existing components may be adapted only after their assumptions have
been checked against this specification.

MUST denotes a mandatory requirement. SHOULD denotes a recommended behavior
whose omission must be documented. The examples below describe the design
contract; the implementation guide records available commands and remaining gaps.

## 2. Operating modes and initial bootstrap

The entry point is provisionally named `deploy-watchtower.ps1`.

It MUST support these explicit modes:

| Mode | Required outcome |
| --- | --- |
| Check | Inspect requirements and access without changing the system. |
| Build | Fetch and build the selected source, then test and retain the artifacts. |
| Install | Build and install locally, or install a supplied verified package. |
| RemoteInstall | Build locally, transfer a verified package and install on the specified target. |
| BuildInstaller | Build a single offline installer without installing Watchtower on the build computer. |

The build computer and installation target MUST be assessed separately.
A remote target receiving a package MUST NOT need Git, a compiler, a Qt SDK,
Python, or a GitHub token. Warden's packaged runtime must be included.

A small Windows PowerShell 5.1-compatible bootstrap MUST work on the supported
Windows baseline. It may provision a pinned compatible PowerShell 7 version
before handing over to the main implementation. It MUST NOT assume that
PowerShell 7, Git, winget or Chocolatey is already installed.

The bootstrap and its initial dependency manifest MUST be available as a
standalone trusted download or supplied bundle. Obtaining them must not require
an existing repository checkout. The README must explain how an authorized
user obtains this bundle while the repository is private.

Interactive operation is the default. Noninteractive operation MUST require
all necessary inputs and fail clearly instead of waiting indefinitely.
An explicit preview option MUST describe intended changes without applying them.
Check and preview MUST NOT download/install dependencies or write files, even
in the initial bootstrap. Use the built-in assessment capability or report
which checks cannot be completed without additional tools.

## 3. Platform and hardware assessment

### 3.1 Requirements manifest

Maintain a versioned, machine-readable requirements and dependency manifest
for each supported source/toolchain combination. Record architecture, minimum
OS build, build tools, runtime components, compatibility rules, workload
assumptions, capacity thresholds, download information and verification data.

The initial implementation targets Windows x64. The current project uses
MSVC 2022 and Qt 6.12.0. Other architectures, including ARM64, and Windows
Server editions require explicit validation before being marked supported.

Qt 6.12 lists Windows 10 version 1809 or later and Windows 11 for x64.
That is a dependency baseline, not proof of Watchtower compatibility. The
effective minimum MUST satisfy Watchtower, every bundled runtime, the selected
PowerShell bootstrap and any required build tools. Build-host and runtime-target
OS floors may differ. Windows support/lifecycle status must be distinguished
from the ability to execute the application.

No measured Watchtower-wide minimum RAM, CPU or camera capacity is currently
established. The implementation task MUST establish and publish tested runtime
and build thresholds before describing them as validated minimum requirements.
Until measured, thresholds must be labeled provisional and results uncertain.
Do not invent a minimum from the specifications of one working station.

### 3.2 Required checks

Before downloading large packages or changing an installation, inspect:

- Windows edition, version, build, native architecture and process architecture.
- CPU capabilities required by the selected binaries, core count and available
  build capacity. Do not require a particular CPU brand without evidence.
- Installed and currently available RAM; distinguish physical capacity from
  temporary memory pressure caused by other applications.
- Free space on every volume used for downloads, temporary extraction, source,
  build output, installation and rollback backups.
- The target's graphics adapter, driver, usable rendering path and relevant
  video-decoding capabilities. A compiler-only host need not have a video GPU.
- The intended desktop account, profile, interactive session, target-directory
  permissions and ability to create the required startup task.
- Reboot-pending conditions that can prevent dependency installation or use.
- Access to required download endpoints, repository and configured backend,
  reporting these as separate checks.

Disk estimates MUST include peak simultaneous usage: remaining downloads,
extracted dependencies, source/build output, installation staging, previous
installation backups and a documented reserve. Recheck before extraction and
replacement. Do not describe a fixed arbitrary disk number as universally
sufficient for every mode.

Runtime suitability MUST reference a workload: simultaneous streams,
resolution, codec, frame rate and monitor layout. Unknown workload means
capacity is unverified. Installation checks MUST NOT silently change camera
settings, lower frame rates, change drivers or run disruptive benchmarks.

### 3.3 Warnings and overrides

Each finding MUST include what was detected, what is required, the practical
effect, and one clear next action. Use concise PASS, WARNING, BLOCKED or UNKNOWN
states with translated labels; never treat an unreadable check as a pass.

Users MUST be able to continue despite unmet declared or provisional minimum
RAM, CPU, graphics-capacity and OS-support requirements, as well as unmet
recommendations, where an actual installation attempt is technically possible.
This includes an unsupported-but-potentially-runnable Windows version. Interactive
operation requires an explicit choice; noninteractive operation requires an
explicit override listing the accepted finding identifiers. Record the choice
without recording secrets. Do not repeatedly ask about the same finding.

An override permits an installation attempt; it cannot make an impossible
operation succeed. A 64-bit binary cannot run on Windows 98 or 32-bit Windows.
Insufficient writable space for the actual payload, missing OS APIs, denied
access, invalid package integrity and security-policy rejection remain real
failures. Explain them and preserve existing installations. The user may still
build/package for another compatible target where possible.

If the bootstrap itself cannot run on an old OS, the documentation must state
that limit; the script cannot promise to display a warning on every historical
Windows release. An override MUST NOT disable security controls or convert a
failed verification into success.

## 4. Language and command-line experience

Select Russian when the initiating user's Windows display/UI language is
Russian; otherwise select English. Use the system UI language only when no
user language is available. Do not infer language from keyboard layout,
geographical location or date formatting.

Provide `-Language Auto|en|ru`. Preserve the chosen language across elevation;
remote deployment messages use the initiating user's language. A standalone
installer uses the target user's language or its explicit override.

All prompts, summaries, dependency instructions and actionable errors MUST be
available in both languages. Paths, product names and version numbers remain
unchanged. Support Cyrillic account names and paths.

Examples of the required message style:

> EN: Available memory is below the requirement for this build. Close other
> applications and check again, continue anyway, or cancel.

> RU: Для сборки недостаточно свободной памяти. Закройте другие программы
> и повторите проверку, продолжите на свой риск или отмените установку.

> EN: The download server is unavailable. Restore the connection and retry,
> provide the required files manually, or cancel.

Normal output MUST show the current stage, essential progress, findings and
next action. Put detailed diagnostics in a separate redacted log. Cancellation
must stop safely and explain what, if anything, has already changed.

## 5. Automatic dependencies and offline recovery

Separate fundamental platform requirements from downloadable prerequisites.
Windows compatibility is a platform requirement; Qt, GStreamer and compiler
tools are dependencies that can usually be provisioned.

Detect compatible existing dependencies first. Automatically download and
install missing required components after the user accepts the installation
plan and any required license terms. Show substantial download/disk estimates
before proceeding. Do not upgrade unrelated tools or alter global PATH when
an isolated tool directory or per-process environment is sufficient.

The dependency set MUST follow the selected source revision. For the current
project this includes Git; compatible PowerShell; MSVC C++ build tools and
Windows SDK; CMake, Ninja and pkg-config; Qt and required modules; matching
GStreamer MSVC runtime/development files; Python and pinned Warden packaging
dependencies; and the installer compiler when producing an installer.
The runtime bundle must also include the multimedia/export components actually
used by Watchtower.

Every dependency entry MUST contain:

- Exact supported version, architecture and required components.
- Official download page and a verified version-specific package URL or
  authenticated vendor retrieval method; do not guess download filenames.
- Expected integrity information and publisher checks where available.
- Detection, installation and post-installation verification procedures.
- Download and extracted sizes, license terms and reboot behavior.
- A concise manual-install instruction in English and Russian.

Pin validated versions. Do not substitute a vendor's unrelated newest release
because a pinned download is unavailable. Respect licensing and redistribution
conditions; if access or acceptance cannot be automated, explain that step.

Use HTTPS with certificate validation, bounded timeouts and limited retries.
Distinguish DNS, proxy, TLS, authorization and missing-file failures from a
general absence of internet. Support existing approved proxy configuration;
never disable TLS verification. Validate cached and downloaded files before use.

When a required download cannot be obtained, offer:

1. Restore the connection and retry.
2. Install the dependency manually or provide an offline package/cache.
3. Cancel safely.

For manual recovery, show only missing items, with exact required versions,
architectures, clickable official URLs, necessary installer options and a
short verification command. Allow files to be downloaded on another computer
and transferred. Recheck compatibility and integrity before continuing.

Offline mode MUST make no internet requests. With an incomplete cache it must
list missing files and stop or wait for manual provision. Missing source code
also requires a verified source bundle or previously fetched exact revision.
A cached checkout cannot be described as the latest main without fetching it.

Dependency installers MUST use no-restart behavior. If a prerequisite needs
a reboot before work can continue, save resumable state without credentials,
report the requirement and wait for a user-controlled restart.

## 6. Private GitHub access and source selection

Default repository: `https://github.com/romayankin/cilex-watchtower.git`.
Default source: the current remote `main` at the time of a successful fetch.
Provide `-Tag` to select an exact GitHub/Git tag instead.

Resolve the chosen branch or annotated/lightweight tag to a full commit SHA
once, record it, and build that exact revision. Fetching a later commit during
the same run must not silently change the build. Never fall back from a missing
tag to main. Obtain required submodules/LFS content if the revision uses them.

Accept `-GhToken`, with `gh_token` as an alias, through a protected in-memory
input such as a PowerShell SecureString. Support a masked prompt and existing
authorized Git credential mechanisms. Repository-read permission is sufficient;
the script must not request write permission merely to build.

Never place a token in a clone URL, command-line string, example, transcript,
Git configuration, diagnostic log, artifact or installer. Do not persist a
token unless the user explicitly selects a supported credential store.
Pass credentials only to the authentication operation that needs them; do not
forward the repository credential to build processes or installation targets.
Do not forward authorization headers across untrusted redirects.

Expired tokens, denied repository access and organization authorization
requirements must produce specific concise guidance. No token is required on
a target installing an already-built offline package.

## 7. Build and artifact creation

Use a clean, uniquely identified checkout and build directory. Preserve any
existing checkout and uncommitted changes. Source acquisition and building
MUST NOT commit, push, tag or modify the remote repository.

Use the selected revision's supported configuration, normally the current
Windows MSVC preset. Build Watchtower and a matching packaged Warden. Never
combine arbitrary versions merely because executable filenames match.

Limit parallel build jobs according to available resources, allow an explicit
override and use reduced priority where appropriate. No existing Watchtower
installation may be required as the source of runtime DLLs.

Create a manifest containing source/tag/commit, product versions, architecture,
OS requirements, dependency versions, file hashes, build configuration, test
results and timestamp. Exclude credentials and private configuration.
Preserve symbols separately for diagnosis. Record provenance without promising
byte-identical builds unless reproducibility has actually been demonstrated.

Build failure or failed artifact verification MUST prevent deployment.

## 8. Local installation and default directories

Default to a per-user installation at:

`%LOCALAPPDATA%\Programs\Cilex Watchtower`

Resolve this through Windows known-folder/profile information for the intended
desktop user, not whichever administrator supplies an elevation credential.
This matches the existing product convention and avoids unnecessary elevation.

Support a custom absolute local directory through `-InstallDir`.
Offer explicit `-InstallScope Machine`, defaulting to
`%ProgramFiles%\Cilex Watchtower`, when an all-users binary installation is
required. Machine scope does not create multiple simultaneous Warden instances.
The designated desktop account remains explicit.

Keep binaries separate from writable settings, logs and station credentials.
Preserve existing application data locations and apply appropriate permissions.
Standard users must not be able to replace machine-wide executable files.

Validate destination paths, free space, permissions, reparse-point behavior
and ownership. Refuse drive roots, profile roots, Windows directories and
unrelated occupied directories. Running installed binaries from a network
share is outside the initial scope; remote targets receive local installations.

An existing installation must be recognized and handled as an update or repair,
with its version, settings, startup configuration and rollback data preserved.
Never recursively delete an arbitrary user-selected directory.

## 9. Remote installation

Support explicit target hostname/address, designated desktop account, remote
administrator credential, transport and optional staging directory.
Verify the remote hostname/identity and its requirements before deployment.
An SMB file-copy success alone does not prove permission to install remotely.

Support authenticated PowerShell remoting where already configured, and an
explicit SMB plus Service Control Manager route equivalent in purpose to the
existing Office deployment. Use unique, bounded helpers and remove only
helpers created by the current run. Do not execute the camera UI as SYSTEM.

Require an authenticated, integrity-protected administrative channel; do not
automatically open firewall ports, enable insecure authentication, disable
remote-account restrictions or change organizational security policy. When
remote access is unavailable, provide the offline installer and concise local
installation instructions as the fallback.

Example staging location:

`\\OFFICE-PC\C$\ProgramData\CilexWatchtower\Deploy\RUN-ID`

The same directory on OFFICE-PC is:

`C:\ProgramData\CilexWatchtower\Deploy\RUN-ID`

`C$` is an administrative share requiring suitable remote rights. A supplied
ordinary share may also be used if its corresponding target-local path is
explicitly known and verified. The final installation directory is a local
path on the target, for example `D:\Apps\Cilex Watchtower`.

Build once on the build computer, transfer and verify the package, execute the
installer on the target, configure Warden for its intended user, then retrieve
a run-bound result. The build computer's GitHub token must never be transferred.

A dropped connection means completion is unknown until reconciled using the
saved run identifier and target state. Reconnecting must not blindly launch a
second installation or restart a completed deployment.

## 10. Self-contained offline installer

`-Mode BuildInstaller` MUST produce a single installer file, provisionally:

`CilexWatchtower-VERSION-windows-x64-setup.exe`

The installer MUST contain Watchtower, native packaged Warden, Qt libraries,
required QML modules/plugins, GStreamer libraries/plugins and their transitive
dependencies, required playback/export components, an appropriate Visual C++
Redistributable where needed, language resources and license notices.

Self-contained means installation and local application startup on a supported
clean machine require no internet, developer tools, separate Qt installation,
Python installation or GitHub access. It does not mean cameras/backend work
without network access, and does not mean Windows or GPU drivers are bundled.
Installer helpers MUST use an execution engine present on the supported Windows
baseline or included in the package; they must not secretly download PowerShell
or Python during offline installation.

Use supported Qt deployment tooling and explicitly collect non-Qt dependencies.
Missing required libraries, plugins or export tools MUST fail packaging rather
than produce a nominally successful but incomplete installer. Include no
station credentials, developer settings, absolute SDK references or build secrets.

Include an uninstaller, Add/Remove Programs registration, version information,
payload integrity checks, repair/update behavior and safe rollback. Preserve
user settings by default during uninstall; delete them only through an explicit
user choice. Shared prerequisite packages must not be removed automatically.

Support trusted code signing when a signing identity is supplied, with a clear
unsigned result otherwise. Do not claim that an unsigned file will necessarily
be admitted by every Windows security policy. Never weaken policy to install it.

## 11. Warden, privileges and startup after reboot

Install Warden with every Watchtower installation and configure it to supervise
the exact installed Watchtower executable under the designated desktop account.
Verify both identity and Windows session; do not match processes by name alone.

Detect actual elevation and required permissions. Membership of Administrators
does not by itself mean the current process has an elevated token. Request
Windows UAC approval only for operations requiring it. Preserve the original
target account/profile if another administrator supplies credentials. Never
request a password as an unmasked argument or attempt to bypass UAC.

Use an interactive scheduled task with an explicit executable and working
directory, an account-specific sign-in trigger, restart-on-failure settings,
periodic recovery and single-instance protection. Watchtower must run visibly
in that account's desktop session with ordinary user privileges.

Windows services run separately from the interactive desktop. A boot-triggered
SYSTEM task/service does not by itself provide a visible camera wall.

The installer MUST explain and collect an explicit startup choice:

- `AfterSignIn`: Warden starts when the designated user signs into Windows and
  launches Watchtower. A reboot alone does not restore the camera wall.
- `UnattendedReboot`: the designated user must automatically sign in after
  boot, after which Warden launches Watchtower. The installer must help set up
  or verify an approved automatic-sign-in mechanism; a logon task alone is
  insufficient.

Do not silently substitute AfterSignIn when UnattendedReboot was requested.
For unattended operation, explain that automatic sign-in opens that account's
desktop, obtain specific consent, and use an approved Windows mechanism and
protected credential entry/storage. Never store passwords in script text,
arguments, logs, manifests or plaintext Winlogon values. Never read back an
existing stored password. Administrator-accessible secret storage must not be
described as inaccessible to administrators.

If policy, account type, interactive authentication, a logon notice or another
condition prevents automatic sign-in, report the exact limitation and the
supported next step. Do not weaken those controls automatically. Declined
elevation or consent must produce a clear incomplete-startup result.

Do not reboot automatically. Record startup as ConfiguredButUnverified until
an explicitly authorized reboot/sign-in test proves the requested behavior.
Resume verification after the test without repeating installation.

## 12. Backend configuration and station identity

Request the backend address and necessary station registration information,
unless installing offline for later configuration. Do not hardcode a pilot
server or reuse another station's token.

Keep GitHub authentication, remote Windows administration, Windows sign-in,
Watchtower application login and Warden station authentication separate.
Store station secrets only in an appropriately protected target-local store
compatible with the application; never embed them in distributable installers.

Verify backend connectivity and registration through supported APIs. A missing
station credential may leave local supervision working while reporting is
unavailable; show those results separately. Offline installation must explain
how to complete enrollment later.

Windows automatic sign-in does not authenticate the user to the backend.
Use the application's supported enrollment and session-refresh behavior;
never embed a shared backend administrator password. Report expired/missing
application authentication separately from successful Windows/Warden startup.

Labs workers, camera configuration, remote-access products and unrelated
services are outside this script's default scope. Preserve existing operator
pauses and holds.

## 13. Safe installation, recovery and results

Use per-installation locks and unique run identifiers. Stage and verify files
before changing a working installation. Back up replaced files and affected
startup configuration, then apply a recoverable transaction.

Control only processes and tasks belonging to the intended installation,
account and session. Bind process operations to verified creation times or
retained handles to avoid affecting a reused process ID. Never terminate all
processes named watchtower.exe, warden.exe or python.exe.

If deployment or verification fails, restore the previous installation and its
startup arrangement where possible. For a first install, remove only newly
created owned resources or leave a clearly reported resumable partial install.
Do not remove shared dependencies. If recovery cannot be verified, report that
explicitly and stop further destructive action.

Support safe reruns and reconciliation after interruption. Preserve user data,
unrelated tasks, other application installations and existing security policy.

Emit a concise summary and a redacted structured result containing run ID,
target, source commit, versions, paths, checks, accepted warnings, installation
state, startup state, backend state and recovery information. Use documented
exit codes distinguishing success, warnings/deferred verification, cancellation,
failure and restart required. Never report full success when a requested mode
is incomplete. Bound log retention and expose the result/log paths.

## 14. Verification and acceptance criteria

The implementation is accepted only after the following are demonstrated:

1. Fresh supported Windows x64 installation with no developer tools: bootstrap,
   dependency provisioning, authenticated source checkout, build and local
   installation complete without manual path repair.
2. Latest main and an exact tag produce the recorded source revision and
   matching Watchtower/Warden versions. Invalid tags and denied access fail
   clearly without silently choosing another source.
3. Russian and English messages, Cyrillic usernames, spaces in paths and
   alternate-administrator elevation preserve the intended target account.
4. Hardware/OS warnings allow explicit overrides; unknown checks remain
   unknown; genuine execution, integrity and access failures remain failures.
5. Missing dependencies install automatically; interrupted downloads resume
   safely; manual/offline packages are revalidated; bad hashes are rejected.
6. The installer works on a clean target with internet disabled and without
   Git, Qt SDK, Python or compiler tools. Confirm no libraries are accidentally
   loaded from developer directories or the build computer's PATH.
7. Test real rendering, live decoding, representative playback and export using
   controlled fixtures. Confirm HTTPS/backend functionality when applicable.
   A process merely remaining alive is insufficient evidence.
8. On configured test stations, verify correct Warden parentage and desktop
   identity, at least 150 seconds of stable startup, and advancing video for
   the expected feeds. Fresh offline installations report backend/video checks
   as deferred until configuration permits them.
9. Prove remote installation, remote privilege refusal, target mismatch,
   transfer corruption and connection-loss reconciliation without duplicate jobs.
10. Prove failed-update rollback, cancellation, repeated invocation, custom
    paths and preservation of unrelated processes, settings and tasks.
11. Prove AfterSignIn and UnattendedReboot behavior using authorized reboot
    tests on disposable or designated test machines. Validate recovery from
    a Warden/app failure in that test environment. Do not run crash drills on
    an active guard station.
12. Check all logs, process arguments, manifests and installer contents for
    credential leakage, using disposable test secrets and preserving no secrets
    in test reports.

Publish the tested OS/build matrix and workload limits. Distinguish passed,
failed and untested cases. Replace any claim of flawless operation with these
measurable acceptance results and remaining limits.

## 15. Proposed interface and examples

Required options, with validated mutually compatible parameter sets:

| Option | Purpose |
| --- | --- |
| `-Mode` | Check, Build, Install, RemoteInstall or BuildInstaller. |
| `-Repository` / `-Tag` | Repository and exact tag; omit Tag for freshly fetched main. |
| `-GhToken` / `-gh_token` | Protected repository credential, never a plaintext example. |
| `-PackagePath` | Install an existing verified offline package without building. |
| `-InstallDir` / `-InstallScope` | Target-local destination; User or Machine scope. |
| `-TargetHost` / `-TargetUser` | Remote computer and intended desktop account. |
| `-Credential` / `-Transport` | Protected remote credential and supported transport. |
| `-RemoteStagePath` | Optional verified UNC staging location. |
| `-StartupMode` | AfterSignIn or UnattendedReboot; prompt if omitted interactively. |
| `-BackendUrl` | Explicit backend address or defer configuration. |
| `-Language` | Auto, en or ru. |
| `-DependencyMode` | Auto, Manual or Offline. |
| `-CacheDir` / `-WorkDir` / `-OutputDir` | Separate package cache, build workspace and output. |
| `-OverrideRequirements` | Accepted finding identifiers for unmet minima or recommendations that permit an attempted installation. |
| `-NonInteractive` / `-WhatIf` | Unattended invocation or change-free preview. |

Illustrative future PowerShell commands:

```powershell
# Build main and install locally; obtain the private-repository token securely.
$repoToken = Read-Host 'GitHub token' -AsSecureString
.\deploy-watchtower.ps1 -Mode Install -GhToken $repoToken

# Build an offline installer from an existing exact repository tag.
$releaseTag = Read-Host 'Exact release tag'
.\deploy-watchtower.ps1 -Mode BuildInstaller -Tag $releaseTag `
    -GhToken $repoToken -OutputDir 'D:\Installers'

# Install an already-built package on another computer.
$remoteLogin = Get-Credential
.\deploy-watchtower.ps1 -Mode RemoteInstall `
    -PackagePath 'D:\Installers\CilexWatchtower-VERSION-windows-x64-setup.exe' `
    -TargetHost 'OFFICE-PC' -TargetUser 'OFFICE-PC\Operator' `
    -Credential $remoteLogin -Transport SMBService `
    -RemoteStagePath '\\OFFICE-PC\C$\ProgramData\CilexWatchtower\Deploy' `
    -InstallDir 'D:\Apps\Cilex Watchtower' -StartupMode AfterSignIn
```

VERSION and machine/account names are placeholders. The README must explain
that these examples become usable only after implementation and must use an
actual existing tag/package. UnattendedReboot must guide the user through its
separate sign-in setup; merely changing the option must not claim success.

## 16. Deliverables and open validation work

Deliver the separate bootstrap/entry script, implementation modules, versioned
requirements/dependency manifests, localized messages, installer definition,
automated tests, verification records and an English README with examples.
Include manual/offline recovery, remote access prerequisites, permissions,
startup choices, credential handling, rollback and uninstall instructions.

Before implementation can be declared complete, establish the measured hardware
and workload thresholds, exact supported OS matrix, redistributable dependency
set and a tested unattended-sign-in integration. These are required engineering
outputs, not facts already proven by this specification.

Historical scope: the request that produced this specification authorized
documentation only. The operator subsequently authorized implementation and
specific Office installation/startup tests. Follow the current task's explicit
permissions and the [verification record](../verification/2026-10-13-generic-deployment/README.md)
for what was actually attempted and what remains unverified.

## 17. Graphical wizard and Office installation lessons

### 17.1 Operator decision and implementation status

On 31 October 2026, after the Office update was verified, the operator asked
to retain this experience for generic Windows installations: a simple wizard,
similar in experience to the Cilex Vision server installer, avoiding manual
configuration. This is a durable product requirement for future installer work.
It changes the primary user interface described above; the existing technical,
integrity, credential and recovery requirements still apply.

The current `generic/installer.nsi` provides directory/install screens, but
its helpers still use console prompts and may open an external sign-in tool.
It is not the complete wizard requested here. Office's successful update is
evidence for its deployment engine, not proof of a fresh-machine wizard.
This update records requirements only; it does not implement or deploy a wizard.

### 17.2 Normal installation experience

Provide one versioned setup EXE containing Watchtower, Warden and their runtime
dependencies. Prefer a trusted signed production installer; verify its payload
and helpers internally. The normal target PC must not require source checkout,
developer tools, a Qt SDK, Python installation or a GitHub token. Keep building
latest `main` or an exact tag as an advanced build-computer operation.

The default path is open setup, review the detected choices, Install, Finish.
Display only screens requiring a real decision; preserve existing choices on
updates. The wizard MUST support these steps without opening a terminal:

| Step | Required behavior |
| --- | --- |
| Destination | Choose **This computer** by default, or **Another computer**. Detect an existing owned installation and offer update/repair. |
| Checks | Assess OS, memory, disk and required components automatically. Group actionable warnings once, retaining the existing explicit override rules. |
| Account and folder | Detect the intended desktop user and existing folder. Default new installs to that user's `%LOCALAPPDATA%\Programs\Cilex Watchtower`; custom paths and machine scope are advanced choices. |
| Server and sign-in | Preserve an existing working server/identity. Ask only for missing information through protected fields and supported enrollment. Offer clearly labeled setup-later when offline. |
| Startup | Explain **After Windows sign-in** versus **Automatically after restart**. Collect the necessary consent and guide supported sign-in setup inside the flow. |
| Install and finish | Show essential progress, request UAC only when needed, install both products, verify startup/video and show the actual outcome. |

Use Russian for Russian Windows display language, English otherwise, with a
language switch. Use short practical messages. Ordinary installation must not
require copied PowerShell commands, manually entered checksums, edited config
files/environment variables, task editing or successive repair ZIP overlays.
Put technical diagnostics behind Details and provide one redacted **Copy support
summary** action. Keep the existing CLI for advanced use and support.

### 17.3 Accounts, remote installation and permissions

Preserve the selected desktop account across elevation, even when a different
administrator approves UAC. Install Warden to launch the exact Watchtower in
that user's interactive desktop, with ordinary application privileges.

For remote installation, collect one computer address and display the verified
target identity. Infer internal connection/hostname/staging settings where
possible; users must not fill in duplicate `TargetHost`/`ExpectedHost` fields.
Explain any custom network path with an example such as
`\\OFFICE-PC\C$\CilexWatchtower-Deploy`; distinguish temporary transfer from
the final target-local folder. Use protected administrator credential entry.
If approved remote access is unavailable, offer the same complete setup file
for local execution on the target. Do not retry guessed credentials or loosen
network/security settings to make remote access work.

Handle script-policy restrictions within the wizard's supported execution
path. When an allowed process-only exception is needed, explain it and obtain
explicit consent there. Do not require manual policy commands, change saved
policies or bypass organisation/application-control restrictions. A signature
alone does not prove every enforced policy will admit the package.

Windows sign-in, application login, station enrollment, remote administration
and source-repository access are distinct. Label them clearly and never copy
another station's token. Detect unsupported automatic-sign-in conditions,
including the Office blank-password account/tool limitation, before claiming
unattended readiness. Do not set a password or change account policy silently.
Offer an explicit supported alternative or report setup incomplete; never
silently downgrade the requested startup mode. Do not reboot automatically.

### 17.4 Engineering lessons that must survive the new interface

- Reuse the verified transactional engine. Stage and validate before downtime,
  retain recovery information, and preserve settings, station identity, logs,
  operator pauses/holds and unrelated services or jobs.
- Retain exact owned process handles before stopping startup. Support the
  observed launcher → Warden bootloader → Warden child → Watchtower chain and
  asynchronous teardown. Permit stale exited metadata to settle within a
  bound. Preserve admitted identities into rollback; new/reused/foreign or
  unverified live processes must refuse without being adopted or terminated.
- Interpret documented Task Scheduler XML defaults with independent typed API
  agreement. Missing `Enabled`/`RunLevel` can mean a documented default;
  absent, null and false are not interchangeable. Recognise an old disabled
  startup entry only after verifying that exact definition is inert and owned.
- Generalize the Office-only idle-Labs startup barrier using verified local
  ownership and trusted per-install metadata, rather than copying Office's
  hostnames, accounts, paths or fixed hashes. File-integrity checks remain
  mandatory. Never treat
  stale status alone as current proof. Preserve active work/holds; do not start
  a worker to refresh status. If a verified idle startup entry is paused,
  persist recovery before mutation and restore its exact enabled state without
  starting analyses. Unfamiliar or active work needs a safe explained outcome.
- Preserve Cyrillic names, spaces and encoding. Parse existing key/value
  configuration without treating Windows path backslashes as escape sequences.
  Never print raw credential-bearing configuration to diagnose a failure.
- Package every helper change with its matching manifest and launcher trust
  data. Keep compiled-application provenance separate from deployment-tool
  provenance. Deliver a complete update artifact rather than making ordinary
  users merge helper files or repair trust metadata.
- Use a validated execution engine and controlled module lookup. The current
  Windows PowerShell 5.1 route is tested; the existing PowerShell 7 window-proof
  date-parsing failure must be fixed/tested before adopting that route.

### 17.5 Finish states and acceptance

Finish must distinguish installed versions, current-session startup/video,
server enrollment, unattended startup pending verification, failure with
verified recovery, and recovery needing attention. Save and retrieve these
results automatically, including after remote connection loss. A running
process or successful file copy alone is not successful deployment. Do not
claim automatic return after reboot from a configured logon task.

Acceptance requires the guided flow on a clean supported Windows machine,
offline runtime installation without developer tools, local and remote
install/update/repair/uninstall, Russian/Cyrillic paths, alternate-admin UAC,
policy refusal/consent/cancel, interrupted-install recovery, task XML defaults,
four-process exit/PID reuse, and preservation of credentials/settings/holds.
Configured online stations must pass stable startup and advancing-video checks;
offline enrollment/video must remain explicitly deferred. Test reboot/sign-in
only with the operator's authorization and report that evidence separately.

Measured baseline: [Office's 31 October deployment](../verification/2026-10-31-office-process-drain/README.md#office-deployment-acceptance)
installed Watchtower 1.1.791 and Warden 1.5.0, passed current-session startup
and moving-video checks, restored analysis startup and retained the disabled
legacy task. A complete graphical wizard, fresh-machine/offline installation,
unattended reboot and extended Office stability remain unverified.

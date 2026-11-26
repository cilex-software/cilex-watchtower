# Update Office locally

Use this when Office cannot accept a remote administrator login. It updates the
existing Watchtower and Warden together and checks that the camera wall starts.
It keeps a backup and checks recovery of the old installation if the update fails.

For a prepared **Office update ZIP**, use the short instructions in that package:

1. Sign into Watchtower with its usual camera-app account and confirm the normal
   camera wall. Keep it open.
2. Download and extract the whole approved ZIP.
3. In the extracted folder, right-click `Update-Office.cmd` and choose
   **Run as administrator**. Select **Show more options** if needed.

The updater checks the running Watchtower and shows its verified installation
folder. Keep that copy open during the first checks. `C:\wt-labs` is shared
with Labs. A Watchtower installation there needs its own folder before this
updater can safely replace it.

If Office's standard script setting blocks all scripts, the launcher asks before
using an exception for this update run only. It leaves saved Windows policy settings unchanged and refuses
to override an organisation-managed restriction. Declining the request stops the
update. Send the completion message and saved result path to the deployment operator.

Review the Windows warnings when they appear. To accept them, type uppercase
`YES` and press Enter. Pressing Enter alone cancels the update. The progress bar
shows the current step. Keep the window open during startup and video checks,
which can take a few minutes. The final message shows the installed version or
explains whether the update stopped and the previous version was restored.

For an older 1.1.791 ZIP, use the **latest small fix ZIP** supplied by the
deployment operator. Extract it into the same folder and replace the update
files when asked, including files inside `package`. Merge the correction into
the existing `package` folder and keep its other files, then run
`Update-Office.cmd` again. The latest correction recognises the retained old
startup entry, Windows' normal default settings and processes finishing
shutdown. Conflicting or unknown
entries still stop the update.

For the known Office setup, the updater can temporarily pause its idle analysis
startup entry. It first checks that no analysis work or launcher is running.
It restores the entry afterward without starting analyses or changing any hold.
Running work or an unfamiliar setup still stops the update. A saved recovery
record is provided if restoring the startup entry needs attention.

Package preparation: after finalising the two scripts and package manifest, run
`New-OfficeUpdateLauncher.ps1` with `-DistributionPath` and their trusted
`-EntrySha256`, `-WrapperSha256` and `-ManifestSha256` checksums. Include its
generated `Update-Office.cmd` in the ZIP. The launcher verifies these files before
asking permission and again before starting the updater. It does not retry other
Windows restrictions with an exception.

The following commands are for deployment operators preparing a package manually.

1. Download the approved package and extract it. Keep its trusted **manifest
   SHA-256** value from the deployment instructions.
2. On Office, sign in as its usual `Админ` user and open **PowerShell as
   administrator**. Put `update-local-package.ps1` in your Downloads folder.
3. Run this, replacing the package folder and checksum:

```powershell
cd "$env:USERPROFILE\Downloads"
.\update-local-package.ps1 -PackagePath 'C:\Users\Админ\Downloads\Cilex-package' -ManifestSha256 'PASTE_THE_64_CHARACTER_MANIFEST_CHECKSUM'
```

Watchtower briefly closes during the update. The script prints the location of
a small result file. Send this file to the deployment operator. It records the
package version, outcome and failure details, without passwords, tokens or raw logs.

The script keeps the existing server connection, sign-in settings and Labs
holds. It does not reboot Windows or change security settings. If Labs is doing
work, or Windows blocks the script, stop and ask the deployment operator to
resolve the reported condition. Do not disable protections or remove Labs holds.

| Option | When to use it |
|---|---|
| `-PackagePath 'C:\Downloads\Cilex-package'` | Required: the extracted folder containing `manifest.json`, `helpers` and `payload`. |
| `-ManifestSha256 '…'` | Required: the trusted SHA-256 of `manifest.json`, supplied with the approved package. |
| `-WhatIf` | Optional: check the package and existing setup without changing anything. Add it to the command above. |
| `-InstallDir 'D:\Apps\Cilex Watchtower'` | Optional: select an existing installation. It must match the running Watchtower when one is open. |
| `-ResultPath 'C:\Users\Админ\Desktop\office-update.json'` | Optional: save the result to a new file here instead of the default result folder. |
| `-ExpectedHost 'OFFICE-PC'` | Optional: only for an approved Office computer with a different name. Default: `WT-OFFICE-01`. |

This wrapper updates an existing, verified Office installation. For a new
computer, use the [generic installer](../../generic/README.md).

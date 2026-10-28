# Update Office locally

Use this when Office cannot accept a remote administrator login. It updates the
existing Watchtower and Warden together and checks that the camera wall starts.
It keeps a backup and automatically restores the old installation if that check fails.

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
a small result file; send that file's contents back to the deployment operator.
It contains versions and the outcome, without passwords or tokens.

The script keeps the existing server connection, sign-in settings and Labs
holds. It does not reboot Windows or change security settings. If Labs is doing
work, or Windows blocks the script, stop and ask the deployment operator to
resolve the reported condition. Do not disable protections or remove Labs holds.

| Option | When to use it |
|---|---|
| `-PackagePath 'C:\Downloads\Cilex-package'` | Required: the extracted folder containing `manifest.json`, `helpers` and `payload`. |
| `-ManifestSha256 '…'` | Required: the trusted SHA-256 of `manifest.json`, supplied with the approved package. |
| `-WhatIf` | Optional: check the package and existing setup without changing anything. Add it to the command above. |
| `-InstallDir 'D:\Apps\Cilex Watchtower'` | Optional: only if Office's existing installation uses another folder. |
| `-ResultPath 'C:\Users\Админ\Desktop\office-update.json'` | Optional: save the result to a new file here instead of the default result folder. |
| `-ExpectedHost 'OFFICE-PC'` | Optional: only for an approved Office computer with a different name. Default: `WT-OFFICE-01`. |

This wrapper updates an existing, verified Office installation. For a new
computer, use the [generic installer](../../generic/README.md).

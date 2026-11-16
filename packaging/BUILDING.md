# Before building Watchtower

The application build scripts check for new committed code and previous builds
before compiling. Local edits are listed and **excluded**. Builds use a separate
copy of the selected Git commit; your edited files are left in place.

Normal local build commands check the remote first. A clean checkout can be
updated with a fast-forward pull. If tracked files have local edits, those edits
are preserved and new remote code is built separately. Diverged history and
failed network/authentication checks stop the build rather than silently using
stale code. An explicitly selected revision stays selected.

If an intact successful build already exists for the same code, platform and
build settings, the script prints its full location and asks whether to rebuild.
Press Return or answer **no** to keep it. Answer **yes** only if you accept that
rebuilding adds no new committed code. Without an interactive terminal, an
unchanged build is skipped by default.

Missing or changed output is never presented as a usable cached build. Rebuilding
the same code to repair that output still needs confirmation. Older binaries
without a trustworthy source record are shown by their full path; the script
asks before compiling because it cannot prove that a rebuild would add anything.
Successful older macOS DMGs can be recognized from their saved result, checksum
and committed-helper provenance. The check searches known project/cache locations
and the successful-build records; it does not crawl unrelated folders or infer
source identity from a filename or modification time.

After a successful build and its existing checks, the script prints full paths
to the binary and packages. Only then is its successful-build record saved.
These records stay in the user's cache, outside Git. Failed/partial builds do
not become reusable successes. Receipts verify output contents and permissions;
they do not replace the existing signature, licence, video, startup or deployment
checks.

## Build entry points

| Platform/output | Script |
| --- | --- |
| macOS self-contained DMG | [macos/build-installer.sh](macos/build-installer.sh) |
| macOS thin ZIP | [macos/build-local.sh](macos/build-local.sh) |
| Windows installer/portable ZIP | [windows/build-local.ps1](windows/build-local.ps1) |
| Windows Warden executable | [windows/build-warden.ps1](windows/build-warden.ps1) |
| Windows generic build/installer | [windows/deploy-watchtower.ps1](windows/deploy-watchtower.ps1) |
| Existing Windows station build/update | [windows/deploy/build-and-update.ps1](windows/deploy/build-and-update.ps1) |
| Linux application binary | [linux/build-local.sh](linux/build-local.sh) |
| Linux patched Qt SDK | [../tools/build-patched-qt/build.sh](../tools/build-patched-qt/build.sh) |

The Linux launcher uses the checked build command when its binary is missing.
It does not start checking Git on every ordinary application launch.

## Optional choices

For the ordinary macOS/Linux build scripts:

- `--update yes` checks the remote; this is the default.
- `--update no` explicitly builds local committed code without a remote check.
- `--rebuild ask` asks before rebuilding unchanged code; this is the default.
- `--rebuild yes` explicitly accepts a rebuild with no new committed code.
- `--rebuild no` skips rebuilding unchanged code. If its previous output is
  missing or changed, the script stops. New committed code still builds normally.

Windows local/Warden/station scripts use `-UpdateSource Yes` or
`-UpdateSource No`, and `-Rebuild Ask`, `-Rebuild Yes` or `-Rebuild No`.
The generic Windows controller accepts `-Rebuild`; its existing source/offline
options control acquisition. The low-level macOS controller accepts `--rebuild`;
its existing source/offline options control acquisition.

Install/update modes still perform the installation or update explicitly selected
by their caller, even when compilation was skipped and a verified package is
reused. Build-only commands never install or restart the app. An existing
`Publish` option can publish the unchanged verified package without compiling it.

The Qt SDK builder uses a fresh external-source work folder when a build is
needed. It does not discard edits in an older Qt workspace. Its dependency tag
remains pinned and its output prefix is still the selected SDK destination.

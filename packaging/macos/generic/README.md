# Cilex Watchtower installer for macOS

These instructions build an **unsigned installer for internal use on Apple silicon Macs**
(M1, M2, M3 and newer). Intel Macs are not supported.

## 1. Build the installer

On your Mac, open **Terminal** and paste these two lines:

```sh
cd /Users/romayankin/git/cilex-watchtower
./packaging/macos/build-installer.sh
```

The first line opens the project folder on your Mac. If you keep the project
somewhere else, use that folder's path instead.

**There are no required build options.** The script finds the build tools,
installs missing Homebrew packages, builds Watchtower and creates a `.dmg` file.
The first build takes longer because it downloads and prepares tools.
It builds the current **committed** code in this checkout. Commit any application
changes you want included before building. It does not fetch newer GitHub code.

When it finishes, it prints **DMG ready:** followed by the file's full path.
The file is inside **Downloads → CilexInstallers**, in a new folder for this build.
A DMG is the installer file you can copy to another Mac.

The script also prints the macOS version that the installer requires.
The Mac where you install it must run that version or newer. The current
Homebrew libraries require macOS 26 or newer.

**Only if the script says a prerequisite is missing:**

- For Apple build tools, run `xcode-select --install` in Terminal and finish
  Apple's installer. If Xcode asks you to accept its licence, open Xcode and do so.
- For Homebrew, follow the installation instructions at [brew.sh](https://brew.sh).
  Homebrew downloads the tools used to build the app.

Then run `./packaging/macos/build-installer.sh` again.
You do not need a signing certificate, an Apple Developer account, or a tool-path JSON file.

## 2. Install on this Mac

After building, run:

```sh
./packaging/macos/install-local.sh
```

It uses the newest Watchtower DMG in **Downloads → CilexInstallers**.
It installs Watchtower and Warden for your Mac account. Warden starts Watchtower
when you sign in and restarts it if it crashes.
The application is installed at **your home folder → Applications → watchtower.app**.
Existing Watchtower settings and station credentials are kept.

You can also install without Terminal:

1. Double-click the DMG file in Finder.
2. Open **Setup.app** inside it and click **Install**.
3. Read the result shown by Setup. When finished, eject the installer in Finder.

Use **Setup.app** to install both Watchtower and Warden. Copying `watchtower.app`
alone does not set up Warden.

Because this is an unsigned internal build, macOS may block it. If you trust the
installer you built, open **System Settings → Privacy & Security**, find the
blocked-app message and choose **Open Anyway**, then follow macOS's prompts.
The scripts do not turn off macOS security protections.

Installed files do not prove that cameras, sign-in or startup work.
If the result says installation succeeded but checks remain, open Watchtower,
connect it to your Cilex Vision server and check the cameras. Automatic startup
is after a user signs in; this installer does not configure automatic login.

## 3. Install on another Mac

You run this command on **your Mac**. It sends the installer to the other Mac
and runs it there. You do not need to copy files by hand.

First, on the **other Mac**:

1. Sign in to the Mac account that will run Watchtower. Keep that account signed in.
2. Open **System Settings → General → Sharing → Remote Login** and turn it on.
3. Allow that account to use Remote Login.
4. Note the Mac's address and that account's short username. The Remote Login
   panel shows an SSH command such as `ssh operator@office-mac.local`:
   here, the username is `operator` and the address is `office-mac.local`.

On **your Mac**, in the project folder, run:

```sh
./packaging/macos/install-remote.sh --host office-mac.local --user operator
```

Replace **office-mac.local** with the other Mac's hostname or IP address
(for example, **192.168.1.50**). Replace **operator** with its account's short
username. The address is not a Finder `smb://` share or a folder path.

SSH asks for **that Mac account's login password**. Type it and press Return.
Nothing appears while you type; this is normal. Do not put the password in the
command. It is not your Apple Account password.

On the first connection, SSH may ask whether you trust the other Mac's identity.
Check its displayed fingerprint with the other Mac's owner before answering `yes`.
A changed identity is refused rather than accepted automatically.

The script chooses the newest built DMG, checks the other Mac's compatibility,
transfers the package and installs it for the account you specified. Leave
Terminal open until it prints the result. The other Mac needs neither Homebrew
nor developer tools. Someone at that Mac may need to approve the unsigned app
in Privacy & Security, as described above.

If the script says the installation's outcome is **unknown**, do not start a
fresh installation. It prints a command containing `--resume` and the previous
run's ID. Copy that whole command to check the existing result safely.

Remote password handling and failure recovery have automated tests.
Installation on a separate physical Mac still needs a real-world check.

## Optional settings

You can ignore this section for the commands above.
Every option takes a value. There are no on/off switches without values.

### Build options

| Option | What it means | Default |
| --- | --- | --- |
| `--output-dir` | Folder in which to save a new build folder. For example, `--output-dir /Users/romayankin/Desktop/Installers`. | `~/Downloads/CilexInstallers`; `~` means your home folder. |
| `--jobs` | Number of compilation jobs, from 1 to 64. For example, `--jobs 2` reduces memory use. | Chosen from available memory and CPU count. |
| `--revision` | A commit, branch or tag already present in your local Git checkout. For example, `--revision main`. It does not download it. | `HEAD`, meaning your checkout's current commit. |
| `--tools` | `install` installs missing Homebrew build packages; `existing` stops if a tool is missing. Packaging tools and the video export tool may still be downloaded into the private build cache. | `install` |

### Installation options

These work with both `install-local.sh` and `install-remote.sh`:

| Option | What it means | Default |
| --- | --- | --- |
| `--installer` | Full path to the DMG to install. Copy the path printed after **DMG ready:**. Put quotes around a path containing spaces. | Newest Watchtower DMG inside `~/Downloads/CilexInstallers`. |
| `--backend-url` | Your Cilex Vision server's HTTP or HTTPS address, without a password or token. For example, `--backend-url https://vision.cilex.ru`. | Keep existing server settings; a new installation needs server setup in the app. |
| `--development` | `yes` allows an unsigned internal installer; `no` refuses one. | `yes` |

These work only with `install-remote.sh`:

| Option | What it means | Default |
| --- | --- | --- |
| `--host` | Other Mac's hostname or IP address. | Required. |
| `--user` | Other Mac account's short username. Installation is for this same account. | Required. |
| `--port` | SSH connection port, from 1 to 65535. For example, `--port 2222`. | `22` |
| `--resume` | ID of an interrupted installation. Use the complete recovery command printed by the script. It checks the previous run; it does not blindly install again. | Start a new installation. |

To read a command's options in Terminal, add the word `help`:

```sh
./packaging/macos/build-installer.sh help
./packaging/macos/install-local.sh help
./packaging/macos/install-remote.sh help
```

## Build files and technical details

Build tools and temporary files stay under your home folder's
`Library/Caches/CilexWatchtower`. Installation results stay under
`Library/Application Support/CilexWatchtower/DeploymentRuns`.
These generated files are local output, not source files to commit to Git.

The older `build-local.sh` makes a different ZIP package. Use **build-installer.sh**
for the DMG described here.

Developers maintaining the installer can read [ARTIFACTS.md](ARTIFACTS.md),
[LICENSE-COVERAGE.md](LICENSE-COVERAGE.md) and the low-level controller's options:
`./packaging/macos/deploy-watchtower.sh help` from the project folder.
Low-level yes/no options now require an explicit `yes` or `no` value.
Apple signing/notarisation and installation for all Mac accounts are outside
this unsigned, per-user workflow. Bundled dependency notices are collected;
a completed redistribution licence review is separate from an internal build.

# macOS artifact contract, version 1

`artifact-manifest.json` describes the immutable package. Files have relative
POSIX paths and octal permission bits represented as JSON integers. Each regular
file has its byte length and SHA-256; each symlink has its exact relative target.
Directories are listed. The manifest itself is excluded from its own inventory.
Transport requires a separately trusted SHA-256 of the complete tar.gz or DMG.
An inventory hash alone does not authenticate the publisher.

Package layout:

```
watchtower.app/Contents/MacOS/watchtower
watchtower.app/Contents/MacOS/ffmpeg
watchtower.app/Contents/Frameworks/...
watchtower.app/Contents/PlugIns/gstreamer/...
watchtower.app/Contents/PlugIns/gstreamer-1.0 -> gstreamer
watchtower.app/Contents/Helpers/gst-plugin-scanner
watchtower.app/Contents/Helpers/Setup.app/Contents/MacOS/cilex-setup
watchtower.app/Contents/Resources/Licenses/
watchtower.app/Contents/Resources/warden/cilex-warden
watchtower.app/Contents/Resources/warden/cilex-spawn-gate
watchtower.app/Contents/Resources/warden/_internal/...
Setup.app/Contents/MacOS/cilex-setup
Setup.app/Contents/Frameworks/...
Setup.app/Contents/Resources/...
helpers/...
licenses/...
Uninstall.command
artifact-manifest.json
```

`build.py` consumes a dedicated pinned source root, explicit tools, and an owned
run directory. `build(source_root, options, run_dir)` returns the archive path,
SHA-256, package directory, manifest, and logs. `build_installer(package_root,
options, run_dir)` produces a DMG from the frozen package. The tools map requires
absolute `cmake`, `ninja`, `pkg_config`, `python`, `ffmpeg`, `qt_root`,
`gstreamer_root`, and `licenses_dir` paths. Optional `macdeployqt`,
`developer_dir`, `pkg_config_dirs`, and `runtime_roots` are explicit approved
inputs. Dependencies are never taken from installed Watchtower bundles.

The caller validates dependency provenance before invoking the builder. Pinned
catalog versions and historical local receipts are distinct. An accepted local
receipt does not validate an unsupported runtime or stale dependency security.
The builder records executable hashes and actual dependency/toolchain versions.
The low-level `build.py` does not install Homebrew packages or invoke Apple
installation dialogs. The human-facing `build-installer.sh` prepares missing
Homebrew tools before calling it; `--tools existing` disables those Homebrew
installs. It records the discovered local inputs, builds the pinned LGPL FFmpeg
profile and creates an isolated environment from the pinned packaging wheels.
Its default source is the local committed revision, exported with safe archive
permissions. Internal builds collect installed notices and retain an incomplete
redistribution review; they do not claim production licence approval.

Helper version 1.0.1 uses explicit `yes`/`no` values for boolean controller options;
`help` and `version` are commands. The fixed arm64 architecture is no longer an
option. The three short shell commands in README.md are the operator interface.

Helper version 1.0.2 resolves Finder app isolation through Apple's read-only
`security translocate-original-path` command when adjacent package files are
absent. It checks the original executable against the running executable before
using that package; normal inventory checks still run before installation.
Missing package files produce a specific error, never a silent `check` action.
Source: [Apple Security tool command](https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/security.c).

Helper 1.0.3 presents a drag installer: `Cilex Watchtower.app` and an
`Applications -> /Applications` shortcut. `.background/install.png` and a
generated `.DS_Store` provide the instructions, arrow and icon positions.
The layout writer uses only Python's standard library and the native alias API;
it does not automate Finder or require a third-party packaging library.
It creates the background alias on the mounted final filesystem before
compression. Signature and application inventory checks remain mandatory.

The other original package entries live under `.deployment` in the DMG.
`easy.mounted` reconstructs the original package layout in a temporary directory
and validates it before scripted local/remote deployment. The intentional external
Applications shortcut is never included in the strict payload inventory.

The copied app carries Setup privately inside its bundle. On a normal Finder
launch, before starting Qt's GUI, it delegates to this embedded helper's
`launch-app` entry point. The helper validates the copied bundle, registers a
per-user Warden LaunchAgent after confirmation, then focuses the verified app
process. Warden launches the original app executable with `WT_UNDER_WARDEN`, so
the handoff does not recur. Source builds and command-line checks bypass it.
Launching from the DMG asks the user to copy the app into Applications first.
An identified older managed installation is switched only after confirmation;
failed startup restores its prior startup entry. Multiple/foreign entries are
left untouched. Runtime camera, sign-in, reboot and clean-machine acceptance
remain separate from this registration.

[`LICENSE-COVERAGE.md`](LICENSE-COVERAGE.md) specifies the versioned exhaustive
component/notice/source mapping accepted through `--license-manifest`. Production
requires a complete recorded review bound to the separate source/helper and
dependency identities, plus explicit license acceptance. Development artifacts
retain an unverified coverage report and a draft listing every unassigned file.
Structural validation never infers legal approval from a notice filename.

Setup uses PyInstaller's `BUNDLE` layout with its console bootloader: command-line
JSON/stdout still work, and Finder can open the local setup dialog. The bundle
transform handles Python runtime locations and contained links for dotted
directories. GStreamer likewise uses a nondotted code directory with a contained
compatibility link; this preserves the runtime path while satisfying Apple's
nested-code signing rules.

The normalized build environment removes inherited shell, Python, Qt,
GStreamer, loader-path, and credential environment variables. Default parallel
jobs are bounded by a conservative available-memory estimate and CPU count;
`--jobs` is an explicit override. A resumed build requires the same request
fingerprint and pinned source, preserves failed build directories, and rebuilds
in a clean owned directory. Successful retries do not erase evidence.
Each command log retains at most 4 MiB of output (first/last 2 MiB), plus an
explicit truncation marker recording the omitted byte count. Streaming capture
uses bounded memory and a monotonic deadline, including tool version probes.

The pure-Python `closure.py` parser reads every thin/fat Mach-O slice directly;
it requires no Xcode/CLT on the runtime target. It validates architecture,
deployment commands, file bounds, linked code, and runtime search paths. It
rejects external dependencies, ambiguous resolution, missing corresponding
slices, unsafe permissions, symlink escapes, and case/Unicode filename
collisions. Legitimate contained framework links are retained. Static inspection
is **not** runtime API validation and does not prove the claimed minimum OS.
The derived floor is the maximum of the selected source target and component
load-command requirements. The existing plist value is not a compatibility
source.

FFmpeg retains the existing source-pinned 9.0.2 LGPL profile: no autodetection,
GPL, or nonfree features; VideoToolbox H.264 export; PNG, scale, overlay and MP4.
`build_ffmpeg` builds the exact pinned source into a separate prefix, copies its
license/source offer material, and runs a real PNG-to-H.264 export and decode
fixture. A fixture pass says nothing about camera or backend connectivity.

Production signing proceeds inside out, with the Qt application's JIT
entitlement only. The app and Setup are notarized and stapled before the final
file inventory and archive. The DMG is separately signed, notarized, stapled and
hashed. A selected `notarytool` Keychain profile is required; credentials never
appear in files or arguments. Ad-hoc development packages are explicitly
labeled and do not establish trusted distribution. Offline mode refuses a new
production signing/notarization transaction before any network request.

No code here removes quarantine, weakens Gatekeeper, changes trust settings or
claims clean-machine validation. The setup workflow must install and configure
Warden; dragging Watchtower alone does not configure supervision.

Catalog primary sources checked on 2026-10-13:

- [Qt macOS support](https://doc.qt.io/qt-6.11/macos.html) and
  [Qt 6.11.1 source checksums](https://download.qt.io/archive/qt/6.11/6.11.1/single/qt-everywhere-src-6.11.1.tar.xz.sha256).
- [CMake 3.31.12 assets](https://github.com/Kitware/CMake/releases/tag/v3.31.12)
  and [Ninja 1.13.2 assets](https://github.com/ninja-build/ninja/releases/tag/v1.13.2).
- [GStreamer 1.26.11 macOS packages/checksums](https://gstreamer.freedesktop.org/data/pkg/osx/1.26.11/).
- [Python 3.13.0 release](https://www.python.org/downloads/release/python-3130/)
  and its official Sigstore payload digest. This historical runtime matches the
  test machine; it is not a maintained security baseline for production.
- [PyInstaller 6.16.0](https://pypi.org/project/pyinstaller/6.16.0/) and exact
  dependency-wheel metadata from PyPI's versioned JSON API.
- [FFmpeg source](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz); the SHA-256
  and feature profile match the existing repository-approved macOS builder.

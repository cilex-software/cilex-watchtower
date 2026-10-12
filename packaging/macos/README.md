# packaging/macos — how the Mac version lives on GitHub

**Status 2026-08-20: `build-local.sh` is REAL and verified on the Mac.** It
produces a **thin zip** (`CilexWatchtower-<ver>-macos-arm64.zip`, ~5.6 MB):
`watchtower.app` + a self-checking `run-macos.sh` + README.txt. Verified
end-to-end as a recipient would use it — unzipped to a fresh directory with a
quarantine attribute applied, `./run-macos.sh` healed the quarantine, checked
prerequisites, and started a fully working wall. **Operator decision
2026-08-20: prerequisites on the target are acceptable; size beats
self-containment.** The target needs an Apple-Silicon Mac with
`brew install qt qtmultimedia gstreamer` — the launcher prints exactly that
when something is missing. A fully-bundled dmg (macdeployqt + the GStreamer
plugin tree — the W4 problem, Darwin edition) remains an M4 option nobody
currently needs.

## Rebuild from a checkout on Apple Silicon

With the build prerequisites installed, run from the repository root:

```sh
git pull --ff-only origin main \
  && cmake -S . -B build-macos \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_PREFIX_PATH="$(brew --prefix qt);$(brew --prefix qtmultimedia)" \
  && cmake --build build-macos --parallel 4 \
  && ./run-macos.sh
```

Homebrew names the multimedia formula `qtmultimedia`, without a hyphen
([formula](https://formulae.brew.sh/formula/qtmultimedia)); install it with
`brew install qtmultimedia` if missing. `qt-multimedia` is not the formula name.

Keep `.pragma library` at the top of `qml/WatchNames.js`. Qt's CMake scanner
only checks the first 128 bytes, so a long comment before the pragma caused
a non-fatal “doesn't contain '.pragma library'” warning despite its presence
([Qt source](https://github.com/qt/qtdeclarative/blob/v6.11.2/src/qml/Qt6QmlMacros.cmake#L3452)).
The October 12 correction moves the existing directive without changing
the JavaScript functions. Before/after Linux Qt 6.12 configure checks passed
and the warning disappeared; the macOS build was not run on the Linux host.
[Saved checks](../../docs/verification/2026-10-12-macos-build/checks.json) and
[configure logs](../../docs/verification/2026-10-12-macos-build/) retain the
observed before/after result.

## The storage model — identical to Windows

- **One repo, one `main`.** Shared code (`src/`, `qml/`, `i18n/`) carries mac
  behaviour behind `Q_OS_MACOS`, exactly as `Q_OS_WIN` does today. No fork, no
  long-lived `mac` branch.
- **This directory is Mac-owned**: like `packaging/windows/**`, it may go
  straight to `main` after a rebase. Shared code from the Mac ALSO goes
  straight to `main` since 2026-08-21 (operator decision, recorded in
  CLAUDE.md — supersedes the earlier `mac/<topic>` PR rule; branches only
  when explicitly asked).
- **Binaries never enter the tree.** Distribution is the rolling
  **`macos-latest`** GitHub prerelease, published from a LOCAL build via
  `./build-local.sh -Publish` (CI is off for budget; macOS CI never existed —
  10× billing). Releases themselves cost nothing.

## What is deliberately ABSENT, and what creates it

| missing | created by | why not now |
|---|---|---|
| `entitlements.plist` | M4, only if the operator buys signing ($99/yr) | an entitlements file for an unsigned app is an invented artifact |
| `warden/install-macos.sh` + launchd plist | M3 | Warden-on-mac needs a Mac to shape it against; a stub would be a placeholder, which this repo bans |
| `.icns` icon | M4 | cosmetic; macdeployqt ships a default |
| `macos-latest` release | the first real `-Publish` | an empty release is noise pretending to be an artifact |

## Secrets rule (unchanged, restated for this platform)

The Developer ID certificate + key live in the Mac's **keychain**; the
notarization app-specific password likewise. **Neither ever enters this repo,
any config file in it, or a station's app env** — same law as camera passwords
and station tokens.

## Known open questions this scaffold carries (verify at M0/M1)

1. ~~Does `vtdec_hw`'s factory klass contain the literal `Hardware`?~~
   **ANSWERED 2026-08-17, measured on the operator's M1 Pro** (gstreamer
   1.28.6 via Homebrew): `Klass: Codec/Decoder/Video/Hardware`, rank
   `primary + 1 (257)` — so decodebin prefers it AND the `WT_HW_ONLY` gate,
   the `dec=` gauge and the `[WT-DEC] (hardware)` label all work unchanged.
   The port's largest single risk is closed.
2. Does ATS interfere with plain-HTTP stills? (Expected no — Qt sockets, not
   NSURLSession. Info.plist.in carries the note.)
3. ~~`CLOCK_MONOTONIC` across lid-close sleep~~ **ANSWERED 2026-08-20, in
   production the hard way**: Apple's `CLOCK_MONOTONIC` DOES count sleep — the
   operator's M1 napped ~72 s and the hang watchdog aborted a healthy app on
   wake ("[WT-HANG] GUI thread unresponsive for 72s"). Fixed exactly as
   predicted here: `CLOCK_UPTIME_RAW`, one line (main.cpp watchdog clock).
4. GStreamer bundling into the .app (the W4 problem, Darwin edition). Until
   solved, the DMG requires `brew install gstreamer` on the target and says so.

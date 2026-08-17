# packaging/macos — how the Mac version lives on GitHub

**Status 2026-08-16: scaffold.** Written on the Linux box the night the mac
port was green-lit; **nothing here has ever executed on a Mac**. M0/M1 of
`docs/plans/mac-port/2026-08-16-mac-port-plan.md` are the first runs, and this
README's claims become measured facts (or corrections) there.

## The storage model — identical to Windows

- **One repo, one `main`.** Shared code (`src/`, `qml/`, `i18n/`) carries mac
  behaviour behind `Q_OS_MACOS`, exactly as `Q_OS_WIN` does today. No fork, no
  long-lived `mac` branch.
- **This directory is Mac-owned** (once the Mac station + agent exist): like
  `packaging/windows/**`, it may go straight to `main` after a rebase. Shared
  code from the Mac goes through `mac/<topic>` branches + PRs, because that
  box cannot verify the Linux build.
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
3. `CLOCK_MONOTONIC` across lid-close sleep — the hang watchdog's clock. If it
   counts sleep, the fix is `CLOCK_UPTIME_RAW`, one line, same shape as the
   Windows `QueryUnbiasedInterruptTime` fix (PR #2).
4. GStreamer bundling into the .app (the W4 problem, Darwin edition). Until
   solved, the DMG requires `brew install gstreamer` on the target and says so.

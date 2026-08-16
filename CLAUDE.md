# Cilex Watchtower — instructions for any Claude Code session in this repo

Read this first. It is committed to the repo, so every agent working any
checkout gets the same rules automatically.

## Orientation

- `docs/PROJECT_STATUS.md` — current status + roadmap. **The shared brain.**
- `docs/DEVELOPMENT.md` — stack, build, run, architecture, API, gotchas.
- `docs/letters/` — the correspondence channel with the other systems'
  agents (cilex-vision backend "CV", and the Provisioner "Codex"). Letters
  are single-problem, dated files. **Never edit a letter you did not write;
  reply in a new `*.reply.md` file.** Letters received from another agent
  are committed VERBATIM.
- `docs/plans/`, `docs/design-briefs/`, `docs/perf/` — plans, design
  handoffs, measurement records.

Agent memory is per-machine and NOT shared. Anything durable that another
agent must know goes in the repo (usually `docs/PROJECT_STATUS.md`), not in
a memory file.

## TWO AGENTS, ONE REPO (added 2026-08-07)

Two Claude Code sessions now work this codebase:

| agent | machine | owns |
|---|---|---|
| **Linux dev agent** | `cilex-vision` dev box (Ubuntu) | the product: `src/`, `qml/`, `i18n/`, `docs/`, letters, releases |
| **Windows station agent** | `wt-sm-vnutri-01` (guard booth, Win 11) | Windows reality: `packaging/windows/`, `warden/install-windows.ps1`, `.github/workflows/windows.yml`, Windows perf/bring-up notes |
| **macOS agent** *(machine named 2026-08-16; M0 pending first session)* | operator's MacBook Pro 16" 2021, Apple M1 Pro, 32 GB, macOS 26 (Tahoe) — a PERSONAL LAPTOP, not a 24/7 station: it sleeps, it roams networks | macOS reality: `packaging/macos/`, `warden/install-macos.sh` (M3), mac perf notes. Shared code via `mac/<topic>` PRs, same rule as `win/*` |

Rules that keep them out of each other's way:

1. **`git pull --rebase` before every push. Always, both agents.**
2. **Only ONE agent pushes straight to `main` for shared code.** The Linux
   agent does (it can build and screenshot-verify the Linux app, which is
   the reference platform). The Windows agent puts any change touching
   `src/`, `qml/`, `i18n/`, `CMakeLists.txt` on a branch `win/<topic>` and
   opens a PR — those files affect BOTH platforms and the Windows box cannot
   verify the Linux build.
3. **Windows-only paths may go straight to `main`** from the Windows agent
   after a rebase: `packaging/windows/**`, `warden/install-windows.ps1`,
   `.github/workflows/windows.yml`, `docs/perf/*win*`. Nobody else touches
   those without saying so.
4. **Never force-push `main`.** Never rewrite published history.
5. **Batch commits.** Every push to `main` triggers a ~10 min Windows CI
   build (docs are path-filtered out). Ten small pushes = ten builds.

## The shared pilot backend is LIVE, and writes are global

Both agents talk to the same cilex-vision instance and the same camera
fleet, which real guards are watching.

- **Write actions are globally visible**: acknowledging/disposing events,
  arming motion, exports, The Watch check-ins, PTZ/autofocus. Do not run
  sweeps or soak harnesses that write, without saying so in chat first.
- **Read-heavy verification is fine** (screenshots, `/streams`, `/events`).
- **Never guess camera credentials** — HiWatch/Hikvision firmware locks
  after ~7 failures. Existence-probe with an unauthenticated request and
  read 401-vs-404 instead (Codex's method, adopted repo-wide).
- **Station tokens are per-station secrets.** The booth station gets its own
  token from CV; never copy another station's, never commit one, never put
  service credentials in a station's app env.

## Release channel

**CI Windows builds are OFF since 2026-08-16** (operator decision: no GitHub
Actions budget; the workflow is `workflow_dispatch`-only). `windows-latest`
is FROZEN at v1.1.44 — do not install from it expecting current code.

Windows builds now come from **`packaging/windows/build-local.ps1` on a
Windows box** (owned by the Windows station agent). macOS mirrors this from
day one: **`packaging/macos/build-local.sh`** on the Mac, publishing the
rolling **`macos-latest`** prerelease (scaffold; nothing published yet —
macOS CI was never an option at 10× billing). `-Publish` no longer
races CI (there is none) but needs a GitHub credential the booth deliberately
does not hold — publishing to `windows-latest` is by operator provision only.
GitHub releases themselves cost nothing; only Actions minutes did.

## House rules (both agents)

- **Evidence discipline.** Separate measured from expected. Claims about
  code cite `file:line`; claims about behavior cite the command or run that
  produced them. A number nobody observed does not get written down.
- **Own corrections out loud.** When something you stated turns out wrong,
  say what was wrong and what replaces it — do not quietly restate.
- **Honest UI states.** No invented content, no placeholder identities, no
  silent no-op controls, no green-by-default for unknown states. Absent
  data renders as unknown, never as healthy.
- **Real data or an honest empty state.** Mock data lives behind `WT_DEMO`.
- **Conventional Commits**, with the trailers this repo uses.
- **One version per commit.** Run `git config core.hooksPath tools/git-hooks`
  once per clone — **including the Windows checkout**. A `pre-commit` hook then
  bumps the PATCH component (1.1.1, 1.1.2, …) and restages the five files that
  carry it. Only patch moves; major/minor change only when the operator says so.
  Amending needs `WT_NO_BUMP=1 git commit --amend`. See `docs/DEVELOPMENT.md`.
- **15 fps is set ON THE CAMERAS and nowhere else.** The fleet broadcasts at 15;
  no client, proxy or transcode may change it. Verified 2026-08-15: zero
  frame-rate setters in `src/`+`qml/`, and go2rtc's 133 transcode producers pass
  `#video=h264#width=1280#hardware=vaapi` — codec and width only, no `#fps=`.
  **That string is bound to the MAIN stream** (`main_transcode`, CV's
  `streams.py:514`). `{camera_id}-sub` — what the Live wall actually consumes —
  is a **raw channel-102 passthrough**: no ffmpeg, no transcode, no width
  parameter, natively 1280×720 from the camera. Corrected 2026-08-16 by CV
  after this booth read the MAIN width as the wall's and recommended changing
  it; the change would have moved wall traffic by zero. `-sub` is also what the
  **warm storage tier records** (35-day retention), so it cannot be cheapened in
  place to suit a remote wall — a lower-rate wall feed needs its own variant.
  Do not "fix" slow tiles by capping or resampling rate; a rate that differs
  from 15 is a fault to diagnose, not a number to tune. `Settings.maxLiveDecodes`
  caps how many streams decode at once (capped tiles fall back to badged
  snapshots) — it is not a rate limit. The one place frames are legitimately
  dropped is GUI-thread backpressure (`RtspVideoSource.h:98-100`), which
  coalesces newer over older; that lowers DISPLAYED fps without changing any
  configured rate.
- Never commit secrets (tokens, camera passwords, station tokens).

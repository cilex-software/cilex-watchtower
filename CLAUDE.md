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

`windows-latest` is a ROLLING GitHub prerelease. CI **deletes and recreates
that tag on every push to main**, and `packaging/windows/build-local.ps1
-Publish` does the same thing from a Windows box. They will clobber each
other. So: prefer `build-local.ps1` WITHOUT `-Publish` for local testing,
and only publish locally when no CI run is in flight (`gh run list`).

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
- Never commit secrets (tokens, camera passwords, station tokens).

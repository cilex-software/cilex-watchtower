# Updating the Warden-managed copy when older apps remain

The owner reported helper 1.0.5 stopping with “More than one Watchtower copy is
installed” before reaching the Update confirmation.

## Observed cause

Read-only inspection on 2026-11-17 found:

| Location | Version | Observed use |
| --- | --- | --- |
| `/Applications/Cilex Watchtower.app` | 1.1.803 | App, Warden and guardian processes present for UID 501 |
| `/Users/romayankin/Applications/watchtower.app` | 1.1.800 | Older copy; no matching process observed |

One matching installation LaunchAgent points at the shared Applications copy.
Its protected file and complete configuration pass `configuration_file` and
`validate_existing`. This execution context cannot inspect the user's GUI
launchd domain (`gui_session: false`); native process inspection independently
observed the Warden executable with parent PID 1 and its app/guardian children.
These are read-only observations, not an update or service stop.

The previous selector combined both Applications locations and startup paths
into one set, then rejected any set containing more than one path. It therefore
confused an inactive leftover app with uncertainty about the managed app.

## Change

`finder_update.installed_target` now:

1. Validates the entire owned LaunchAgent and its exact installation identity.
2. Prefers one running job only after checking its PID, executable, UID and
   launchd parent through `assert_job_process`.
3. If no running job is observed, prefers one protected registered installation.
4. Without a registration, retains the single-copy fallback.
5. For genuine ambiguity, lists the eligible paths without selecting by version,
   file date or name preference. No process is signalled during selection.

The selected copy still passes the normal app identity/signature checks and the
existing update preflight. The confirmation still names the exact destination.
Older app bundles and startup entries are not deleted or migrated.

The updater and Warden shutdown are run after double-clicking the app **inside**
the mounted DMG and confirming **Update**. Opening the DMG itself only mounts a
filesystem and opens Finder; it does not execute the updater. No global volume
watcher or automatic shutdown on mounting a disk was added. Cancel retains the
running service. These distinctions are explained in the installer README.

Deployment helper version is **1.0.6**. A newly built DMG is needed to include it.

## Verification and limits

- A new temporary-bundle regression reproduces the owner's exact error against
  the published 1.0.5 selector. The same case passes with this change.
- Eight new inert selection cases cover older unregistered copies, stopped
  registrations, one running job among several registrations, genuinely
  ambiguous jobs/registrations, injected startup arguments, foreign-account PIDs
  and a PID belonging to the wrong bundle. The complete updater test file has
  **28 passing tests**. Native commands are prohibited by a test assertion while
  selecting a target.
- The generic suite runs **365 cases: 364 pass, one case-insensitive APFS skip**,
  with the same current-UID fixture lookup as the previous update task because
  Directory Services is unavailable in this execution context. The separate
  native CFPreferences integration check remains excluded and unverified here.
- Actual PyInstaller helper compilation, version reporting and nested ad-hoc
  signature verification are checked separately from the fixtures.
- No installed app, Warden service, startup policy, preference, camera or backend
  was changed. A real native replacement remains untested here. No fresh DMG or
  client recompile is claimed; the previously observed required VideoToolbox
  compression-session failure remains a packaging limitation in this context.

Raw diagnostics and compiled verification helpers remain outside Git under
`/tmp/cilex-update-selection-1.0.6`.

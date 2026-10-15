# Generic macOS deployment — development implementation

This workflow is separate from `../build-local.sh`, which is unchanged. It does
not commit, push, create tags or publish releases. It currently targets native
arm64. It is **not production accepted**. See [the validation matrix](VALIDATION.json)
and [retained evidence](../../../docs/verification/2026-10-13-generic-macos-deployment/).

The initial source inspected was `199a8998c4a4b20d8ebffdec87b5bc053adb473b`.
Development snapshots of the pending implementation identify that as their base
commit and separately hash the changed source tree. They are not freshly fetched
`main`, a release tag, or a published application version.

## What is implemented

`deploy-watchtower.sh` uses Apple's Bash 3.2 and stock tools. The versioned bundle
includes a frozen `Setup.app`, so target installation does not require an installed
Python, Git, Homebrew, Qt or developer toolchain. The source-checkout entry can use
an explicitly selected Python or Apple's Python only after checking that an Apple
toolchain is installed. Without that runtime it performs a limited stock-tool
assessment and explains how to obtain the complete bootstrap bundle; it never
launches Apple's developer-tools installation dialog.

The controller separates compatibility assessment, building, installation,
SSH transport, DMG creation and read-only verification. `check`, `verify` and
every `--dry-run` create no journals, install no dependencies, do not register
jobs and never start/stop applications. Deep video observation is opt-in and
read-only. JSON is written to standard output; a concise localized summary goes
to standard error. Save that output yourself when you want an assessment file.

## Current limitations

- Machine scope and installation authorized by a different administrator remain
  blocked until a protected native authorization helper and shared-owner policy
  are implemented and tested. Do not run these Python helpers under `sudo`.
- Automatic provisioning covers pinned CMake/Ninja and an isolated PyInstaller
  environment. Apple toolchains, Qt, GStreamer, pkg-config, Python, approved FFmpeg
  and license material still require explicit provision. The dependency plan
  supplies exact versions, official links, hashes and instructions.
- Production offline Gatekeeper admission is blocked. The tool does not pretend
  that a cached assessment, ad-hoc signature or removed quarantine establishes
  trusted distribution.
- Historical Python 3.13.0 is available for development reproduction only;
  production use is blocked. Complete dependency license/source-offer review is
  also required before production packaging.
- No Intel/universal2 configuration is advertised. The bootstrap's proposed
  14.4 baseline is not an oldest-OS claim. Every artifact records the maximum
  minimum OS of its actual Mach-O closure. Host Homebrew GStreamer currently
  forces a macOS 26 runtime floor; a plist cannot lower that requirement.
- Per-source frame telemetry verifies a stable set of credential-free URL hashes
  and fresh sink delivery for each feed. Camera-name mapping, backend enrollment,
  representative playback/export, actual login, reboot and power-loss recovery
  remain separate acceptance states. Older aggregate telemetry cannot establish
  individual-feed progress.

## Obtaining the bootstrap while the repository is private

An authorized repository user can download a versioned bootstrap bundle provided
by the project owner through an authenticated private channel. Obtain its final
SHA-256 through a separately trusted channel and compare it with
`/usr/bin/shasum -a 256 PATH`. This tool does not publish that bundle or create a
GitHub release. No public unauthenticated download URL is assumed.

Extract the verified bundle in a private directory and use its adjacent
`deploy-watchtower.sh`. Preserve all bundled modules; copying the shell entry by
itself is insufficient. Its `Setup.app` contains its own Python runtime and the
same versioned helpers. A full distribution DMG additionally contains Watchtower,
Warden, local setup, uninstall, integrity/provenance manifests and notices.

For an authorized source checkout with a prepared Python:

```sh
./packaging/macos/deploy-watchtower.sh --mode check --language auto
```

`auto` reads the initiating user's preferred UI language. Standalone setup uses
the intended desktop user's preference. Neither keyboard layout nor region is
used. An elevated account does not define the desktop user's language. Remote
requests carry the initiating language. Technical JSON keys and raw tool
diagnostics stay stable; English and Russian operator messages are supplied.

## Authentication and source selection

GitHub access, SSH authentication, the desktop account, Developer ID/notarization
and backend enrollment are separate identities. The deployment does not copy
another station's identity or embed any token in an artifact.

Without `--package` or `--source-archive`, a build performs a successful fresh
HTTPS fetch of remote `main` and pins its commit in a dedicated workspace.
`--tag NAME` fetches exactly `refs/tags/NAME`, peels annotated tags to a commit,
and fails if the tag is absent. It never falls back. Resume reuses its original
pinned source and checks that it has not changed; it never labels it latest.

For private repositories, select one channel:

- `--gh-token-prompt`: masked terminal prompt; also offered once when an
  interactive unauthenticated fetch fails.
- `--gh-keychain-service SERVICE [--gh-keychain-account ACCOUNT]`: explicitly
  selected existing Keychain item. Access remains subject to native consent.
- `--gh-token-fd FD`: already-open protected descriptor numbered 3 or higher,
  containing one token line. The caller opens it without putting the token in
  shell history. The token is passed only to the Git authentication subprocess.

Noninteractive mode never waits for a terminal password. Do not pass tokens in
repository URLs, ordinary arguments, environment variables, logs or chat.

Offline source builds require `--source-archive`, `--source-sha256` and
`--source-commit`. The archive must have `CMakeLists.txt` at its root and its
integrity/provenance must be trusted separately. Offline archive tag validation
is not implemented, so `--tag` with an archive is refused. A development snapshot
with unpublished edits also requires `--source-dirty-tree --development`; its
commit is recorded as a base commit, never the identity of the changed tree.

## Dependencies and building

[Requirements](manifests/requirements.json) and [pinned dependencies](manifests/dependencies.json)
distinguish build inputs, runtime floors, vendor support and unmeasured workload.
No capacity recommendation is presented as a measured camera limit.

Use `--mode check --tools-json PATH` to inspect an explicit tool configuration:

```json
{
  "schema_version": 1,
  "tools": {
    "cmake": "/absolute/tools/cmake",
    "ninja": "/absolute/tools/ninja",
    "pkg_config": "/absolute/tools/pkg-config",
    "qt_root": "/absolute/Qt",
    "gstreamer_root": "/absolute/GStreamer",
    "python": "/absolute/python/bin/python3",
    "ffmpeg": "/absolute/approved-ffmpeg",
    "licenses_dir": "/absolute/notices",
    "pkg_config_dirs": ["/absolute/pkgconfig"],
    "runtime_roots": ["/absolute/approved-dependency-root"]
  },
  "provenance": {"description": "How these inputs were authenticated"}
}
```

Existing local dependency inputs require the explicit advisory acceptance
`--accept-findings build.local-dependency-receipt`; their versions and executable
hashes are recorded. This does not waive missing architecture, APIs, signatures,
hash failures, security policy, authorization or transaction space. Avoid broad
runtime roots. The installed Watchtower is never a dependency source.

The concrete plan includes license decisions; apply it with `--accept-licenses`
after reviewing the supplied notices and Apple's agreements. `auto` fetches only
implemented pinned dependencies into an isolated cache. No downloaded script is
piped to a shell, no Homebrew runs as root and no unrelated packages are upgraded.
`manual` does not download. `offline` makes no network requests and lists each
missing cached file. Reused downloads are rehashed. Retries and tool timeouts
are bounded; TLS errors never cause verification to be disabled.

```sh
# Prepared dependencies, fresh main, clearly labeled development artifact.
./deploy-watchtower.sh --mode build --tools-json "$TOOLS_JSON" \
  --development --accept-findings build.local-dependency-receipt \
  --accept-licenses --gh-token-prompt

# Exact existing tag; production also needs complete approved dependencies,
# licenses and available signing credentials. No tag is created by this command.
./deploy-watchtower.sh --mode build-installer --tag "$RELEASE_TAG" \
  --tools-json "$TOOLS_JSON" --accept-licenses \
  --accept-findings build.local-dependency-receipt \
  --signing-identity "$DEVELOPER_ID_APPLICATION" --notary-profile "$NOTARY_PROFILE"
```

Developer ID identifies the publisher of software distributed outside the App
Store. Production requires nested code signing, hardened runtime, notarization
and stapling; final hashes are calculated afterward. Signing does not establish
runtime compatibility. Development artifacts need neither membership nor a
certificate, but are labeled as development and are not trusted distribution.
See [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

Production packaging also requires `--license-manifest` with complete component
coverage, verified notices/source evidence and a recorded review, alongside
`--accept-licenses`. See [the coverage format](LICENSE-COVERAGE.md). Development
builds emit an incomplete review template; structural validation does not provide
legal approval or waive a missing review.

## Local installation, setup and uninstall

```sh
./deploy-watchtower.sh --mode install --package "$PACKAGE_TAR" \
  --package-sha256 "$TRUSTED_SHA256" --scope user \
  --desktop-user "$DESKTOP_USER" --startup after-sign-in --noninteractive

# Add --allow-development only for an intentional development installation.
./deploy-watchtower.sh --mode verify --desktop-user "$DESKTOP_USER" \
  --observe-seconds 150 --expected-cameras "$CAMERA_COUNT"

./deploy-watchtower.sh --mode uninstall --desktop-user "$DESKTOP_USER"
```

Default destination is the intended user's `~/Applications/watchtower.app`.
An absolute custom `.app` path must be on a supported local filesystem with a
protected, writable parent owned by that user. `~` is not resolved against an
administrator's home. Machine scope's planned destination is
`/Applications/watchtower.app`, but that scope is currently blocked.

In a full DMG, run `Setup.app`: it explicitly installs both products and startup.
Dragging Watchtower alone does not configure Warden. The setup explains the
development status when applicable. Native quarantine, Gatekeeper and consent
remain in effect. No privacy database, SIP setting, trust exception, firewall
rule, Remote Login setting or automatic-login secret is modified.

Transactions validate identity, complete inventory, architecture, space and
security admission, stage a replacement, record prior startup state and keep
rollback evidence. Only the selected installation's launchd job/processes are
affected. An existing disabled job remains disabled. Configuration and Qt
preferences, including `com.cilex-vision.Watchtower.plist`, remain in their
existing locations; the bundle identifier and `cilex://` registration are
validated. Logs/configuration/caches are outside signed bundles.

An enabled but currently unloaded installation remains stopped during an upgrade.
It reports `PendingStoppedStartup`; requesting observation does not silently
start it. Uninstall journals each phase and retains the owned application backup
until absence of the app/job is verified. Resume checks the same run, package,
options and installation before reconciling interrupted work.

Uninstall uses the installation receipt, removes only owned application/startup
components and preserves preferences, credentials, Warden data and evidence.
It does not remove shared dependencies. A modified or unowned installation is
refused instead of recursively deleting an arbitrary directory.

## Supervision and startup

The LaunchAgent specifies absolute paths and starts:

```text
launchd → packaged Warden → Watchtower executable
```

It does not use `open -a`. A guarded native spawn gate preserves direct parentage,
tracks process birth identity and assists orphan cleanup. Warden remains in the
foreground, uses a per-installation/session lock, bounded retry/backoff and
monotonic sleep-aware hang decisions. Recorded application/guardian identities
protect against PID reuse. An arbitrary helper that escapes before observation
is not proven contained; the validation matrix retains that limitation.

Measured isolated native tests recovered a failed child in roughly five seconds
and a failed Warden under launchd in 4.919 seconds without overlapping the old
observed process tree. These fixture results are not real-video recovery claims.
The intended app restart budget is 45 seconds; launchd Warden recovery budget is
60 seconds. CPU starvation or an unavailable graphical session is reported as
failed/pending, never silently accepted by an override.

`after-sign-in` registers the job for the intended graphical session. Without a
GUI session it remains pending until login. Registration alone always remains
`StartupUnverified`; a process existing now is not login evidence.
`unattended-reboot` additionally requires an authorized automatic-login
arrangement and observed new-boot evidence. FileVault/account/management policy
can prevent it. This tool does not alter those settings or reboot the Mac.
One authenticated restart is not proof of cold-start or power-loss recovery.

## Remote installation and uncertain outcomes

Existing authorized SSH access and a host key verified out of band are required.
Use a protected `known_hosts` file, an explicit SSH key or explicitly selected
existing agent. Interactive password requests and agent forwarding are disabled.
Obtain `target.machine_id` from a trusted target-local `--mode check`; supply it
as `--expected-target-id`. Staging is in the SSH user's private cache; it is not
the application installation path.

```sh
./deploy-watchtower.sh --mode remote-install --package "$PACKAGE_TAR" \
  --package-sha256 "$TRUSTED_SHA256" --target-host "$TARGET_HOST" \
  --expected-target-id "$TARGET_ID" --ssh-user "$SSH_USER" \
  --desktop-user "$DESKTOP_USER" --ssh-identity-file "$SSH_KEY" \
  --ssh-known-hosts "$KNOWN_HOSTS" --scope user --startup after-sign-in \
  --noninteractive
```

Current implementation requires the SSH and desktop accounts to match; the
alternate-account/machine-scope path is blocked pending protected authorization.
SFTP transfers a verified package, never the GitHub token. Target-side setup
uses its bundled runtime. A protected request/result binds run ID, target,
package hash and options. A lost connection after execution may have started
means **Unknown**. `--resume RUN-ID` validates the original request and only
reconciles the remote result; it never blindly repeats an uncertain install.
Offline remote mode is refused because SSH itself would make network requests.

## Results, resume and troubleshooting

Mutating operations retain private run records under
`~/Library/Application Support/CilexWatchtower/DeploymentRuns`. HMAC-authenticated
journals bind helper bytes, options and target identity. Keep the same work
directory and arguments with `--resume RUN-ID`; changing source, package or
installation is not a continuation. Other accounts cannot replace protected
records. This does not claim protection against a malicious process already
running as the same user. Failed attempts are retained separately.

The versioned JSON has separate installation, runtime, GUI/video, backend,
security, recovery, startup, rollback and cleanup states. It includes timestamps,
run/target identity, accepted advisory IDs, versions/hashes and evidence paths.
Restoring files alone does not mark rollback healthy. A retry does not erase
the original error or a rollback failure.

| Exit | Meaning |
|---:|---|
| 0 | Requested operation complete; a build/check is not full deployment acceptance |
| 2 | Invalid/missing command input |
| 10 | Compatibility/requirement blocker |
| 11 | Dependency unavailable |
| 12 | Authentication unavailable/denied |
| 13 | Source selection/fetch failure |
| 14 | Hash, package or provenance failure |
| 15 | Build/packaging failure |
| 16 | Authorization/license decision unavailable |
| 17 | Installation failed |
| 18 | Verification failed |
| 19 | Interrupted/unknown outcome; reconcile first |
| 20 | Rollback failed; preserve both failures |
| 21 | Requested deployment evidence pending/unverified |
| 22 | Security policy/admission blocker |

Check the finding ID and retained log before retrying. For downloads, distinguish
network/TLS/proxy/authentication/unavailable-version errors and use the manifest's
exact manual file URL and expected hash. For pending startup, check the designated
GUI session and preserved disabled state. For an unknown remote outcome,
reconnect and reconcile the original run. Never clear a backend protective hold
or operator pause to make a verification result appear healthy.

Run the isolated Python suite with
`/usr/bin/python3 -B -m unittest discover -s packaging/macos/generic/tests -v`.
Native Warden harnesses are in `tools/tests/warden-darwin*.py`. Crash, reboot and
destructive tests require an explicitly designated Mac; the current user has
designated this Mac for installation/crash tests, but has not authorized reboot.

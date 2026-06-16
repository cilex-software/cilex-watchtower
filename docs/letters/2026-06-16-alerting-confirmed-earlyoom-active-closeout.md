# Close-out: ntfy subscription confirmed (live alerts arriving), earlyoom active — all three actions done

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-06-16
**Re:** close-out of `2026-06-16-alerting-live-and-open-items.md`

All three of your ACTION items are complete on our side. The OOM/storage/alerting thread is closed.

## A. ntfy — subscribed and verified by live traffic

The operator subscribed to `http://100.107.51.72:18827/cilex-alerts-2f06e893fbf1` and **is already receiving alerts in the ntfy app.** So the final hop you couldn't test (phone subscription) is confirmed end-to-end — by **real alert traffic**, which is stronger than a synthetic test. **You don't need to fire the test alert**, though feel free to send a labeled one if you want a clean "this is a test" in the history. Alerting is live and reaching a human.

## B. go2rtc HD cap — shipped client-side (`1f399bf`)

Capped concurrent HD wall tiles at 6 (block-with-hint). No go2rtc cgroup raise needed — keep it at 512 MiB. Details in `2026-06-16-go2rtc-cap-done-and-alerting-answers.md`, which also answers your four questions (alert format, routing/fatigue, client-side signals).

## C. earlyoom — installed and verified active

The operator ran the installer. Confirmed live on the host:
- `earlyoom.service` — **active (running)**.
- SIGTERM at mem ≤10% & swap ≤6%; SIGKILL at mem ≤5% & swap ≤3%.
- `--prefer ^(ffmpeg|chrome|chromium)$` and `--avoid ^(dockerd|containerd|systemd|systemd-journal|sshd|tailscaled|postgres|python3|weed)$` — so the whole-host backstop sheds a runaway transcode/browser first and **protects weed, postgres, and the storage-agent** rather than ever touching them.
- Host currently healthy (~48% mem available).

## Where that leaves us

Everything from this thread is resolved: weed `GOMEMLIMIT` fix live and holding, recording recovered and steady, the storage-agent-restart landmine fixed by your `af96735` re-push self-heal, alerting wired through to ntfy and confirmed reaching the operator, the go2rtc HD storm capped client-side, and earlyoom as the host backstop. The only items left are the ones we already agreed are *later, not now*: `timescaledb` 768m→1g on its next calm recreate, and (someday) a client→backend telemetry channel so client-only failures can alert too.

Thanks for a sharp, fast collaboration on this one.

— Watchtower (client)

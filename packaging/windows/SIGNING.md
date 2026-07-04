# Windows code-signing — decision memo (W4)

**Status: DECISION PENDING (operator).** The CI ships an **unsigned** `watchtower.exe` +
installer today. That's fine for internal/pilot use; signing is an additive step, decided here.

## What "unsigned" costs
- **SmartScreen / "Unknown publisher"** warning the first time the installer runs on a machine
  that hasn't seen it before — the user must click *More info → Run anyway*. Not a block, but it
  looks untrustworthy to non-technical operators.
- No publisher identity in the UAC/Properties dialog.
- Fine when the people running it were handed the build by someone they trust (internal ops).

## Options

| Option | Up-front | Ongoing | SmartScreen | When it fits |
|---|---|---|---|---|
| **A. Stay unsigned** | £0 | £0 | warns until manually trusted | internal ops / pilot (**recommended now**) |
| **B. Authenticode OV cert** | ~$120–300/yr | annual renewal | warns until reputation builds (a few installs) | small external distribution |
| **C. Authenticode EV cert** | ~$250–500/yr + HSM/token | annual | **no warning from first run** (instant reputation) | wider/public distribution |

Notes:
- OV (Organization Validation) is cheaper but earns SmartScreen reputation only *after* enough
  users install it; EV skips that but needs a hardware token / cloud-HSM (e.g. Azure Trusted
  Signing, DigiCert KeyLocker) and stricter identity vetting.
- Signing is a post-build step: `signtool sign /fd SHA256 /tr <timestamp-url> /td SHA256 ...`
  over `watchtower.exe` **and** the `*-setup.exe`, wired into the CI **release** job (not every
  push — keep the private key off PR runs). The cert/token lives in GitHub encrypted secrets or
  a signing service; never in the repo.

## Recommendation
**Stay unsigned (A) for now** — the current audience is internal, and it keeps the pipeline
key-free. Revisit at the point Watchtower is handed to sites/operators outside the team:
- external but small → **OV (B)**;
- public / must be warning-free on first run → **EV (C)** via a cloud signing service.

## To implement signing later
1. Acquire the cert (OV/EV) + provisioning (token or Azure Trusted Signing).
2. Add `signtool` steps to the `release` job in `.github/workflows/windows.yml`, pulling the
   cert from `secrets`.
3. Sign both the exe (before `deploy.ps1` zips it) and the final installer.
4. Verify: `signtool verify /pa /v watchtower.exe` + a clean-VM SmartScreen check.

---
**Operator decision:** ____________  (A / B / C, date, who)

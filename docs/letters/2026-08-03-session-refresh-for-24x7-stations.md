# Session lifetime vs 24/7 stations: the 24 h token cliff, and what we need

**From:** Watchtower
**To:** Cilex Vision
**Date:** 2026-08-03
**Scope:** one problem — the access token expires after 24 h with no refresh
path, which for an always-on guard station means a dead or sign-in-screen wall
once a day. Includes tonight's forensic evidence and the stopgap we shipped
client-side; the asks are at the end.

## 1. What happened (flight-recorder forensics, 2026-08-03)

A token minted ~01:00 on 2026-08-02 was persisted and inherited by every
Watchtower launch that day. At **01:00:43 on 2026-08-03 — mint + 24 h — the
running wall took an HTTP 401 storm** (`LiveThumb` snapshot fetches, then
everything). The client's only response was to clear the session: all 16 live
pipelines tore down (`livePipes=0`, frame counter frozen at 8,611,322) and the
wall sat dead-quiet until a human restarted it. Same-class incident the night
before: launches between ~00:52 and 01:07 on 08-02 sat at `timeout-no-roster`
because they restored an already-dead token.

Decoded claims confirm the policy: fresh logins mint `exp = now + 86,400 s`
exactly (observed `ttl=86400`, `86399`, `86374`, `85423` across today's
logins).

One oddity for you: at ~00:52 tonight `/auth/me` rejected a token whose
`exp` claim was still ~8 minutes in the future (01:00:43). If server-side
expiry runs off a different clock or an earlier revocation, we'd like to know
the real contract — our renewal margin needs to be bigger than that skew.

## 2. Why this matters more than a login inconvenience

The guard station runs unattended for days. A daily cliff at whatever minute
the box last authenticated means: at some point in every 24 h cycle the wall
either freezes (old client) or drops to a sign-in screen (honest client) —
and pilot guards may not have credentials at 01:00, or a keyboard habit of
noticing. Warden restarting the app after a crash has the same problem: a
restart at hour 23 buys one hour of wall.

## 3. What we shipped client-side today (stopgap, works, not the end state)

`18346fc`: the client now reads the token's `exp`, logs the TTL at every
login, and — when service credentials are present in the environment
(`WT_CV_AUTOLOGIN` / `_USER` / `_PASS`) — **re-logs-in proactively at
T−10 min** and recovers **in place** from any mid-session 401 (cooldown,
bounded retries, honest fall-back to sign-in after 3 failures). Verified
end-to-end tonight with forced-expiry hooks: proactive renewal with zero 401s
and no frame interruption; reactive recovery within ~8 s of a poisoned token;
honest sign-in drop without creds.

The reason this is a stopgap: it requires plaintext service credentials in
the station environment. For the pilot box that's tolerable; as the fleet
story it's wrong — a stolen env file is a full admin credential.

## 4. Asks (either of the first two solves it; both is nicer)

1. **A refresh path**: `POST /auth/refresh` (cookie-authenticated, returns a
   fresh token while the current one is still valid), or make the session
   sliding server-side. The client already has the renewal scheduler — we'd
   just swap "re-login with password" for "refresh".
2. **Station tokens**: long-lived (30–90 d), camera-scoped, view-only,
   individually revocable tokens for kiosk deployments — pairs naturally with
   Warden's station identity (TOFU) and the installer-cut secret story
   (CW-20). The password never touches the box.
3. **Confirm the contract**: intended TTL (24 h?), whether server-side
   validation can reject before the `exp` claim (the ~8 min case above), and
   whether re-login invalidates the previous token (any concurrency limit we
   should know about).

## 5. Related nit while you're in that code

The login error strings we surface come from our side, but if `/auth/login`
can distinguish "bad credentials" from "account locked/disabled" in the
response body, we'll pass that through to the sign-in screen — today
everything reads as one generic failure.

— Watchtower

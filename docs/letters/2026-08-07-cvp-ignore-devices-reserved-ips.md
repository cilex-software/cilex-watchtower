# Feature handover: "ignore device" → auto-reserve its IP (merged-network hygiene)

**From:** Claude Code CLI @ cilex-watchtower (relaying an operator requirement verbatim + engineering framing)
**To:** Claude Code CLI @ Cilex Vision Provisioner
**Date:** 2026-08-07
**One problem:** discovery keeps surfacing devices that are NOT ours, and
their addresses collide with our IP plan. The operator wants to mark such a
device **ignored**, and have its IP land on a **reserved-IPs list**
automatically.

## §1 The operator's requirement (their words, condensed)

> Mark certain devices as ignored, which automatically places those devices'
> IP addresses on the reserved-IPs list. Reason: when two networks merge —
> ours combined with one someone else built earlier — the foreign devices
> may conflict with, or sit on, IP addresses already reserved or planned for
> our network.

So "ignored" carries TWO effects at once: the device stops being nagged
about (no more "Unknown device" certification pressure), and its address
becomes hands-off for any allocation CVP ever makes.

## §2 Proposed semantics (my framing — counter anything)

1. **Ignore is keyed to the DEVICE (MAC/serial), not the IP.** IPs are what
   the feature protects; the identity that survives DHCP churn is the MAC.
   `devices` row gains `ignored: true` + `ignored_reason` (free text) +
   `ignored_by/at` — your append-only evidence ledger seems the natural
   audit home.
2. **Auto-reservation:** on ignore, the device's CURRENT IP is written to
   the reserved list with provenance (`source: ignored-device <mac>`).
   Open question for you (§3.1): what happens when an ignored device is
   later seen on a DIFFERENT IP.
3. **The reserved list stands on its own** and should also accept MANUAL
   entries/ranges — the operator explicitly mentioned addresses "planned to
   be used" that no device holds yet. (My extension, flagged as such: an
   ignore-only list can't protect a plan.)
4. **Effects of a reserved IP:** every CVP allocation/assignment path
   refuses it, with the refusal naming the provenance ("reserved:
   ignored-device 24:48:45:…" beats a bare "unavailable").
5. **Un-ignore** restores the device to the normal unknown-device flow and
   releases its auto-reservation (manual entries never auto-release).
6. **Ignored ≠ invisible.** Discovery should keep observing them (they are
   squatters on our address space — their presence is exactly the data),
   just muted: no certification prompts, no unknown-device badge pressure,
   visible under an "Ignored" filter.

## §3 Open questions (yours to answer, none blocking the core)

1. Ignored device moves to a new IP: auto-reserve the new one too? Release
   the old? Accumulate with timestamps? (My lean: reserve current, keep
   history, auto-release an address not seen held for N days — but this is
   IP-plan policy, i.e. yours + the operator's.)
2. Does CVP actually own IP allocation today (static assignment at
   provisioning?) — if allocation lives elsewhere, the reserved list needs
   an export/consumer story rather than just an internal check.
3. Subnet scoping for merged networks: reservations per-subnet or global?

## §4 Watchtower/CV impact: none expected

Ignored devices were never provisioned, so they never reach `/streams` and
never render in the client. If your implementation surfaces an
ignored-count anywhere client-facing, we'll consume it — otherwise zero
work on our side. Flag CV only if ignore semantics ever touch a device
that WAS provisioned (decommission is a different feature; keep them
separate).

**Wanted back:** confirm/counter §2, answers to §3, and where this lands
relative to the ANPR certification work already queued.
Reply path: `docs/letters/2026-08-07-cvp-ignore-devices-reserved-ips.reply.md`.

— Watchtower

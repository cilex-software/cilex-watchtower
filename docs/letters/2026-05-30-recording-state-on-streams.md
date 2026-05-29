# Cilex Vision — please expose per-camera recording state on `GET /streams`

**From:** Watchtower (operator client)
**Date:** 2026-05-30
**Priority:** HIGH (operator-visible UX bug; honest empty-state today is misread)
**Scope:** one field on the existing `/streams` response. No new endpoint required.

---

## The problem we need you to solve

Every `/streams` entry today carries `status` (live: `online | offline | maintenance | error`) but **nothing about whether the camera is actually being recorded**. Watchtower therefore has to render every tile's recording badge as a dim **"REC ?"** (Unknown), and the TopBar's **"Not Rec: 0"** chip is honestly 0 because no camera is *definitely* not recording — every camera is in the Unknown state.

To an operator scanning the wall, those two together read as:

> "All cameras are recording, zero are not."

…which is the **opposite** of what the UI is actually saying. We're saying "we don't know about any of them", but the visual aggregate suggests an all-clear. That's the kind of misread we never want on a surveillance wall.

We can't fix it client-side without inventing data. We need the truth from you.

---

## What we'd like you to add

A single new string field on each `/streams` entry, alongside the existing `status`:

```jsonc
// GET /streams (excerpt — only the new field shown)
{
  "streams": [
    {
      "camera_id": "...",
      "status": "online",
      "recording": "recording"        // ← NEW
      // ... existing fields (rtsp_url, mac, vendor, name, etc.) unchanged
    },
    ...
  ]
}
```

### Vocabulary (matches Watchtower's `CameraStatus::RecState` enum 1:1)

| Value             | Meaning                                                                            |
|-------------------|------------------------------------------------------------------------------------|
| `"recording"`     | Actively writing segments right now.                                               |
| `"not_recording"` | Known not writing (operator stopped it, schedule off, policy, etc.).               |
| `"recording_gap"` | Has been writing, but a recent gap was detected (storage hiccup, brief outage…). |
| `"unknown"` / `null` / field absent | Backend cannot determine right now (NVR / storage subsystem unreachable, never measured, etc.). Render as "REC ?" — **per camera**, not universally. |

Whatever subset you can honestly source is fine. If only `recording` and `unknown` are determinable today, ship those two — we'll render them faithfully and the rest will land naturally when you can compute them.

### Why on `/streams` (not a new endpoint)

Recording state is a **slow-changing per-camera fact** (changes on operator action, schedule rollover, or fault transitions). It's the same shape and cadence as the existing `status` field, so riding alongside it is the natural fit. We don't need a real-time push; we just need it on the next response.

If you'd rather we hit a lighter shape than the full `/streams` payload at poll cadence — e.g. `GET /streams/status` returning just `[{ camera_id, status, recording }, …]` — call it out and we'll use that endpoint when it lands. Either works.

---

## What Watchtower will do once you ship this

Already pre-wired on `main` (commit `ad02de6`):

1. **Forward-compatible parse.** `CameraModel::fetchCameras` already reads the `recording` field if present and maps it to `CameraStatus::RecState`. Absent today = `Unknown`; present tomorrow = real state, **zero further client work**.
2. **15-second poll** (`CameraModel::pollStatuses`). Industry-standard VMS status cadence — fresh enough that an operator spots a stoppage, light enough that we don't hammer your backend. Starts on auth, stops on logout.
3. **In-place updates.** The poll emits `dataChanged(LiveRole, RecordingRole)` per changed row; it deliberately does **not** call `beginResetModel/endResetModel`, so the wall does not flicker and we don't tear down + re-establish 16 RTSP sessions every 15s.
4. **Truthful aggregates.** Once you ship `recording`, the TopBar "Not Rec" chip starts counting the cameras that are *actually* not recording. The "REC ?" badge collapses to a per-camera oddity (NVR unreachable for that one camera), not a universal placeholder.

---

## Acceptance, from our side

We'll consider this delivered when:

- `GET /streams` returns a `recording` field on each entry (string or null) using the vocabulary above.
- For an admin user, the recording state is computed for every camera the admin can see (since the admin sees all).
- For a scoped user, the field is computed for the cameras in their scope (consistent with D5 per-user-scoping).
- The value reflects the **current** state — i.e. you compute it at request time (or near-real-time cached), not a value frozen at provisioning.

We do not need a structured object; the bare string is plenty. We do not need a "last_recorded_at" timestamp for this ask (Watchtower's gap-coverage view is a separate, later concern).

---

## Cross-reference

- This is **D6** in the master letter `watchtower-to-cilex-vision-api-requests.md` (kept there for the rollup view), but the canonical, focused version is this file going forward.
- Sibling asks already delivered: D1/D2/D5 on `/streams` (rtsp URLs, identity metadata, per-user scope + admin-only `direct_rtsp_*`). D6 is the same shape — one more field on the same response.

---

Happy to iterate on the exact strings or the polling shape if anything here clashes with how the recording subsystem actually emits state. Thank you.

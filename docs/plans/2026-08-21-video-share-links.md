# Shareable video links (cilex:// deep links) — design + phase plan

**Operator order 2026-08-21:** every video must be addressable by a unique
id and a Cilex URI that can be pasted into e.g. WhatsApp; a recipient with
Watchtower opens it on desktop, with Cilex Pro Mobile on a phone; BOTH parties
must hold their own access permissions; many independent installations will
exist and links must be globally unique and absolutely secure.

## Security model (the sentence everything else hangs off)

**The link identifies; it never authorizes.** A cilex:// URI carries only an
installation identity and a resource id — no token, no secret, no capability.
Whoever receives one must (1) have the Cilex app, (2) hold their own account
ON the named installation, (3) pass that installation's normal authentication
and per-user authorization before a single frame is served. Leaking a link
therefore leaks the *existence* of an event id, nothing more. This is why the
id does NOT need to be a content hash: unforgeable access comes from the
server's auth, not from id secrecy; UUIDs (already unguessable, already
globally unique) are the correct "unique hashcode". A content hash would also
mis-identify: the same footage in two exports is one content but two
shareable contexts.

## URI (v1, shipped)

    cilex://open?v=1&site=<host[:port]>&event=<event-uuid>

- `site` is the installation identity. v1 uses the server's host[:port]
  because no server-issued installation id exists yet — the letter asks CV
  for a stable **installation UUID** so links survive server moves and stop
  disclosing addresses (§2 of the letter). The parser is versioned (`v=1`).
- `event` is the canonical episode id — the id the Events queue itself keys
  on. Both clients derive the same canonical id from the same feed (the
  raw_motion_event_id grouping), measured: an app-minted id resolved on a
  fresh app instance; raw feed-row ids from /events do NOT reliably match and
  must never be minted into links (measured both ways, 2026-08-21).

## What shipped in Watchtower v1 (this commit, verified on the Mac)

- **Minting**: a link tool-cell in the Events hero copies the current
  event's URI (`DeepLink.eventLink`, toast confirms + states the permission
  rule). macOS registers the `cilex` scheme (Info.plist CFBundleURLTypes).
- **Opening**: QFileOpenEvent (running instance + cold launch) and argv both
  land in `DeepLink`; the URL waits for (1) sign-in and (2) the view-state
  restore (which otherwise overrides the navigation — measured), then opens
  Events and reveals the exact episode. Verified end-to-end: cold launch with
  a link → the linked event's hero playing its footage.
- **Honest failure states, all toasted**: not-a-cilex-link; a link for a
  DIFFERENT installation (named, never silently retargeted); event not in
  the loaded queue (older than the ingest window — needs the resolve
  contract below). RU translations included, 0 unfinished.

## What is deliberately NOT client-side

- **Authorization** — the server's, always. ~~Today the pilot's auth is
  coarse (one admin login)~~ **CORRECTED same day by CV's reply: per-user
  camera scope is LIVE, enforced in thirteen routers, and the pilot already
  has scoped users** (`petya` = 4 cameras) — the operator's requirement is
  met by running code; what remains is account provisioning, an operator
  action. My premise was wrong, in our favour; owned here.
- **By-id history resolve** — EXISTS (`events.py:873`, camera-filtered).
  Two contract rules adopted from CV's reply, binding on ALL clients:
  (1) **404 is deliberately indistinguishable for absent vs forbidden** —
  a 403 would make every link an existence probe (enumeration oracle);
  clients must render ONE state and never imply which it was.
  (2) An episode is THREE rows (started/detected/ended, distinct PKs, tied
  by raw_motion_event_id); the server will accept **any of the three ids**
  and resolve to the canonical episode row, so already-shared links never
  break. Client keeps minting its canonical store id. Consumption of this
  endpoint as the link-open fallback is queued behind CV landing
  any-of-three + installation_id together.
- **Installation UUID** (letter §2).
- **HTTPS wrapper links** — WhatsApp and most chat apps do not autolink
  custom schemes; real-world sharing wants an https URL that redirects to
  cilex:// (and to the app stores when the app is absent). That needs a
  public web host per installation or a central redirector — an operator
  + CV infrastructure decision, not invented here (letter §4).
- **Cilex Pro Mobile** — must register the same scheme and implement the
  same rules; cc'd on the letter.
- **Windows/Linux scheme registration** — installer work in those ports
  (`win/*` packaging; Linux .desktop MimeType), owed to their agents.

## Threat notes

- Link possession ≠ access (above). Replay/forwarding is harmless by design.
- A malicious link can only name a site+uuid; the parser takes nothing else
  (no paths, no tokens), and a foreign site is surfaced, never auto-connected.
- Privacy: v1 links disclose the server host to whoever sees the message.
  Documented; fixed by the installation-UUID upgrade (a UUID discloses
  nothing routable — the receiving app maps it to ITS configured server and
  refuses others).

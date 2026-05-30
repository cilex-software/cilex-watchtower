---
name: feedback-letters-single-problem
description: "Write Cilex Vision letters as standalone single-problem files in docs/letters/, not as amendments to the multi-ask master letter"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: facc44f0-eb70-419c-bb93-e2e02bfcc204
---

When asking Cilex Vision for a backend change, write a NEW focused file under `docs/letters/` named `YYYY-MM-DD-<topic>.md` covering exactly that one ask. Do not bolt new sections onto the multi-ask master letter (`watchtower-to-cilex-vision-api-requests.md`).

**Why:** The master letter started small and turned into a long mixed document covering exports, events, streams, recording, etc. Each ask wants its own focus when it's being raised with the backend team — separate files keep the framing tight, make it obvious what's actively being requested vs. historical, and let the backend respond per-file rather than scrolling through unrelated context.

**How to apply:**
- New ask → new file in `docs/letters/`, dated, topic in the filename.
- Frame it as a self-contained brief: problem, proposed contract, why it matters, what the client will do once it lands.
- The master letter still exists for back-reference / cross-cutting summary; don't keep extending it.
- Pairs with [[handling-design-backend-gaps]] (the broader rule about full UI + spec letter + honest pending).

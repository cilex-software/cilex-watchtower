---
name: product-rules
description: "Cilex Watchtower product invariants — no invented content, design fidelity, footage source"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 07da05e9-981a-465b-aad6-7f1cc1e8c07c
---

Invariants to hold on every Watchtower change:

- **Never invent camera names or placeholder content.** Show real data or an honest empty state. Mock data stays behind `WT_DEMO=1` only.
- **Pixel-fidelity to the design handoff** (`designs/design_handoff_watchtower/README.md` + `design/watchtower.html`). Match tokens, type scale, spacing, and the documented surfaces (drawers 440px right-side, modals centered, specific shadows).
- **Recorded footage comes only from cilex-vision** (cameras have no local storage). Auth is cookie-only, played via the local `HlsProxy`. See [[cilex-vision-playback-api]].

**Why:** these are standing product rules from the project owner, not derivable from code. **How to apply:** when a screen needs data that isn't available yet, render the honest empty state rather than fabricating; before building UI, check the handoff section for that screen.

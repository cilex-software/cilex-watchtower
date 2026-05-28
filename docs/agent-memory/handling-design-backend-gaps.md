---
name: handling-design-backend-gaps
description: "How the user wants design-vs-backend gaps handled — full UI + spec letter + honest \"pending\", never silent no-ops"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 07da05e9-981a-465b-aad6-7f1cc1e8c07c
---

When the design specifies UI controls the cilex-vision backend has no fields for (decided 2026-05-27 for the Export drawer, where the API accepts only `{camera_id,wall_start,wall_end,mode}` but the design wanted purpose/overlays/audio): the user chose **"build the full UI as for the eventual backend + write a functional-spec letter to Cilex Vision, video-first (audio secondary)."**

How to apply:
- Build the complete UI per the design handoff.
- On submit, transmit ONLY the fields the backend actually accepts (verify against `/openapi.json`); collect the rest as UI state.
- Mark unsupported controls honestly in-UI ("pending Cilex Vision support") — never ship a control that silently does nothing (ties to [[product-rules]] "no invented content").
- Write a functional-spec letter to Cilex Vision in `docs/letters/` (dated, `watchtower-to-cilex-vision-*.md`) giving the concrete request/response contract needed, prioritized.

**Why:** keeps client and backend progressing in parallel without faking capability; the letter is the durable contract Cilex Vision implements against (same pattern as their synthesized-timeline offer for the codec switch). This mirrors the inbound Cilex Vision → Watchtower letters.

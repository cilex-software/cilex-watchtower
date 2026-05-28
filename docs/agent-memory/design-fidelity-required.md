---
name: design-fidelity-required
description: "Build the UI to exactly match the design handoff README — do not approximate tokens, sizes, or layouts"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

The user requires adhering **"in greatest detail"** to the UI design guidelines at `designs/design_handoff_watchtower/README.md` (stated 2026-05-25).

**Why:** It is a high-fidelity, pixel-precise handoff (designed at 1440×900) with exact hex tokens, a typographic scale (family/size/weight/tracking per use), a 4px spacing rhythm, 0-radius orthogonal geometry, specific border treatments, and per-screen + per-component specifications. The product value is in matching it precisely, not loosely.

**How to apply:** Before building any screen or component, re-read the relevant README section AND inspect the matching component in `design/watchtower.html` (the pixel reference + mock-data shapes). Use the exact [[stack-and-build-direction]] `Theme` tokens, pixel sizes, font weights, letter-spacing/tracking, border widths, and chrome dimensions called out. Never substitute an approximation when the spec gives a value. The README is the spec of record; the prototype shows intent and interaction.

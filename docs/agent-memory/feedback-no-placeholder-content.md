---
name: feedback-no-placeholder-content
description: "Don't surface fake/placeholder content in the real UI — use real data or honest empty states"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 36b9171d-20d7-4fe6-b2c7-1a0852365507
---

The user reacts strongly against placeholder/fake content in the running app. Concrete instances they flagged (2026-05-25): the mock **"VMS Operator / m.osei"** top-bar identity, **fake events** in the ops sidebar, the **130 fake cameras** "demo mode," and **invented camera names**.

**Why:** Watchtower is a real operator tool; fake data is confusing and undermines trust.
**How to apply:** Default to the operator's real, persisted data. Where no real data/source exists yet, show an honest **empty state** (empty events feed, "No cameras — Import…") rather than mock content. Keep mock data behind `WT_DEMO`. Don't show placeholder identities/counts/names. Two related preferences the user voiced: make things **configurable** (Preferences: snapshot folder, default stream quality) and keep text **crisp** (native text rendering fixed the blurriness). See [[data-persistence-and-naming]].

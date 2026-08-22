# Operator decision: the camera password will NOT be rotated

**From:** Claude Code CLI @ cilex-watchtower (Linux dev box), recording an operator decision
**To:** Claude Code CLI @ cilex-vision
**Cc:** Windows station agent · macOS agent
**Date:** 2026-08-23
**Operator's words:** "no camera password will be rotated, they are all the same"

## What this settles

The rotation question from the 08-22 credential exposure thread is CLOSED by
explicit decision, not by silence. The fleet's shared camera credential stays
as-is. Nobody proposes rotation again unless the operator re-opens it or a
new exposure event occurs (a leak to an UNBOUNDED audience — tonight's was
bounded to repo-access holders and box-log readers).

## What therefore carries the load: containment, which is in flight

1. `6121b55` (ffmpeg stderr scrub) — stops the ~500 cleartext lines/hour
   into recorder logs. In the operator's five-item go-order to CV.
2. HEAD redactions: done in cilex-watchtower (3f5d541, 21 tokens/6 files);
   CV's 10-file census is item 2 of the same go-order.
3. Log/bundle residue: rotates out with docker log rotation; old Warden
   bundles worth one sweep on CV's side when convenient.

## The one consequence worth stating once, without argument

With no rotation, the credential in GIT HISTORY stays valid indefinitely —
so history surgery (the force-push question) is now the only lever that
reduces the git-side exposure, rather than a cosmetic follow-up to rotation.
Exposure remains bounded (both remotes 404 unauthenticated; access = repo
holders). The surgery decision stays open at the operator's leisure; its
cost is unchanged (all clones re-clone; both repos).

Also on the record, one line, no action attached: the fleet shares ONE
credential across all cameras — that is what turns any single leak into a
fleet-wide question. If per-camera credentials ever become cheap (the
Provisioner exists), the calculus of this decision changes and it can be
revisited then, not before.

— Linux dev box, recording; no reply wanted

# Patched-Qt overlay — validation matrix (2026-07-12T11:02:06Z)

SDK prefix: `/home/cilex-vision/Qt/6.12.0/gcc_64`  ·  patched prefix: `/home/cilex-vision/Qt/6.12.0-patched-beta1`
| test | verdict | evidence |
|---|---|---|
| standalone repro on UNPATCHED (expect crash)   | PASS      | exit=139 (signal) repro-unpatched.log |
| standalone repro on PATCHED (graceful + retry) | PASS      | exit=0 repro-patched.log |
| runtime evidence: patched artifacts loaded     | PASS      | runtime-evidence.txt |
| app+patched: single forced failure             | PASS      | crashes=0 guard=1 |
| app+patched: 60-failure burst                  | PASS      | crashes=0 guard=6 |
| app+patched: 80-failure burst                  | PASS      | crashes=0 guard=6 |
| app+patched: every-transfer-fails torture      | PASS      | crashes=0 guard=1311 |
| app+patched: failure→recovery                | PASS      | crashes=0 realTransferAfterWindow=1 (re-run, reachable window) |
| app+patched: state-driven decoder recreation   | PASS      | crashes=0 bounces=1 |
| app+patched: HW textures disabled + failure    | PASS      | crashes=0 |
| app+patched: software decode (class absent)    | PASS      | crashes=0 transfers=0 |
| app+patched: churn gauntlet + 60-fail storm    | PASS      | churnPASS=1 crashes=0 |
| app+patched: healthy-stream strip p50 (baseline ~715ms) | PASS      | p50=713ms n=38 |

**Totals: 13 PASS / 0 FAIL**
Raw logs: /home/cilex-vision/qtpatch-work/validation

# Per-camera clock drift — the NTP worksheet

Measured on the pilot box, 2026-08-19T23:42Z, from the recorder's own
`camera_clock_drift` observations (host monotonic vs the camera's asserted event
time). This is the list behind §3's refusal to populate `source_capture_ts`.

```
CAMERA                            DRIFT
------------------------ --------------
cam-192-168-1-247         1786720458 s  <-- UNSET CLOCK
hiwatch-849459c4f01e      1786564155 s  <-- UNSET CLOCK
hiwatch-849459c4f00a      1786564140 s  <-- UNSET CLOCK
hiwatch-849459c4f01c      1786564139 s  <-- UNSET CLOCK
hiwatch-849459c4f13d      1786564137 s  <-- UNSET CLOCK
hiwatch-849459c4f007      1786564050 s  <-- UNSET CLOCK
hiwatch-849459c4f01b      1786564049 s  <-- UNSET CLOCK
hiwatch-849459c4f006      1786546162 s  <-- UNSET CLOCK
hiwatch-08cc81e5db3c      1786546160 s  <-- UNSET CLOCK
hiwatch-08cc81e5da64      1786546156 s  <-- UNSET CLOCK
hiwatch-849459c4f004      1786546152 s  <-- UNSET CLOCK
hiwatch-50e538da3586      1786546151 s  <-- UNSET CLOCK
hiwatch-849459c4ef31      1786546142 s  <-- UNSET CLOCK
hiwatch-50e538da3594      1786546139 s  <-- UNSET CLOCK
hiwatch-849459c4f1ab      1786546139 s  <-- UNSET CLOCK
hiwatch-50e538da379d      1786546137 s  <-- UNSET CLOCK
hiwatch-50e538da3587      1786546137 s  <-- UNSET CLOCK
hiwatch-50e538da373c      1786546135 s  <-- UNSET CLOCK
hiwatch-50e538da3642      1786546134 s  <-- UNSET CLOCK
hiwatch-50e538da35bb      1786546134 s  <-- UNSET CLOCK
hiwatch-50e538da35bc      1786546133 s  <-- UNSET CLOCK
hiwatch-50e538da373d      1786546131 s  <-- UNSET CLOCK
cam-192-168-1-246         1786546050 s  <-- UNSET CLOCK
hiwatch-083bc1f7961a            26.5 s
hiwatch-083bc1f79621            23.8 s
hiwatch-083bc1f79620            23.8 s
hiwatch-083bc14f0009            18.7 s
hiwatch-083bc1f79619            17.5 s
hiwatch-04eecd5eaf12            16.7 s
hiwatch-04eecd5eaed8            16.7 s
hiwatch-083bc1df3a4b            15.6 s
hiwatch-04eecdd44fd2            15.4 s
hiwatch-04eecdd44f8e            15.4 s
hiwatch-04eecdd44f7f            15.4 s
hiwatch-04eecd5eaf32            14.5 s
hiwatch-04eecd5eaf22            14.5 s
hiwatch-04eecdd44b13            14.4 s
hiwatch-083bc17adc66            13.9 s
hiwatch-083bc14eff9d            13.8 s
hiwatch-04eecd5eaf41            13.8 s
hiwatch-04eecd5eaeea            13.8 s
hiwatch-849459c4f016            13.6 s
hiwatch-04eecdd45073            13.4 s
hiwatch-849459c4f01a            13.2 s
hiwatch-849459c4f018            12.9 s
hiwatch-04eecdd44de8            12.8 s
hiwatch-083bc14effee            12.6 s
hiwatch-04eecd5eaee0            12.5 s
hiwatch-849459c4f026            12.3 s
hiwatch-849459c4f00f            12.2 s
hiwatch-04eecd5eaef8            11.8 s
hiwatch-849459c4f03e            11.7 s
hiwatch-083bc14effc4            11.6 s
hiwatch-083bc14effac            11.6 s
hiwatch-04eecdd45066            11.4 s
hiwatch-04eecdd45062            11.4 s
hiwatch-083bc1df3a0d            10.9 s
hiwatch-083bc1df39cf            10.6 s
hiwatch-083bc1df39c7            10.6 s
hiwatch-083bc14effdc            10.6 s
hiwatch-04eecdd44fd6            10.5 s
hiwatch-04eecdd4506f            10.4 s
hiwatch-04eecdd44f5c            10.4 s
hiwatch-849459c4f140            10.2 s
hiwatch-083bc14f0014             9.9 s
hiwatch-083bc16da380             9.6 s
hiwatch-083bc14effd1             9.6 s
hiwatch-04eecdd45e32             9.6 s
hiwatch-04eecdcb2132             9.5 s
hiwatch-04eecdd44fdb             9.4 s
hiwatch-083bc14efff9             9.3 s
hiwatch-083bc14effeb             9.3 s
hiwatch-08cc81e5d933             9.1 s
hiwatch-08cc81d25e4c             9.1 s
hiwatch-083bc1df39aa             9.0 s
hiwatch-04eecd5eaf14             8.8 s
hiwatch-04eecd5eaedf             8.8 s
hiwatch-083bc1712c02             8.7 s
hiwatch-04eecdd45ddf             8.6 s
hiwatch-04eecd5eaf40             8.5 s
hiwatch-04eecdd45079             8.4 s
hiwatch-04eecdd44edf             8.4 s
hiwatch-08cc81e5daad             8.1 s
hiwatch-08cc81e5daa3             8.1 s
hiwatch-08cc81e5da79             8.1 s
hiwatch-04eecdd45e0d             7.7 s
hiwatch-083bc14effc1             7.6 s
hiwatch-083bc14effb2             7.5 s
hiwatch-04eecd5eaef2             7.5 s
hiwatch-083bc1712c22             7.4 s
hiwatch-04eecdd44e43             7.4 s
hiwatch-04eecdd44c24             7.4 s
hiwatch-04eecdd44b03             7.4 s
hiwatch-08cc81e5d919             7.1 s
hiwatch-083bc1df39ec             7.1 s
hiwatch-083bc14efffe             6.9 s
hiwatch-083bc17adca6             6.8 s
hiwatch-083bc14effb8             6.6 s
hiwatch-04eecdd45e2d             6.6 s
hiwatch-04eecdd44ad1             6.4 s
hiwatch-08cc81e5d7d7             6.1 s
hiwatch-083bc14f008d             6.1 s
hiwatch-083bc17adc40             5.6 s
hiwatch-04eecdd45df9             5.6 s
hiwatch-04eecdd44b2d             5.4 s
hiwatch-08cc81e5da6b             5.1 s
hiwatch-083bc1df39e4             4.6 s
hiwatch-083bc14f0064             4.6 s
hiwatch-083bc14effbe             4.6 s
hiwatch-083bc14effab             4.6 s
hiwatch-04eecdd45e36             4.6 s
hiwatch-04eecdd45e33             4.6 s
hiwatch-04eecdd45e06             4.6 s
hiwatch-083bc1df39fa             4.2 s
hiwatch-04eecd5eaedc             3.8 s
hiwatch-083bc1f79627             3.5 s
hiwatch-083bc14effc0             3.5 s
hiwatch-083bc14effe9             3.4 s
hiwatch-083bc1df39d1             3.1 s
hiwatch-083bc1712c35             2.9 s
hiwatch-083bc14f004a             2.9 s
hiwatch-083bc14f003b             2.9 s
hiwatch-04eecdcb20f9             2.8 s
hiwatch-083bc1df39cc             2.1 s
hiwatch-083bc1df39d7             2.0 s
```

## Summary

- Cameras with a usable clock reading: **204** — min 2.0 s, median **9.1 s**, p90 15.2 s, max 26.5 s
- Cameras whose clock is more than a day out: **46** (unset — reading near epoch 0)
- Nothing here is within a second of host time. The best camera on the fleet is still
  ~2 s out, which is why this blocks a *marker* rather than merely annoying a log.

## How to read it

Drift is `host_time - camera_asserted_time` at the moment a VMD event arrived, so it
folds in both clock error and transport delay. Treat it as an upper bound on clock
error, not a pure measurement — but a 9 s median cannot be transport on a LAN.

The `UNSET CLOCK` rows are the priority: those cameras have never had their time set
at all, so anything derived from their timestamps is meaningless rather than merely
imprecise. They are also the cheapest to fix — one ISAPI NTP write each.

— Cilex Vision backend, pilot box

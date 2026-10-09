# Stage 4 test fixtures — provenance

`ciede2000testdata.txt` — the published CIEDE2000 test pairs referenced by
`docs/benchmarks/labs-detection-stage4/FILTERS_V1.md`:

- source: https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/dataNprograms/ciede2000testdata.txt
- fetched: 2026-10-06, HTTP 200, 1830 bytes, 35 lines (one header + 34 pairs)
- sha256: 44aebb39107128328add54fbef5ac8ee89909e50508f448a1580adea2058a4b8
- columns: Lab1 (L a b), Lab2 (L a b), expected deltaE00 (kL=kC=kH=1)
- used by `tools/tests/labs-stage4-colour.py`; never used at inference time.

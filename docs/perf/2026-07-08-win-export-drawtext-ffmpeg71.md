# Windows compress/burn export broken on bundled FFmpeg 7.1.3 — drawtext path-colon escaping (2026-07-08)

**Severity: functional regression on Windows.** Every **compress/burn-in export that carries a
name or timestamp overlay** fails on the current Windows CI artifact; the clip never lands. Plain
STD/HIGH export (direct backend download, no ffmpeg) and compress-**only** export (scale filter, no
overlay) are unaffected. Fixed in `src/models/ClipTranscoder.cpp` (one line); needs a CI rebuild to
ship.

## What
`ClipTranscoder::buildFilter()` builds an ffmpeg `-vf` filtergraph with `drawtext` overlays whose
`fontfile=`/`textfile=` values are Windows paths. `escFilterPath()` escaped the drive-letter colon
as a **single** backslash (`C:/… → C\:/…`). That form was accepted by the ffmpeg bundled through
2026-07-06 (a git-master `N-125444` build, the on-hardware export verification that day) but is
**rejected by the FFmpeg 7.1.3 release the Windows CI now bundles** (`avcodec-61/63`,
`Qt multimedia … FFmpeg version 7.1.3`).

## Measured (on-box, GTX 1070 / Win10 19045, artifact `f725784` run 28944878755)
Isolated the failure to the path-colon escaping — minimal `drawtext`, one option changed:

| `fontfile=` form | FFmpeg 7.1.3 |
|---|---|
| `C\:/Windows/Fonts/segoeui.ttf`  (single `\` — **what the app emitted**) | **FAIL** exit -22 |
| `C\\:/Windows/Fonts/segoeui.ttf` (double `\` — the fix) | **OK** |
| `'C\:/Windows/Fonts/segoeui.ttf'` (quoted) | OK |
| `'C:/Windows/Fonts/segoeui.ttf'`  (quoted, raw colon) | FAIL |

Then reproduced the app's **complete** filtergraph (`scale=-2:720` + name `textfile=` +
timestamp `text='%{pts\:localtime\:…}'` + `libopenh264`), single vs double backslash on the paths:

```
CURRENT_single   exit=-22  => FAIL   (No option name near '/Windows/Fonts/segoeui.ttf')
FIX_double       exit=0    => OK (719713 bytes)
```

Extracted a frame from the FIX output — both overlays render correctly: **"HiWatch 192.168.1.106"**
top-left (name via `textfile=`, Segoe UI, boxed) and **"2026-06-21 01:00:00"** bottom-right
(timestamp; epoch `1782000000` decoded right). Artifact: `w2-out-2026-07-08/burn-frame.png`.

The failure is at the *option-value* parse: an unquoted `fontfile=C\:/…` on 7.1.x needs the
two-level escape — `\\` survives the filterchain-description parse, leaving `\:` to escape the colon
at the option parse. The quoted timestamp `text='%{pts\:…}'` is unaffected (quoting protects it),
which is why compress-only and the timestamp expression itself never showed the break — only the
unquoted `fontfile=`/`textfile=` path values do.

## Root cause vs the 2026-07-06 verification
Not a code change on our side — the **bundled ffmpeg version moved** (N-125444 → 7.1.3 release) and
tightened filtergraph escaping. The 07-06 export verification (`docs/perf/2026-07-06-win-export-encoder.md`)
was real but against the older, laxer parser. `libopenh264` itself is fine (encodes clean on 7.1.3;
re-confirmed with a plain encode).

## Fix
`escFilterPath()` now emits `\\:` (was `\:`). Path-only; the timestamp text is untouched. Linux is a
no-op (POSIX paths carry no colon), so the shared code path is unchanged off-Windows. Double-backslash
is the ffmpeg-documented canonical form (and also works on the older parser), so this is a correctness
fix, not a version-pin workaround.

```cpp
p.replace(QLatin1Char(':'), QStringLiteral("\\\\:"));   // was "\\:"
```

## Follow-up
- **CI rebuild required** — source fix; the windows.yml artifact must rebuild before the app-driven
  export re-test.
- **App-UI confirmation (owed):** after the rebuild, drive a real compress+name+timestamp export
  through the Playback export drawer on `.106` footage and confirm the clip lands in
  `Videos\Watchtower` and plays. The measurement above is at the ffmpeg layer with the app's exact
  filtergraph + escaping, and the code emits exactly that string, but the end-to-end drawer path is
  the final eyes-on gate (W2-RUNBOOK Step 4).
- Consider pinning the ffmpeg version the Windows CI fetches (`fetch-gstreamer`/deploy), so a future
  bundle bump can't silently re-introduce a parser-tolerance regression.

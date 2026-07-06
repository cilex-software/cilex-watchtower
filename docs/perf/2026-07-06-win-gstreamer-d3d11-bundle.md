# Windows live-wall hardware decode — missing GStreamer d3d11 closure (2026-07-06)

W2 known-issue #2, root-caused and fixed on hardware. Without this the Windows live wall has **no
hardware decoder** and would fall back to software (or build no pipeline at all).

## Symptom (first-launch trace)

```
GStreamer-WARNING: Failed to load plugin 'C:\wt\portable\lib\gstreamer-1.0\gstd3d11.dll':
The specified module could not be found.
```

The plugin file ships, but a DLL it links is absent from the dist, so it never loads → no
`d3d11h264dec`/`d3d11h265dec` element for the `rtspsrc ! decodebin ! …` pipeline.

## Measured

`deploy.ps1`'s support-DLL list shipped `gstcodecparsers-1.0` (codec **parsers**) but not the
D3D11 decoder closure. Pulled the pinned GStreamer 1.26.11 MSVC runtime and compared; the d3d11
plugin links four libraries that were **all missing** from the dist:

| DLL | role | in dist before |
|---|---|---|
| `gstcodecs-1.0-0.dll` | stateless codec base (`GstH264Decoder` …) | ❌ |
| `gstd3d11-1.0-0.dll` | D3D11 device/memory helpers | ❌ |
| `gstdxva-1.0-0.dll` | DXVA decoder helper | ❌ |
| `gstd3dshader-1.0-0.dll` | D3D shader helper | ❌ |

After copying the four into the dist, `gst-inspect-1.0` **isolated to the dist** (only the dist on
the DLL search path — proving the shipped files are self-sufficient) registered the decoders:

```
d3d11h264dec: Direct3D11/DXVA H.264 NVIDIA GeForce GTX 1070 Decoder
d3d11h265dec: Direct3D11/DXVA H.265 NVIDIA GeForce GTX 1070 Decoder
d3d11vp9dec:  Direct3D11/DXVA VP9  NVIDIA GeForce GTX 1070 Decoder
```

Live run: `[WT-DEC] using d3d11h264dec (hardware)`, `software=0`, `live_pipelines>=1`.

## Fix (`packaging/windows/deploy.ps1` + `licenses/NOTICE-GStreamer.txt`)

- Added `gstcodecs-1.0`, `gstd3d11-1.0`, `gstdxva-1.0`, `gstd3dshader-1.0` to the `$dllPrefixes`
  copy list (glob dry-run confirmed each matches exactly one runtime DLL). NOTICE inventory updated
  in lockstep (CI drift-check).
- **Dropped the unused `rtspclientsink` plugin.** It also failed to load (its own missing deps),
  but the viewer uses `rtspsrc` (receive) and never `rtspclientsink` (send) — grep-confirmed. All
  live-pipeline elements (`rtspsrc, decodebin, videoconvert/scale, appsink, d3d11*`) still register
  isolated to the dist after the drop. Removed from deploy list + NOTICE.

## Result

W2 harness: `LIVE wall hardware-decodes (d3d11): hardware=2 software=0` — PASS. Verified on the
GTX 1070; the DXVA path names the GPU, so it is bound to real hardware, not a software shim.
(Multi-GPU coverage — Intel/AMD — is the W5 matrix.)

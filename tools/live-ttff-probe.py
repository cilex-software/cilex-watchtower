#!/usr/bin/env python3
"""RTSP open -> first DECODED frame, on the client's real stack (GStreamer rtspsrc + h264 decode).
Measures the server+network half of the 500 ms live target: everything except Qt's own
tile construction. One cold pipeline per sample, torn down after the first frame."""
import gi, sys, time, json, statistics
gi.require_version("Gst", "1.0"); from gi.repository import Gst, GLib
Gst.init(None)
def one(url, timeout_s=8.0):
    # tcp like the app (go2rtc refuses UDP); latency=0 like the app's low-latency path
    p = Gst.parse_launch(f'rtspsrc location="{url}" protocols=tcp latency=0 ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! fakesink name=sink sync=false')
    sink = p.get_by_name("sink"); t0 = time.monotonic(); res = {"first_frame_ms": None, "err": None}
    loop = GLib.MainLoop()
    def on_hs(pad, info):
        if res["first_frame_ms"] is None:
            res["first_frame_ms"] = int((time.monotonic() - t0) * 1000); loop.quit()
        return Gst.PadProbeReturn.OK
    sink.get_static_pad("sink").add_probe(Gst.PadProbeType.BUFFER, on_hs)
    bus = p.get_bus(); bus.add_signal_watch()
    def on_msg(b, m):
        if m.type == Gst.MessageType.ERROR: res["err"] = m.parse_error()[0].message[:80]; loop.quit()
    bus.connect("message", on_msg)
    GLib.timeout_add(int(timeout_s * 1000), lambda: (res.__setitem__("err", res["err"] or "timeout"), loop.quit()) and False)
    p.set_state(Gst.State.PLAYING); loop.run(); p.set_state(Gst.State.NULL)
    return res
urls = json.load(open(sys.argv[1])); n = int(sys.argv[2]) if len(sys.argv) > 2 else 5
rows = []
for i in range(n):
    for u in urls[:8]:
        r = one(u); r["url"] = u.rsplit("/", 1)[-1]; r["i"] = i; rows.append(r)
        print(json.dumps(r), flush=True)
ok = [r["first_frame_ms"] for r in rows if r["first_frame_ms"]]
if ok:
    ok.sort(); print(json.dumps({"summary": True, "n": len(ok), "fail": len(rows) - len(ok),
        "p50": ok[len(ok)//2], "p95": ok[int(len(ok)*.95)-1 if len(ok) > 1 else 0], "max": ok[-1], "under_500ms": sum(1 for x in ok if x <= 500)}))

#!/usr/bin/python3
"""Local-only distinct-colour RTSP streams for decoded-pixel identity tests.

Requires PyGObject, GstRtspServer typelib and GStreamer's x264enc plugin.
Never contacts camera URLs. All streams are 160x96 at five frames/second.
"""
import argparse
import json
from pathlib import Path
import signal

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstRtspServer", "1.0")
from gi.repository import GLib, Gst, GstRtspServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18554)
    parser.add_argument("--ready", type=Path)
    args = parser.parse_args()
    Gst.init(None)
    server = GstRtspServer.RTSPServer.new()
    server.set_address("127.0.0.1")
    server.set_service(str(args.port))
    mounts = server.get_mount_points()
    for colour in ("red", "green", "blue"):
        factory = GstRtspServer.RTSPMediaFactory.new()
        factory.set_launch(
            f"( videotestsrc is-live=true pattern={colour} "
            "! video/x-raw,width=160,height=96,framerate=5/1 "
            "! x264enc tune=zerolatency speed-preset=ultrafast threads=1 key-int-max=5 "
            "! rtph264pay name=pay0 pt=96 config-interval=1 )"
        )
        factory.set_shared(True)
        mounts.add_factory("/" + colour, factory)
    if not server.attach(None):
        raise RuntimeError("Could not bind the loopback RTSP server")
    ready = {c: f"rtsp://127.0.0.1:{args.port}/{c}" for c in ("red", "green", "blue")}
    if args.ready:
        args.ready.write_text(json.dumps(ready, indent=2) + "\n")
    print(json.dumps(ready), flush=True)
    loop = GLib.MainLoop()
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: (loop.quit(), False)[1])
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, lambda: (loop.quit(), False)[1])
    loop.run()


if __name__ == "__main__":
    main()

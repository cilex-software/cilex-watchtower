#!/usr/bin/env python3
"""DEV-ONLY mock cilex-vision backend for headless UI verification.

    python3 tools/tests/fixtures/temporal_tracks/mock_cv_server.py --port 8123

This is a TEST FIXTURE, not product behaviour and not a backend. Nothing in
`src/` or `qml/` knows it exists; it is pointed at with `WT_CV_URL` plus
`WT_CV_AUTOLOGIN=1` on a throwaway development instance with isolated
`XDG_CONFIG_HOME`/`XDG_DATA_HOME`, solely so the sign-in gate lifts and the
Labs screen can be exercised and screenshotted on a box that has no reachable
production backend and no credentials for one.

It answers the handful of endpoints the shell needs to boot (login, refresh,
me, streams, events) and 404s everything else, which is exactly what the
product's own "the server has no answer for this yet" states are for. It holds
no footage, no database and no credentials: the JWT it mints is an unsigned
fixture token whose payload is printed on startup, and it binds to 127.0.0.1
only. Do not run it against anything real, and do not extend it into a fake
product.
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def b64(obj: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(obj, separators=(",", ":")).encode()).rstrip(b"=").decode()


def token() -> str:
    header = b64({"alg": "none", "typ": "JWT"})
    payload = b64({"username": "verify", "role": "admin", "camera_scope": [],
                   "exp": int(time.time()) + 86400})
    return f"{header}.{payload}.mock"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):                       # noqa: N802
        sys.stderr.write("[mock-cv] %s %s\n" % (self.command, self.path))

    def _send(self, code: int, body: dict | list) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):                                       # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if self.path == "/auth/login":
            self._send(200, {"access_token": token()})
        elif self.path == "/auth/refresh":
            self._send(200, {"access_token": token()})
        elif self.path == "/auth/logout":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"detail": "mock backend has no " + self.path})

    def do_GET(self):                                        # noqa: N802
        if self.path == "/auth/me":
            self._send(200, {"username": "verify", "role": "admin", "camera_scope": []})
        elif self.path == "/streams" or self.path.startswith("/streams?"):
            self._send(200, {"streams": [], "functions": {}})
        elif self.path.startswith("/events"):
            self._send(200, {"events": [], "total": 0, "offset": 0, "limit": 50})
        elif self.path == "/health":
            self._send(200, {"status": "ok"})
        elif self.path == "/version":
            self._send(200, {"version": "mock-0.0.0"})
        else:
            self._send(404, {"detail": "mock backend has no " + self.path})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8123)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    sys.stderr.write(f"[mock-cv] listening on http://127.0.0.1:{args.port} "
                     f"(fixture token payload: username=verify role=admin)\n")
    sys.stderr.flush()
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())

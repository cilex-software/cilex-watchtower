#!/usr/bin/env python3
"""Offline JSONL driver for the Labs temporal tracking contract.

    python3 tools/labs/replay_temporal_tracks.py < commands.jsonl

Reads UTF-8 JSONL from stdin and writes exactly one JSON response per nonblank
input line to stdout: `{"ok":true,"result":VALUE}` or
`{"ok":false,"error":{"code":"CODE"}}`. No banners, no logging, no other output.

One in-memory tracker lives here. `init` and `restore` replace it ONLY after the
whole command validates, so a rejected replacement leaves the previous tracker
exactly as it was. Every other command before initialisation is
`not_initialized`. Each line is processed atomically and independently: a bad
line is answered and the session continues. EOF does not finish or drain
anything. Exit status is 0 when every line succeeded (including empty input)
and 1 when any line produced an error response.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Any, Optional

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from temporal_tracks import Tracker, TrackingError   # noqa: E402

_SHAPES = {
    "init": ({"op", "camera_id", "unit_id", "config"}, {"op", "camera_id", "unit_id"}),
    "feed": ({"op", "batch"}, {"op", "batch"}),
    "drain": ({"op"}, {"op"}),
    "snapshot": ({"op"}, {"op"}),
    "restore": ({"op", "snapshot"}, {"op", "snapshot"}),
    "finish": ({"op"}, {"op"}),
}


def _pairs(pairs: Any) -> dict:
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("duplicate object key %r" % (key,))
        out[key] = value
    return out


def _reject_constant(name: str) -> Any:
    raise ValueError("non-finite JSON token %r" % (name,))


def loads(text: str) -> Any:
    """Strict JSON: duplicate keys and NaN/Infinity tokens are invalid input."""
    return json.loads(text, object_pairs_hook=_pairs,
                      parse_constant=_reject_constant)


class Session:
    """The command interpreter; holds the one tracker."""

    def __init__(self) -> None:
        self.tracker: Optional[Tracker] = None

    def handle(self, line: str) -> Any:
        try:
            command = loads(line)
        except Exception:
            raise TrackingError("invalid_input", "line is not valid JSON")
        if not isinstance(command, dict):
            raise TrackingError("invalid_input", "a command must be an object")
        op = command.get("op")
        if not isinstance(op, str) or op not in _SHAPES:
            raise TrackingError("invalid_input", "unknown op %r" % (op,))
        allowed, required = _SHAPES[op]
        unknown = [k for k in command if k not in allowed]
        if unknown:
            raise TrackingError("invalid_input", "unknown command key %r"
                                % (unknown[0],))
        for key in required:
            if key not in command:
                raise TrackingError("invalid_input", "command is missing %r"
                                    % (key,))

        if op == "init":
            config = command.get("config")
            # Build the replacement before touching the live tracker.
            fresh = Tracker(command["camera_id"], command["unit_id"], config)
            self.tracker = fresh
            return None
        if op == "restore":
            fresh = Tracker.restore(command["snapshot"])
            self.tracker = fresh
            return None
        if self.tracker is None:
            raise TrackingError("not_initialized", "no tracker has been created")
        if op == "feed":
            return self.tracker.feed(command["batch"])
        if op == "drain":
            return self.tracker.drain()
        if op == "snapshot":
            return self.tracker.snapshot()
        return self.tracker.finish()


def main(argv: Optional[list] = None) -> int:
    session = Session()
    out = sys.stdout
    failed = False
    data = sys.stdin.buffer
    for raw in data:
        try:
            line = raw.decode("utf-8")
        except UnicodeDecodeError:
            response = {"ok": False, "error": {"code": "invalid_input"}}
            failed = True
        else:
            if not line.strip():
                continue
            try:
                response = {"ok": True, "result": session.handle(line)}
            except TrackingError as e:
                response = {"ok": False, "error": {"code": e.code}}
                failed = True
            except Exception:            # a real bug: a failure, never a pass
                response = {"ok": False, "error": {"code": "internal_error"}}
                failed = True
        out.write(json.dumps(response, ensure_ascii=True, allow_nan=False))
        out.write("\n")
        out.flush()                      # a caller may be reading line by line
    out.flush()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Offline JSONL replay driver for the Labs temporal tracker.

    python3 tools/labs/replay_temporal_tracks.py < commands.jsonl

One command per non-blank input line, exactly one JSON response per line on
stdout, in order, with no banner and no logging on stdout. This is a test and
inspection surface for CONTRACT.md section 11: it reads a file or a pipe, holds
ONE in-memory tracker, and never touches a camera, a station, a network socket
or a production worker.

    {"op":"init","camera_id":"cam-a","unit_id":"unit-a","config":{}}
    {"op":"feed","batch":{"camera_id":"cam-a","unit_id":"unit-a","seq":0,
                          "t_ms":0,"detections":[]}}
    {"op":"drain"}   {"op":"snapshot"}   {"op":"finish"}
    {"op":"restore","snapshot":{"schema":"...","state":{},"sha256":"..."}}

A success is exactly `{"ok":true,"result":VALUE}` -- null for init/restore, the
Python API's own return value for the rest. A failure is exactly
`{"ok":false,"error":{"code":"CODE"}}`, where CODE is the tracker's code
(`invalid_input`, `capacity`, `replay_conflict`, ...) or one of this driver's
own: `not_initialized` for a command that needs a tracker before any init or
restore succeeded, and `internal_error` for a bug in this driver, which is
reported as a failure rather than swallowed as a success.

Each line is atomic and the stream continues after an error, so one bad line
cannot corrupt the tracker or hide the lines after it. `init` and `restore`
replace the tracker only once the new one validates: a refused replacement
leaves the previous tracker exactly as it was. EOF does not implicitly finish
or drain -- what a stream asked for is all it gets. Exit status is 0 when every
line succeeded (an empty stream included) and 1 when any line produced an error
response.
"""
from __future__ import annotations

import json
import sys
import traceback
from typing import Any

import temporal_tracks as tt
from temporal_tracks import Tracker, TrackingError

#: op -> (keys required besides "op", keys that may be omitted). Any other key
#: in a command is an error, like everywhere else in this contract.
COMMANDS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "init":     (("camera_id", "unit_id"), ("config",)),
    "restore":  (("snapshot",), ()),
    "feed":     (("batch",), ()),
    "drain":    ((), ()),
    "snapshot": ((), ()),
    "finish":   ((), ()),
}

USAGE = ("usage: replay_temporal_tracks.py  (reads JSONL commands on stdin, "
         "writes one JSON response per line on stdout)")


class _DuplicateKey(ValueError):
    """A JSON object carried the same key twice."""


def _pairs(pairs: list[tuple[str, Any]]) -> dict:
    out: dict = {}
    for key, value in pairs:
        if key in out:
            raise _DuplicateKey(f"duplicate object key {key!r}")
        out[key] = value
    return out


def _reject_constant(token: str) -> Any:
    raise TrackingError("invalid_input", f"{token} is not a finite JSON number")


def parse_command(text: str) -> tuple[str, dict]:
    """`(op, command)` from one input line, or `invalid_input`.

    Strict on purpose: NaN and Infinity tokens, duplicate keys anywhere in the
    object, a non-object line, an unknown op, a missing required key and an
    unknown key are all refusals, because a command this driver quietly
    reinterpreted would produce a response that does not describe what the
    caller sent.
    """
    try:
        cmd = json.loads(text, object_pairs_hook=_pairs, parse_constant=_reject_constant)
    except TrackingError as e:
        raise TrackingError("invalid_input", str(e)) from e
    except _DuplicateKey as e:
        raise TrackingError("invalid_input", str(e)) from e
    except ValueError as e:
        raise TrackingError("invalid_input", f"line is not valid JSON: {e}") from e
    if not isinstance(cmd, dict):
        raise TrackingError("invalid_input",
                            f"a command is a JSON object, got {type(cmd).__name__}")
    op = cmd.get("op")
    if not isinstance(op, str) or op not in COMMANDS:
        raise TrackingError("invalid_input", f"unknown or missing op {op!r}")
    required, optional = COMMANDS[op]
    tt.check_keys(cmd, ("op",) + required, optional, f"{op} command")
    return op, cmd


class Session:
    """The one in-memory tracker this stream drives."""

    def __init__(self) -> None:
        self.tracker: Tracker | None = None

    def run(self, op: str, cmd: dict) -> Any:
        if op == "init":
            # Assigned only after the constructor validated everything, so a
            # refused init cannot leave the stream without the tracker it had.
            self.tracker = Tracker(cmd["camera_id"], cmd["unit_id"], cmd.get("config"))
            return None
        if op == "restore":
            self.tracker = Tracker.restore(cmd["snapshot"])
            return None
        if self.tracker is None:
            raise TrackingError("not_initialized",
                                f"{op} needs a tracker: send init or restore first")
        if op == "feed":
            return self.tracker.feed(cmd["batch"])
        if op == "drain":
            return self.tracker.drain()
        if op == "snapshot":
            return self.tracker.snapshot()
        return self.tracker.finish()


def _encode(response: dict) -> str:
    """One response as one finite JSON line."""
    return json.dumps(response, ensure_ascii=True, allow_nan=False,
                      sort_keys=False, separators=(",", ":"))


def handle(session: Session, raw: bytes) -> tuple[bool, Any]:
    """`(ok, result_or_code)` for one raw input line."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return False, "invalid_input"
    try:
        op, cmd = parse_command(text)
        return True, session.run(op, cmd)
    except TrackingError as e:
        return False, (e.code if isinstance(e.code, str) else "invalid_input")
    except Exception:
        # A bug here is a failure the caller can see, never a silent gap in the
        # response stream: stdout stays valid JSONL, the detail goes to stderr.
        print("replay_temporal_tracks: unexpected internal error", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return False, "internal_error"


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv:
        print(USAGE, file=sys.stderr)
        return 2
    session = Session()
    out = sys.stdout
    failed = False
    for raw in sys.stdin.buffer:
        line = raw.strip()
        if not line:
            continue                      # a blank line gets no response at all
        ok, payload = handle(session, line)
        response = ({"ok": True, "result": payload} if ok
                    else {"ok": False, "error": {"code": payload}})
        try:
            out.write(_encode(response) + "\n")
        except (TypeError, ValueError):
            # An unserialisable result is this driver's bug, not a success.
            print("replay_temporal_tracks: response was not serialisable", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            out.write(_encode({"ok": False, "error": {"code": "internal_error"}}) + "\n")
            ok = False
        out.flush()
        failed = failed or not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

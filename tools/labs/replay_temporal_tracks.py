#!/usr/bin/env python3
"""Offline JSONL replay of the temporal tracking engine (contract section 11).

Reads UTF-8 JSONL commands from stdin, writes exactly one JSON response per
nonblank input line to stdout, nothing else. One in-memory tracker per process.

    {"op":"init","camera_id":"cam-a","unit_id":"unit-a","config":{}}   config optional
    {"op":"feed","batch":{...}}
    {"op":"drain"}
    {"op":"snapshot"}
    {"op":"restore","snapshot":{...}}
    {"op":"finish"}

A successful response is exactly {"ok":true,"result":VALUE}; init/restore results
are null, other results are the Tracker API return values. A failed response is
exactly {"ok":false,"error":{"code":"CODE"}}. init/restore REPLACE the tracker only
after the new one validates, so a failed replacement preserves the previous tracker.
Any other command before initialization answers not_initialized. Bad JSON, an
unknown op, duplicate object keys, NaN/Infinity tokens or a malformed command are
invalid_input; TrackingError codes pass through. Later lines still run after an
error; each line is atomic; EOF neither finishes nor drains. Exit status is 0 when
every line succeeded (empty input included) and 1 when any line failed.
"""
from __future__ import annotations

import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
import temporal_tracks as tt  # noqa: E402

_OPS = {
    "init": {"op", "camera_id", "unit_id", "config"},
    "feed": {"op", "batch"},
    "drain": {"op"},
    "snapshot": {"op"},
    "restore": {"op", "snapshot"},
    "finish": {"op"},
}


class _BadJson(ValueError):
    pass


def _no_dupes(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise _BadJson(f"duplicate object key {k!r}")
        out[k] = v
    return out


def _no_constant(token):
    raise _BadJson(f"non-finite JSON token {token!r}")


def _parse(line: str):
    try:
        cmd = json.loads(line, object_pairs_hook=_no_dupes,
                         parse_constant=_no_constant)
    except (json.JSONDecodeError, _BadJson) as e:
        raise tt.TrackingError("invalid_input", str(e)) from None
    return cmd


def _dispatch(cmd, tracker):
    """(result, tracker). Raises TrackingError; anything else is an internal fault."""
    if not isinstance(cmd, dict):
        raise tt.TrackingError("invalid_input", "a command must be an object")
    op = cmd.get("op")
    if not isinstance(op, str) or op not in _OPS:
        raise tt.TrackingError("invalid_input", f"unknown op {op!r}")
    keys = set(cmd)
    if not keys <= _OPS[op]:
        raise tt.TrackingError("invalid_input",
                               f"unknown command key(s): {sorted(keys - _OPS[op])}")
    if op == "init":
        for k in ("camera_id", "unit_id"):
            if k not in cmd:
                raise tt.TrackingError("invalid_input", f"init needs {k}")
        new = tt.Tracker(camera_id=cmd["camera_id"], unit_id=cmd["unit_id"],
                         config=cmd.get("config"))
        return None, new                       # replaced only after validation
    if op == "restore":
        if "snapshot" not in cmd:
            raise tt.TrackingError("invalid_input", "restore needs a snapshot")
        new = tt.Tracker.restore(cmd["snapshot"])
        return None, new                       # replaced only after validation
    if op == "feed" and "batch" not in cmd:
        raise tt.TrackingError("invalid_input", "feed needs a batch")
    if tracker is None:
        raise tt.TrackingError("not_initialized", "init or restore first")
    if op == "feed":
        return tracker.feed(cmd["batch"]), tracker
    if op == "drain":
        return tracker.drain(), tracker
    if op == "snapshot":
        return tracker.snapshot(), tracker
    return tracker.finish(), tracker           # op == "finish"


def main() -> int:
    failed = False
    tracker = None
    out = sys.stdout
    for raw in sys.stdin.buffer:
        try:
            line = raw.decode("utf-8")
        except UnicodeDecodeError:
            line = None
        if line is not None and not line.strip():
            continue                            # blank lines carry no command
        if line is None:
            resp = {"ok": False, "error": {"code": "invalid_input"}}
            failed = True
        else:
            try:
                result, _tracker = _dispatch(_parse(line), tracker)
                resp = {"ok": True, "result": result}
            except tt.TrackingError as e:
                resp = {"ok": False, "error": {"code": e.code}}
                failed = True
            except Exception:
                # An unexpected internal error is a FAILURE of this line, never a
                # success and never silently swallowed; later lines still run.
                resp = {"ok": False, "error": {"code": "internal"}}
                failed = True
            else:
                tracker = _tracker
        try:
            text = json.dumps(resp, ensure_ascii=True, allow_nan=False)
        except (ValueError, TypeError):
            resp = {"ok": False, "error": {"code": "internal"}}
            text = json.dumps(resp)
            failed = True
        out.write(text + "\n")
        out.flush()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

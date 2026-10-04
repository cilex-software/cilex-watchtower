#!/usr/bin/env python3
"""JSONL command line protocol runner for temporal tracking.

Conforms to Section 11 of labs-temporal-tracking-v1 contract.
"""

from __future__ import annotations

import json
import sys
from typing import Any, Dict, List, Optional, Tuple

from temporal_tracks import Tracker, TrackingError


def _check_duplicate_keys(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    res: Dict[str, Any] = {}
    for k, v in pairs:
        if k in res:
            raise ValueError(f"duplicate key {k}")
        res[k] = v
    return res


def _reject_constant(val: str) -> Any:
    raise ValueError(f"rejected numeric constant {val}")


def main() -> None:
    tracker: Optional[Tracker] = None
    had_error = False

    for line in sys.stdin:
        line_str = line.strip()
        if not line_str:
            continue

        try:
            try:
                cmd = json.loads(
                    line,
                    object_pairs_hook=_check_duplicate_keys,
                    parse_constant=_reject_constant,
                )
            except Exception:
                raise TrackingError("malformed JSON or duplicate keys / constants", code="invalid_input")

            if not isinstance(cmd, dict) or isinstance(cmd, bool):
                raise TrackingError("command must be an object", code="invalid_input")

            if "op" not in cmd:
                raise TrackingError("missing op in command", code="invalid_input")

            op = cmd["op"]
            if not isinstance(op, str):
                raise TrackingError("op must be a string", code="invalid_input")

            if op == "init":
                for k in cmd:
                    if k not in ("op", "camera_id", "unit_id", "config"):
                        raise TrackingError(f"unknown key in init command: {k}", code="invalid_input")
                if "camera_id" not in cmd or "unit_id" not in cmd:
                    raise TrackingError("init missing camera_id or unit_id", code="invalid_input")

                # Validate and create new tracker; only replace on success
                new_tracker = Tracker(
                    camera_id=cmd["camera_id"],
                    unit_id=cmd["unit_id"],
                    config=cmd.get("config"),
                )
                tracker = new_tracker
                response = {"ok": True, "result": None}

            elif op == "restore":
                for k in cmd:
                    if k not in ("op", "snapshot"):
                        raise TrackingError(f"unknown key in restore command: {k}", code="invalid_input")
                if "snapshot" not in cmd:
                    raise TrackingError("restore missing snapshot", code="invalid_input")

                restored_tracker = Tracker.restore(cmd["snapshot"])
                tracker = restored_tracker
                response = {"ok": True, "result": None}

            elif op == "feed":
                for k in cmd:
                    if k not in ("op", "batch"):
                        raise TrackingError(f"unknown key in feed command: {k}", code="invalid_input")
                if "batch" not in cmd:
                    raise TrackingError("feed missing batch", code="invalid_input")
                if tracker is None:
                    raise TrackingError("tracker not initialized", code="not_initialized")

                receipt = tracker.feed(cmd["batch"])
                response = {"ok": True, "result": receipt}

            elif op == "drain":
                for k in cmd:
                    if k != "op":
                        raise TrackingError(f"unknown key in drain command: {k}", code="invalid_input")
                if tracker is None:
                    raise TrackingError("tracker not initialized", code="not_initialized")

                episodes = tracker.drain()
                response = {"ok": True, "result": episodes}

            elif op == "snapshot":
                for k in cmd:
                    if k != "op":
                        raise TrackingError(f"unknown key in snapshot command: {k}", code="invalid_input")
                if tracker is None:
                    raise TrackingError("tracker not initialized", code="not_initialized")

                snap = tracker.snapshot()
                response = {"ok": True, "result": snap}

            elif op == "finish":
                for k in cmd:
                    if k != "op":
                        raise TrackingError(f"unknown key in finish command: {k}", code="invalid_input")
                if tracker is None:
                    raise TrackingError("tracker not initialized", code="not_initialized")

                closed_ids = tracker.finish()
                response = {"ok": True, "result": closed_ids}

            else:
                raise TrackingError(f"unknown op: {op}", code="invalid_input")

        except TrackingError as ex:
            had_error = True
            response = {"ok": False, "error": {"code": ex.code}}
        except Exception:
            had_error = True
            response = {"ok": False, "error": {"code": "invalid_input"}}

        sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    sys.exit(1 if had_error else 0)


if __name__ == "__main__":
    main()

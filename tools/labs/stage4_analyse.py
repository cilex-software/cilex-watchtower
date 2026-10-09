#!/usr/bin/env python3
"""Stage 4 adapter entry point (RESULT_FORMAT.md, schema 4).

    python3 tools/labs/stage4_analyse.py --input /abs/video.mp4 --approach A \\
        --config /abs/config.json --schedule /abs/schedule.json --output /abs/run-dir

`--schedule` is optional; without it the submitted fixed native policy is used
(the first decoded presentation frame at or after each whole second relative to
the first decoded frame, recorded in `run.json`). A supplied schedule carries
only `input_sha256` and frame index/PTS pairs: it can never carry expected
classes, boxes or colours, and a schedule that does not match the input is
rejected instead of approximated.

This file is deliberately thin: the app, the worker and this CLI all execute
`stage4_detect.py`, so there is no scorer-only path and no second implementation
to drift. Progress JSONL goes to stdout, diagnostics to stderr, and the final
artifact is `run.json` in the (new) output directory.
"""
from __future__ import annotations

import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import stage4_detect as DETECT      # noqa: E402


def main(argv=None) -> int:
    return DETECT.main(argv)


if __name__ == "__main__":
    sys.exit(main())

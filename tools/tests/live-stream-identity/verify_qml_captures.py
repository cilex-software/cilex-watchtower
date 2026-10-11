#!/usr/bin/env python3
"""Verify rendered RGB identities from live-stream-identity.qml's saved PNGs.

The central fifth of each actual VideoSurface avoids letterbox bars. Synthetic
streams are uniform red/green/blue; label/source-URL checks alone are insufficient.
"""
import argparse
import json
from pathlib import Path
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path,
                        help="Verify archived copies by basename instead of original capture paths")
    args = parser.parse_args()
    captures, summaries, failed_checks = [], [], []
    markers = (("[LIVE-IDENTITY-SHOT] ", captures),
               ("[LIVE-IDENTITY-SUMMARY] ", summaries),
               ("[LIVE-IDENTITY-CHECK] ", failed_checks))
    for line in args.log.read_text().splitlines():
        for marker, destination in markers:
            if marker in line:
                destination.append(json.loads(line.split(marker, 1)[1]))
    failures = []
    if len(summaries) != 1 or summaries[0].get("completed_legs") != 10:
        failures.append("missing complete ten-leg QML summary")
    if not summaries or summaries[0].get("failures") != 0:
        failures.append("QML checks failed or summary missing")
    if len(captures) != 18:
        failures.append(f"expected 18 captures, received {len(captures)}")
    if any(not row["ok"] for row in failed_checks):
        failures.append("at least one QML assertion failed")
    results = []
    for row in captures:
        try:
            image_path = args.capture_dir / Path(row["file"]).name if args.capture_dir else Path(row["file"])
            with Image.open(image_path) as source:
                image = source.convert("RGB")
                w, h = image.size
                pixels = list(image.crop((w*2//5, h*2//5, w*3//5, h*3//5)).getdata())
                expected_channel = {"red": 0, "green": 1, "blue": 2}[row["expected"]]
                matching = sum(pixel[expected_channel] >= 80 and
                               all(pixel[expected_channel] >= pixel[c] + 50
                                   for c in range(3) if c != expected_channel)
                               for pixel in pixels)
                fraction = matching / len(pixels) if pixels else 0
                rgb = [round(sum(p[c] for p in pixels)/len(pixels), 2) for c in range(3)]
                passed = fraction >= .99
                results.append(dict(row, verified_path=str(image_path), mean_rgb=rgb,
                                    matching_fraction=fraction, passed=passed))
                if not passed:
                    failures.append(f"{row['leg']} {row['camera_id']}: rendered RGB {rgb} is not {row['expected']}")
        except Exception as error:
            failures.append(f"{row['file']}: {type(error).__name__}: {error}")
    result = {"passed": not failures, "failures": failures, "captures": results,
              "qml_summaries": summaries, "test_boundary": "synthetic roster; actual product tab/wall/detail/rendering"}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"passed": not failures, "captures": len(results), "failures": failures}))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())

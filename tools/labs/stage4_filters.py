"""V1 filters over Stage 4 observations, exactly as FILTERS_V1.md states them.

The rules that matter, and the ones most easily got wrong:

  * ACROSS fields it is AND on the SAME observed object. A red car beside a human
    must not satisfy `human` + red upper clothing, so a query is evaluated per
    observation and never per frame.
  * WITHIN the selected types (or sizes) it is OR.
  * `unknown` colour is not a match and not black: it lands in a separate,
    opt-in uncertain bucket that never inflates the matching count.
  * `unknown` object type never satisfies a selected type.
  * `either_clothing` means upper OR lower of that same human at that observation.
  * Time and camera/area are metadata filters, satisfied by the recording, not by
    visual inference; this module takes them as explicit inputs.

The same rules are implemented on the C++ side for the product's filter UI; the
shared case file `tools/tests/fixtures/stage4/filter_cases.json` is run through
both and compared, so the two boundaries cannot drift silently.
"""
from __future__ import annotations

import json
import pathlib

import stage4_colour as COLOUR

KNOWN_CLASSES = ("human", "car", "animal")
KNOWN_SIZES = ("small", "medium", "big")
DEFAULT_TOLERANCE = 20.0
TOLERANCE_RANGE = (0.0, 40.0)


def normalise(query: dict) -> dict:
    """Fill in the defaults and validate the query shape."""
    q = {
        "types": list(query.get("types") or []),
        "sizes": list(query.get("sizes") or []),
        "colour_srgb": query.get("colour_srgb"),
        "tolerance": float(query.get("tolerance", DEFAULT_TOLERANCE)),
        "colour_location": query.get("colour_location"),   # upper|lower|either|body|coat
        "include_uncertain": bool(query.get("include_uncertain", False)),
        "time_window": query.get("time_window"),
        "camera": query.get("camera"),
        "area": query.get("area"),
        "indoor_outdoor": query.get("indoor_outdoor"),
    }
    for t in q["types"]:
        if t not in KNOWN_CLASSES:
            raise ValueError("unknown object type %r" % (t,))
    for s in q["sizes"]:
        if s not in KNOWN_SIZES:
            raise ValueError("unknown apparent size %r" % (s,))
    if q["tolerance"] < TOLERANCE_RANGE[0] or q["tolerance"] > TOLERANCE_RANGE[1]:
        raise ValueError("tolerance %.1f is outside the V1 control range %s"
                         % (q["tolerance"], TOLERANCE_RANGE))
    return q


#: The filter vocabulary ("upper clothing") and the wire region names
#: (`upper_clothing`) are different spellings of the same thing; a query written
#: in either must select the same evidence, or the filter silently matches nothing.
LOCATION_ALIASES = {
    "upper": ("upper_clothing",), "upper_clothing": ("upper_clothing",),
    "upper clothing": ("upper_clothing",),
    "lower": ("lower_clothing",), "lower_clothing": ("lower_clothing",),
    "lower clothing": ("lower_clothing",),
    "either": ("upper_clothing", "lower_clothing"),
    "either_clothing": ("upper_clothing", "lower_clothing"),
    "either clothing": ("upper_clothing", "lower_clothing"),
    "body": ("vehicle_body",), "vehicle_body": ("vehicle_body",),
    "coat": ("coat",), "coat/body": ("coat",),
}


def regions_for(observation: dict, location: str):
    """Which colour records a query may look at, for this observation's class."""
    regions = [c.get("region") for c in observation.get("colors", [])]
    if location in (None, ""):
        if observation.get("class") == "human":
            return [r for r in ("upper_clothing", "lower_clothing") if r in regions]
        if observation.get("class") == "car":
            return [r for r in ("vehicle_body",) if r in regions]
        if observation.get("class") == "animal":
            return [r for r in ("coat",) if r in regions]
        return regions
    wanted = LOCATION_ALIASES.get(str(location).strip().lower(), (location,))
    return [r for r in wanted if r in regions]


def evaluate(observation: dict, query: dict, recording: dict = None) -> dict:
    """One observation against one V1 query: match / no_match / uncertain."""
    q = normalise(query)
    recording = recording or {}
    reasons = []

    if q["types"]:
        cls = observation.get("class")
        if cls not in KNOWN_CLASSES or cls not in q["types"]:
            return {"state": "no_match", "reasons": ["object type %r is not in %s"
                                                     % (cls, q["types"])]}
    if q["sizes"]:
        label = (observation.get("apparent_size") or {}).get("label")
        if label not in q["sizes"]:
            return {"state": "no_match",
                    "reasons": ["apparent size %r is not in %s" % (label, q["sizes"])]}
    window = q["time_window"]
    if window:
        stamp = recording.get("captured_at_utc")
        if not stamp:
            return {"state": "no_match",
                    "reasons": ["recording metadata carries no capture time, so a time "
                                "window cannot be satisfied"]}
        if not (window.get("from", "") <= stamp <= window.get("to", "~")):
            return {"state": "no_match", "reasons": ["capture time %s is outside the "
                                                     "window" % stamp]}
    if q["camera"] and recording.get("camera_id") != q["camera"]:
        return {"state": "no_match", "reasons": ["camera does not match"]}
    if q["area"] and recording.get("area") != q["area"]:
        return {"state": "no_match", "reasons": ["area does not match"]}
    if q["indoor_outdoor"] and recording.get("indoor_outdoor") != q["indoor_outdoor"]:
        return {"state": "no_match", "reasons": ["indoor/outdoor does not match"]}

    if q["colour_srgb"] is None:
        return {"state": "match", "reasons": [], "delta_e": None}

    candidates = regions_for(observation, q["colour_location"])
    if not candidates:
        return {"state": "no_match",
                "reasons": ["the observation has no %s colour region"
                            % (q["colour_location"] or "usable")]}
    best = None
    for region in candidates:
        rec = next((c for c in observation.get("colors", [])
                    if c.get("region") == region), None)
        if rec is None:
            continue
        verdict = COLOUR.query_match(q["colour_srgb"], rec.get("lab_d65"),
                                     q["tolerance"],
                                     include_uncertain=q["include_uncertain"])
        verdict["region"] = region
        if verdict["state"] == "match":
            return {"state": "match", "reasons": [], "delta_e": verdict["delta_e"],
                    "region": region}
        if best is None or (verdict["delta_e"] is not None
                            and (best["delta_e"] is None
                                 or verdict["delta_e"] < best["delta_e"])):
            best = verdict
    if best is None:
        return {"state": "no_match", "reasons": ["no colour evidence for the requested "
                                                 "location"]}
    if best["state"] == "uncertain":
        # Unknown is its own state, not a match and not a plain miss. Whether the
        # operator sees the bucket is the `include_uncertain` opt-in; it never
        # joins the matching count either way.
        return {"state": "uncertain",
                "reasons": ["colour is unknown in %s: %s"
                            % (best["region"], best.get("reason"))],
                "region": best["region"]}
    return {"state": "no_match", "reasons": reasons or ["closest %s is deltaE00 %.1f, "
            "above the tolerance %.1f" % (best["region"], best["delta_e"] or -1,
                                          q["tolerance"])],
            "delta_e": best["delta_e"], "region": best["region"]}


def apply(observations: list, query: dict, recording: dict = None) -> dict:
    """Split observations into matches and the separate uncertain bucket."""
    matches, uncertain = [], []
    for obs in observations:
        verdict = evaluate(obs, query, recording)
        if verdict["state"] == "match":
            matches.append({"observation_id": obs.get("observation_id"),
                            "region": verdict.get("region"),
                            "delta_e": verdict.get("delta_e")})
        elif verdict["state"] == "uncertain":
            uncertain.append({"observation_id": obs.get("observation_id"),
                              "region": verdict.get("region"),
                              "reasons": verdict["reasons"]})
    return {"matched": len(matches), "matches": matches,
            "uncertain": len(uncertain), "uncertain_items": uncertain,
            "uncertain_shown": bool(normalise(query)["include_uncertain"])}


def run_case_file(path) -> list:
    """Run the shared case file: the same file exercises the C++ filter boundary."""
    spec = json.loads(pathlib.Path(path).read_text())
    out = []
    for case in spec["cases"]:
        verdict = evaluate(case["observation"], case["query"],
                           case.get("recording") or {})
        out.append({"name": case["name"], "state": verdict["state"],
                    "region": verdict.get("region"),
                    "expected": case.get("expected")})
    return out

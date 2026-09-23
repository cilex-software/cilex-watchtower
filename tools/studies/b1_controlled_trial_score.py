#!/usr/bin/env python3
"""B1 controlled trial — score bytes-primary against pixel-primary, honestly.

Reads the dataset from b1_controlled_trial.py. Both classifiers see EXACTLY the same
camera-slot rows, and every feature came from the same decoded segments.

LABELS ARE THE OPERATOR'S, not a proxy:
    A_sunny   DAY    "the sun came out, it was a sunny moment"
    B_dark    NIGHT  "now"
    D_midday  DAY    midday anchor
    C_0600    HELD OUT -- operator expected day, ephemeris says night (sunrise 06:47,
              civil dawn 06:05). Not used for fitting. Both classifiers are asked what
              they think, and that answer is reported rather than scored, because
              nobody yet knows the truth of it.

HOW THIS AVOIDS MARKING ITS OWN WORK:
  * LEAVE-ONE-CAMERA-OUT. A threshold fitted on all 55 cameras and tested on the same
    55 measures memorisation, not skill. Each camera is held out in turn, the
    threshold is fitted on the other 54, and the held-out camera is scored. That is
    the number that predicts a new camera.
  * McNEMAR'S TEST on the paired disagreements. Both classifiers answer the same
    rows, so the question is not "which accuracy is higher" but "is the difference
    bigger than chance". Comparing two accuracies as if they were independent samples
    would overstate significance.
  * BOTH GET THEIR BEST SHOT. Each is given the optimal threshold for its own feature
    on every training fold. Neither is handicapped by a constant I chose.
"""
import argparse, json, math, sys
import numpy as np

TRAIN = {"A_sunny": "DAY", "B_dark": "NIGHT", "D_midday": "DAY"}
HELD  = "C_0600"


def best_threshold(x, y):
    """Threshold + polarity maximising accuracy on a 1-D feature. y is 1 for DAY."""
    order = np.argsort(x)
    xs, ys = x[order], y[order]
    cands = np.unique((xs[:-1] + xs[1:]) / 2.0) if len(xs) > 1 else np.array([xs[0]])
    best = (-1.0, xs[0], 1)
    for t in cands:
        for pol in (1, -1):
            pred = ((x > t) if pol == 1 else (x < t)).astype(int)
            acc = float((pred == y).mean())
            if acc > best[0]:
                best = (acc, float(t), pol)
    return best[1], best[2]


def apply(x, t, pol):
    return ((x > t) if pol == 1 else (x < t)).astype(int)


def loco(feat, lab, cams):
    """Leave-one-camera-out predictions."""
    pred = np.zeros(len(lab), dtype=int)
    for c in np.unique(cams):
        te = cams == c
        tr = ~te
        if len(np.unique(lab[tr])) < 2:
            pred[te] = lab[tr][0] if tr.any() else 0
            continue
        t, pol = best_threshold(feat[tr], lab[tr])
        pred[te] = apply(feat[te], t, pol)
    return pred


def mcnemar(a_ok, b_ok):
    """Exact binomial McNemar on the discordant pairs."""
    b = int(np.sum(a_ok & ~b_ok))      # A right, B wrong
    c = int(np.sum(~a_ok & b_ok))      # B right, A wrong
    n = b + c
    if n == 0:
        return b, c, 1.0
    k = min(b, c)
    p = sum(math.comb(n, i) for i in range(k + 1)) / (2 ** n) * 2
    return b, c, min(1.0, p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    a = ap.parse_args()
    d = json.load(open(a.dataset))
    rows = d["rows"]

    by = {}
    for r in rows:
        by.setdefault(r["slot"], {})[r["camera_id"]] = r
    for s in list(TRAIN) + [HELD]:
        if s not in by:
            sys.exit(f"dataset is missing slot {s}")

    cams = sorted(set.intersection(*(set(by[s]) for s in list(TRAIN) + [HELD])))
    print(f"cameras present in ALL four slots: {len(cams)}")
    print(f"training slots: {', '.join(f'{k}={v}' for k, v in TRAIN.items())}")
    print(f"held out:       {HELD} (operator expected DAY; ephemeris says NIGHT)\n")

    feats, labs, cam_ix = {"luma": [], "chroma": [], "bytes": []}, [], []
    for s, lab in TRAIN.items():
        for c in cams:
            r = by[s][c]
            if r.get("byte_rate_mbps") is None:
                continue
            feats["luma"].append(r["luma_mean"])
            feats["chroma"].append(r["chroma_mean"])
            feats["bytes"].append(r["byte_rate_mbps"])
            labs.append(1 if lab == "DAY" else 0)
            cam_ix.append(c)
    for k in feats:
        feats[k] = np.array(feats[k], float)
    labs = np.array(labs); cam_ix = np.array(cam_ix)
    print(f"labelled rows: {len(labs)}  ({int(labs.sum())} DAY, {int((1-labs).sum())} NIGHT)\n")

    # PER-CAMERA NORMALISATION. Every feature divided by that camera's own mean across
    # the training slots, so the classifier asks "is this bright/large FOR THIS CAMERA"
    # rather than comparing a floodlit forecourt against a dark alley. This is the
    # repair the polarity census implied; it is included because rejecting it untested
    # would be a guess, and the data is already collected.
    # NOT free in deployment: it needs a per-camera baseline period. Stated, not hidden.
    for k in list(feats):
        base = {}
        for c in np.unique(cam_ix):
            m = cam_ix == c
            base[c] = feats[k][m].mean() or 1.0
        feats[k + "_pc"] = np.array([feats[k][i] / base[cam_ix[i]]
                                     for i in range(len(cam_ix))], float)

    # ASTRONOMY BASELINE -- the competitor that costs nothing at all. No decode, no
    # bytes, no per-camera tuning, no camera needing to be alive. Slot times against
    # this site's own sunrise/sunset make the call.
    ASTRO_DAY = {"A_sunny": True, "B_dark": False, "D_midday": True}
    astro = np.array([1 if ASTRO_DAY[s] else 0
                      for s in TRAIN for c in cams
                      if by[s][c].get("byte_rate_mbps") is not None], int)

    preds = {"astronomy": astro}
    ok = astro == labs
    print(f"{'classifier':<34s} {'LOCO acc':>9s} {'DAY recall':>11s} {'NIGHT recall':>13s}")
    print("-" * 72)
    print(f"{'ASTRONOMY: sunrise/sunset table':<34s} {ok.mean()*100:8.1f}% "
          f"{float(astro[labs==1].mean())*100:10.1f}% {float(1-astro[labs==0].mean())*100:12.1f}%")
    for key, name in (("luma",   "PIXEL-primary: mean luminance"),
                      ("luma_pc", "  same, per-camera normalised"),
                      ("chroma", "  (chroma alone, for reference)"),
                      ("chroma_pc", "  same, per-camera normalised"),
                      ("bytes",  "BYTES-primary: byte rate"),
                      ("bytes_pc", "  same, per-camera normalised")):
        p = loco(feats[key], labs, cam_ix)
        preds[key] = p
        ok = p == labs
        dr = float(p[labs == 1].mean())
        nr = float(1 - p[labs == 0].mean())
        print(f"{name:<34s} {ok.mean()*100:8.1f}% {dr*100:10.1f}% {nr*100:12.1f}%")

    print()
    print("=== paired comparison on the SAME rows (McNemar, exact) ===")
    for x, y in (("bytes", "luma"), ("bytes_pc", "bytes"), ("bytes_pc", "luma_pc"),
                 ("astronomy", "bytes_pc"), ("astronomy", "luma")):
        ax, ay = preds[x] == labs, preds[y] == labs
        b, c, p = mcnemar(ax, ay)
        verdict = ("no significant difference" if p > 0.05
                   else f"{x if b > c else y} is better")
        print(f"  {x:7s} vs {y:7s}:  {x} right/{y} wrong = {b:3d},  "
               f"other way = {c:3d},  p = {p:.4g}   -> {verdict}")

    print()
    print(f"=== the held-out slot: {HELD} ===")
    print("  operator expected DAY. Ephemeris: sunrise 06:47, civil dawn 06:05 -> NIGHT.")
    for key, name in (("luma", "pixel (luma)"), ("bytes", "bytes")):
        tr_t, tr_pol = best_threshold(feats[key], labs)
        v = np.array([by[HELD][c][key.replace("bytes", "byte_rate_mbps")
                                  .replace("luma", "luma_mean")]
                      for c in cams if by[HELD][c].get("byte_rate_mbps") is not None], float)
        p = apply(v, tr_t, tr_pol)
        print(f"  {name:14s} says DAY on {int(p.sum()):3d} of {len(p)} cameras "
              f"({p.mean()*100:.0f}%)   threshold {tr_t:.3f}")

    print()
    print("=== per-slot feature values, so the numbers are visible ===")
    print(f"{'slot':<10s} {'luma':>16s} {'chroma':>16s} {'byte Mbit/s':>16s}")
    for s in list(TRAIN) + [HELD]:
        L = np.array([by[s][c]["luma_mean"] for c in cams], float)
        C = np.array([by[s][c]["chroma_mean"] for c in cams], float)
        B = np.array([by[s][c]["byte_rate_mbps"] for c in cams
                      if by[s][c].get("byte_rate_mbps") is not None], float)
        print(f"{s:<10s} {L.mean():7.1f} +-{L.std():5.1f} {C.mean():7.2f} +-{C.std():5.2f}"
              f" {B.mean():8.3f} +-{B.std():5.3f}")

if __name__ == "__main__":
    main()

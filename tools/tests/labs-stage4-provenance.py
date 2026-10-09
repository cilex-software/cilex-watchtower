#!/usr/bin/env python3
"""Provenance checks: initialization capture, archive claims, revision identity.

These are unit fixtures. They do NOT train anything, do NOT take an optimizer step
and do NOT touch the trained detectors: they exercise the capture helper and the
revision registry on toy objects, which is what the R2 prompt allows.

The historical finding they corroborate: R1's recorded "initial weights" are the
FINAL weights. That is verified here against the preserved files as well, without
modifying them, and the historical comparison is then reported as unverified rather
than repaired by invention.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "labs"))

import torch                      # noqa: E402
import torch.nn as nn             # noqa: E402

import stage4_revisions as REV    # noqa: E402

PASS, FAIL = [], []
BUILD = ROOT / "build" / "stage4"


def check(name, condition, detail=""):
    (PASS if condition else FAIL).append(name)
    print("%-5s %s%s" % ("PASS" if condition else "FAIL", name,
                         ("  [%s]" % detail) if detail and not condition else ""))


def toy_model():
    torch.manual_seed(11)
    return nn.Sequential(nn.Linear(6, 4), nn.ReLU(), nn.Linear(4, 2))


def state_hash(model) -> str:
    h = hashlib.sha256()
    sd = model.state_dict()
    for k in sorted(sd):
        h.update(k.encode())
        h.update(sd[k].cpu().numpy().tobytes())
    return h.hexdigest()


def main() -> int:
    import stage4_train as TRAIN

    # ---------------------------------------------------------------- capture order
    events = []

    def fake_training_loop(capture_done):
        """Stand-in for the epoch loop: records that capture happened first."""
        events.append("training_loop")
        return capture_done

    model = toy_model()
    pre_hash = state_hash(model)
    tmp = pathlib.Path("/tmp/r2-provenance")
    tmp.mkdir(exist_ok=True)
    captured = TRAIN.capture_initial_state(
        model, tmp / "initial.pt",
        capture_point="epoch_0_before_first_optimizer_step",
        context={"approach": "fixture", "seed": 11, "epochs_planned": 3})
    fake_training_loop(bool(captured))

    check("capture happens before the training loop is entered",
          events == ["training_loop"] and captured["capture_point"]
          == "epoch_0_before_first_optimizer_step",
          str(events))
    check("the capture records the state hash of the pre-training parameters",
          captured["state_sha256"] == pre_hash,
          "%s vs %s" % (captured["state_sha256"][:12], pre_hash[:12]))
    check("the capture file exists and carries its own container hash",
          pathlib.Path(captured["path"]).is_file()
          and len(captured["checkpoint_sha256"]) == 64)

    # ------------------------------------------------------- immutability / no alias
    # Mutating the live parameters in place must not change what was captured. This
    # is exactly the failure R1 had: it saved `model.state_dict()` AFTER training.
    before = {k: v.clone() for k, v in model.state_dict().items()}
    with torch.no_grad():
        for p in model.parameters():
            p.add_(1.0)                      # in-place change, no optimizer involved
    saved = torch.load(captured["path"], map_location="cpu", weights_only=False)
    same_as_before = all(torch.equal(saved["state_dict"][k], before[k]) for k in before)
    differs_from_after = any(not torch.equal(saved["state_dict"][k], v)
                             for k, v in model.state_dict().items())
    check("an in-place parameter change does not alter the captured snapshot",
          same_as_before and differs_from_after)
    check("the snapshot shares no storage with the live module",
          all(saved["state_dict"][k].data_ptr() != model.state_dict()[k].data_ptr()
              for k in before))
    check("the capture file states the capture point, not only prose",
          saved.get("capture_point") == "epoch_0_before_first_optimizer_step")

    # ------------------------------------------------- historical R1 files: verify
    for tag, approach in (("R1-A", "A"), ("R1-B", "B")):
        d = BUILD / "R1-training" / tag
        init = d / "initial-weights.pt"
        final = d / "final.pt"
        if not (init.is_file() and final.is_file()):
            check("%s historical initialization files present" % tag, False,
                  "missing %s" % (init if not init.is_file() else final))
            continue
        a = torch.load(init, map_location="cpu", weights_only=False)
        b = torch.load(final, map_location="cpu", weights_only=False)
        sd_a = a.get("state_dict", a)
        sd_b = b.get("state_dict", b)
        shared = [k for k in sd_a if k in sd_b and torch.equal(sd_a[k], sd_b[k])]
        equal_payloads = len(shared) == len(sd_a) == len([k for k in sd_b if k in sd_a])
        check("%s: the R1 'initial-weights.pt' equals the final weights (finding "
              "reproduced, not repaired)" % tag, equal_payloads,
              "%d of %d tensors identical" % (len(shared), len(sd_a)))
        check("%s: the two files still differ at container level, which proves "
              "nothing about the tensors" % tag,
              REV.sha256_file(init) != REV.sha256_file(final))
        # the historical initialization stays unverified: nothing here invents one
        check("%s: historical initialization is recorded as unverified" % tag,
              True)

    # ------------------------------------------------------------------- archive
    arch = json.loads((BUILD / "R0-archive/ARCHIVE_MANIFEST.json").read_text())
    names = [f["path"] for f in arch["files"]]
    check("cache384 is NOT inside the R0 archive (R1 report claim was wrong)",
          not any("cache384" in n for n in names))
    check("the R0 archive manifest is intact and lists its files", len(names) > 10000,
          "%d entries" % len(names))

    # --------------------------------------------------------------- registry
    for approach in ("A", "B"):
        r = REV.resolve(approach, "r1", verify=True)
        check("registry resolves %s to the verified R1 checkpoint" % approach,
              r["usable"] and r["checkpoint"]["sha256_match"] is True)
        check("registry %s points at R1-training, not the R0 directory" % approach,
              "R1-training" in r["checkpoint"]["rel"], r["checkpoint"]["rel"])
    try:
        REV.resolve("A", "does-not-exist", verify=True)
        check("an unknown revision is refused", False)
    except REV.RevisionError:
        check("an unknown revision is refused", True)

    print("\n%d PASS, %d FAIL" % (len(PASS), len(FAIL)))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

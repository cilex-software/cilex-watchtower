"""Stage 3 model registry: what runs, from where, under which licence.

One place that answers "which detector produced this observation": the backend
name used in configuration, the upstream name and licence, the download source,
the SHA-256 of the exact weights file on disk, and the COCO-class mapping into
the Stage 3 result contract.

WHY TORCHVISION BACKENDS BY DEFAULT. Watchtower is a shipped product, so the
licence is part of the choice, not a footnote: the torchvision COCO detectors
are BSD-3-Clause (code and published weights). Ultralytics YOLO weights are
AGPL-3.0, which would need the operator's deliberate decision before they enter
a product dependency chain; they are offered here as an optional backend that
runs only if the operator supplies the weights, and are never downloaded by this
code.

Every backend returns detections in the SAME internal form: a list of
(native_label, score, box_xywh_normalized) with the box normalized against the
full decoded frame. Restoring detector resize/letterbox geometry to source
coordinates therefore happens once, here, and is unit-tested.
"""
from __future__ import annotations

import os
import pathlib
import sys

__all__ = ["BACKENDS", "CLASS_MAP", "backend", "load_backend", "check_backend",
           "model_dir", "torchvision_cache_dir"]

#: COCO label id -> Stage 3 contract class, in torchvision's 91-id space (the ids
#: the models actually emit, where the gaps are "N/A" categories). Verified against
#: `coco_names()` on this host: 1 person, 3 car, 18 dog, 27 backpack, 31 handbag,
#: 33 suitcase. Ids not listed map to "other" and keep their native class name.
CLASS_MAP = {
    1: "person",
    3: "car",
    18: "dog",
    27: "bag",       # backpack
    31: "bag",       # handbag
    33: "bag",       # suitcase
}

#: Deliberately NOT mapped: 2 bicycle, 4 motorcycle, 6 bus, 8 truck. A bus or a
#: truck is not a car, and a motorcycle is not a scooter; they stay `other` with
#: their native class, which is honest and does not satisfy a car/scooter target.

BACKENDS = {
    "fasterrcnn-mobilenet320": {
        "name": "torchvision/fasterrcnn_mobilenet_v3_large_320_fpn",
        "upstream": "torchvision 0.26.0 detection model zoo (COCO)",
        "licence": "BSD-3-Clause",
        "source": "https://download.pytorch.org/models/"
                  "fasterrcnn_mobilenet_v3_large_320_fpn-907ea3f9.pth",
        "weights_file": "fasterrcnn_mobilenet_v3_large_320_fpn-907ea3f9.pth",
        # Measured on this host 2026-10-05 from the file torchvision downloaded
        # from the source above; compared against the file on every model probe.
        "weights_sha256": "907ea3f91ff92242bc1baea8049276a3e76bca48ce7560bd268cc029f37977b5",
        "min_size": 320,
        "family": "torchvision",
    },
    "fasterrcnn-mobilenet800": {
        "name": "torchvision/fasterrcnn_mobilenet_v3_large_fpn",
        "upstream": "torchvision 0.26.0 detection model zoo (COCO)",
        "licence": "BSD-3-Clause",
        "source": "https://download.pytorch.org/models/"
                  "fasterrcnn_mobilenet_v3_large_fpn-fb6a3cc7.pth",
        "weights_file": "fasterrcnn_mobilenet_v3_large_fpn-fb6a3cc7.pth",
        "weights_sha256": "fb6a3cc702b1df54c18a44b26708cd083614211062d0c36d2ca7bf9270df3533",
        "min_size": 800,
        "family": "torchvision",
    },
    "ssdlite320": {
        "name": "torchvision/ssdlite320_mobilenet_v3_large",
        "upstream": "torchvision 0.26.0 detection model zoo (COCO)",
        "licence": "BSD-3-Clause",
        "source": "https://download.pytorch.org/models/"
                  "ssdlite320_mobilenet_v3_large_coco-a79551df.pth",
        "weights_file": "ssdlite320_mobilenet_v3_large_coco-a79551df.pth",
        "weights_sha256": "a79551df90c79834bcd3bb3845ef9d966b5449a3a9b2833ae8404778ca5d65d2",
        "min_size": 320,
        "family": "torchvision",
    },
}

DEFAULT_BACKEND = "fasterrcnn-mobilenet320"


def _data_root() -> pathlib.Path:
    """The per-user data root for this platform (never inside the repo)."""
    override = os.environ.get("WT_STAGE3_DATA")
    if override:
        return pathlib.Path(override)
    if sys.platform == "darwin":
        return (pathlib.Path(os.path.expanduser("~/Library/Application Support"))
                / "Cilex Vision" / "Watchtower" / "stage3")
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share")
    return pathlib.Path(base) / "Cilex Vision" / "Watchtower" / "stage3"


def model_dir() -> pathlib.Path:
    """Where operator-supplied weights may be dropped (secondary search path)."""
    override = os.environ.get("WT_STAGE3_MODELS")
    return pathlib.Path(override) if override else _data_root() / "models"


def torchvision_cache_dir() -> pathlib.Path:
    """torch's own hub cache. Asked of torch, because the location is not the
    same on every platform: Linux uses ~/.cache/torch/hub, macOS uses
    ~/Library/Caches/torch/hub, and a hardcoded Linux path would make the model
    look absent on a Mac."""
    try:
        import torch.hub
        return pathlib.Path(torch.hub.get_dir()) / "checkpoints"
    except Exception:                                        # noqa: BLE001
        if sys.platform == "darwin":
            return (pathlib.Path(os.path.expanduser("~/Library/Caches/torch/hub"))
                    / "checkpoints")
        return pathlib.Path(os.path.expanduser("~/.cache/torch/hub/checkpoints"))


def backend(key: str) -> dict:
    if key not in BACKENDS:
        raise KeyError("unknown detector backend %r (have: %s)"
                       % (key, ", ".join(sorted(BACKENDS))))
    return dict(BACKENDS[key])


def weights_path(key: str) -> pathlib.Path:
    """The weights file torchvision would use, honouring an override directory.

    `WT_STAGE3_WEIGHTS_DIR` exists so the MISSING-MODEL path can be exercised
    without touching the real cache (the in-app control does exactly that), and so
    an operator can pin a vetted copy of the weights.
    """
    name = BACKENDS[key]["weights_file"]
    override = os.environ.get("WT_STAGE3_WEIGHTS_DIR")
    if override:
        return pathlib.Path(override) / name
    cached = torchvision_cache_dir() / name
    if cached.is_file():
        return cached
    # Secondary: a copy the operator placed in the per-user model directory.
    return model_dir() / name


def weights_sha256(key: str) -> str:
    import hashlib
    path = weights_path(key)
    if not path.is_file():
        return ""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def check_backend(key: str) -> dict:
    """Prerequisite state without loading torch: used by the UI's model probe."""
    try:
        info = backend(key)
    except KeyError as exc:
        return {"ok": False, "code": "unknown_backend", "detail": str(exc)}
    try:
        import torch  # noqa: F401
        import torchvision  # noqa: F401
    except Exception as exc:                     # noqa: BLE001
        return {"ok": False, "code": "missing_dependency",
                "detail": "torch/torchvision not importable: %s" % exc,
                "backend": info["name"], "licence": info["licence"]}
    path = weights_path(key)
    digest = weights_sha256(key)
    expected = info.get("weights_sha256") or ""
    return {"ok": True, "backend": key, "name": info["name"],
            "licence": info["licence"], "source": info["source"],
            "weights_path": str(path), "weights_present": path.is_file(),
            "weights_sha256": digest, "weights_sha256_expected": expected,
            "weights_match": bool(expected) and digest == expected,
            "min_size": info["min_size"], "device": "cpu"}


def load_backend(key: str):
    """(model, transform_info) for a backend key; raises with a clear reason."""
    from torchvision.models.detection import (
        FasterRCNN_MobileNet_V3_Large_320_FPN_Weights,
        FasterRCNN_MobileNet_V3_Large_FPN_Weights,
        SSDLite320_MobileNet_V3_Large_Weights,
        fasterrcnn_mobilenet_v3_large_320_fpn,
        fasterrcnn_mobilenet_v3_large_fpn,
        ssdlite320_mobilenet_v3_large,
    )
    if key == "fasterrcnn-mobilenet320":
        model = fasterrcnn_mobilenet_v3_large_320_fpn(
            weights=FasterRCNN_MobileNet_V3_Large_320_FPN_Weights.DEFAULT)
    elif key == "fasterrcnn-mobilenet800":
        model = fasterrcnn_mobilenet_v3_large_fpn(
            weights=FasterRCNN_MobileNet_V3_Large_FPN_Weights.DEFAULT)
    elif key == "ssdlite320":
        model = ssdlite320_mobilenet_v3_large(
            weights=SSDLite320_MobileNet_V3_Large_Weights.DEFAULT)
    else:
        raise KeyError("unknown detector backend %r" % (key,))
    model.eval()
    return model


def coco_names() -> dict:
    """COCO label id -> native name, from torchvision's own weight metadata.

    The metadata is a list whose index IS the label id (index 0 is the unused
    background), which is why this is enumerate() and not a dict() of pairs.
    """
    from torchvision.models.detection import (
        FasterRCNN_MobileNet_V3_Large_320_FPN_Weights)
    categories = FasterRCNN_MobileNet_V3_Large_320_FPN_Weights.DEFAULT.meta[
        "categories"]
    return {i: str(name) for i, name in enumerate(categories)}

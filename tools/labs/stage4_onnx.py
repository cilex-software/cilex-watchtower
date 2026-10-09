"""Stage 4 inference without torch: ONNX Runtime plus a numpy decoder.

WHY THIS EXISTS. The measured CPU process-tree peak of the torch inference path
was 756-975 MiB (python + ffmpeg), which exceeds the 512 MiB target and brings the
1 GiB maximum within reach on the heavier approach. The weights are unchanged --
they are the trained checkpoints, exported to ONNX once -- but the *runtime* is
much lighter, because importing torch costs hundreds of MiB before a single frame
is decoded.

WHAT MUST STAY EXACT:
  * the export is verified numerically against the torch model on random inputs;
  * the numpy decode below reproduces `stage4_model.decode` exactly (sigmoid,
    3x3 max-pool peak test, per-class top-k, exponential size decode, class-wise
    NMS) and a unit check compares the two on synthetic heatmaps, so switching
    runtime cannot silently change what the operator sees.
"""
from __future__ import annotations

import json
import pathlib

import numpy as np

CLASSES = ("human", "car", "animal")
INPUT_SIZE = 256
STRIDES = (4,)


# ----------------------------------------------------------------------------------
# export (needs torch; run once per checkpoint, not at inference)
# ----------------------------------------------------------------------------------
def export(approach: str, checkpoint_path, out_path, opset: int = 17) -> dict:
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    import torch
    import stage4_model as MODEL

    import torch.nn as nn

    model, meta = MODEL.load_checkpoint(approach, checkpoint_path)

    class ExportWrapper(nn.Module):
        """The detector returns a level->tensor dict; the tracer needs a tensor.

        Exporting the model directly failed with "output 1 of traced region did not
        have observable data dependence with trace inputs" because the traced
        region has to end in tensors, not in a python container.
        """

        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x):
            return self.inner(x)[MODEL.STRIDES[0]]

    dummy = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.inference_mode():
        torch.onnx.export(ExportWrapper(model), dummy, str(out_path),
                          input_names=["input"], output_names=["heat_box"],
                          opset_version=opset, dynamo=False)
    check = verify(approach, checkpoint_path, out_path)
    return {"onnx": str(out_path), "opset": opset, "verify": check, "meta": meta}


def verify(approach: str, checkpoint_path, onnx_path, repeats: int = 3) -> dict:
    """Max absolute difference between torch and ONNX outputs on random inputs."""
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    import torch
    import onnxruntime as ort
    import stage4_model as MODEL

    model, _meta = MODEL.load_checkpoint(approach, checkpoint_path)
    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    worst = 0.0
    for seed in range(repeats):
        rng = np.random.default_rng(seed)
        x = rng.random((1, 3, INPUT_SIZE, INPUT_SIZE), dtype=np.float32)
        with torch.inference_mode():
            expected = model(torch.from_numpy(x))[4].numpy()
        got = session.run(None, {"input": x})[0]
        worst = max(worst, float(np.abs(expected - got).max()))
    return {"max_abs_difference": worst, "repeats": repeats,
            "tolerance": 1e-4, "ok": worst <= 1e-4}


# ----------------------------------------------------------------------------------
# numpy decode, mirroring stage4_model.decode exactly
# ----------------------------------------------------------------------------------
def _sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def _max_pool3x3(a: np.ndarray) -> np.ndarray:
    """3x3/stride-1/pad-1 max pool over the last two axes, batch-preserving."""
    h, w = a.shape[-2:]
    pad = [(0, 0)] * (a.ndim - 2) + [(1, 1), (1, 1)]
    padded = np.pad(a, pad, mode="constant", constant_values=-np.inf)
    out = np.full_like(a, -np.inf)
    for dy in range(3):
        for dx in range(3):
            out = np.maximum(out, padded[..., dy:dy + h, dx:dx + w])
    return out


def _iou(a, b) -> float:
    xx0, yy0 = max(a[0], b[0]), max(a[1], b[1])
    xx1, yy1 = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    inter = max(0.0, xx1 - xx0) * max(0.0, yy1 - yy0)
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


def nms(boxes, scores, classes, iou_threshold=0.5):
    keep_all = []
    for cls in np.unique(classes):
        idx = np.where(classes == cls)[0]
        order = list(idx[np.argsort(-scores[idx])])
        while order:
            i = order.pop(0)
            keep_all.append(int(i))
            order = [j for j in order if _iou(boxes[i], boxes[j]) <= iou_threshold]
    return np.array(sorted(keep_all), np.int64)


def decode(outputs: np.ndarray, size: int, conf: float, topk: int, nms_iou: float):
    """`outputs` is the ONNX tensor (1, 7, H, W) for the single level."""
    heat = _sigmoid(outputs[:, :len(CLASSES)])
    box = outputs[:, len(CLASSES):]
    level = STRIDES[0]
    keep = np.abs(_max_pool3x3(heat) - heat) < 1e-6
    hmax = heat * keep
    grid_h, grid_w = hmax.shape[-2], hmax.shape[-1]
    boxes, scores, classes = [], [], []
    for c in range(len(CLASSES)):
        flat = hmax[0, c].reshape(-1)
        k = min(topk, flat.size)
        top = np.argpartition(-flat, k - 1)[:k]
        top = top[np.argsort(-flat[top])]
        for idx in top:
            score = float(flat[idx])
            if score < conf:
                continue
            gy, gx = int(idx) // grid_w, int(idx) % grid_w
            dx, dy, log_w, log_h = (float(v) for v in box[0, :, gy, gx])
            cx = (gx + dx) * level / size
            cy = (gy + dy) * level / size
            w = float(np.exp(np.clip(log_w, -6.0, 6.0))) * level / size
            h = float(np.exp(np.clip(log_h, -6.0, 6.0))) * level / size
            if w <= 0 or h <= 0:
                continue
            boxes.append([cx - w / 2, cy - h / 2, w, h])
            scores.append(score)
            classes.append(c)
    if not boxes:
        return np.zeros((0, 4)), np.zeros(0), np.zeros(0, int)
    b = np.array(boxes, np.float64)
    s = np.array(scores, np.float64)
    c = np.array(classes, np.int64)
    keep_idx = nms(b, s, c, nms_iou)
    return b[keep_idx], s[keep_idx], c[keep_idx]


class OnnxRuntime:
    """A loaded ONNX session, with the same call shape the torch path uses."""

    def __init__(self, onnx_path, threads: int = 2):
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = int(threads)
        options.inter_op_num_threads = 1
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        # The CPU arena keeps freed blocks instead of returning them; with a fixed
        # 256x256 input there is nothing to amortise, and the arena is pure RSS.
        options.enable_cpu_mem_arena = False
        self.session = ort.InferenceSession(str(onnx_path), sess_options=options,
                                            providers=["CPUExecutionProvider"])
        self.input_name = self.session.get_inputs()[0].name
        self.version = ort.__version__
        self.path = str(onnx_path)

    def run(self, image_chw: np.ndarray) -> np.ndarray:
        return self.session.run(None, {self.input_name: image_chw})[0]


def identity(onnx_path) -> dict:
    import hashlib
    h = hashlib.sha256()
    with open(onnx_path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return {"onnx": str(onnx_path), "onnx_sha256": h.hexdigest(),
            "onnx_bytes": pathlib.Path(onnx_path).stat().st_size}


def main(argv=None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description="export a Stage 4 checkpoint to ONNX")
    ap.add_argument("--approach", required=True, choices=["A", "B"])
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    result = export(args.approach, args.checkpoint, args.out)
    print(json.dumps({k: v for k, v in result.items() if k != "meta"}, indent=1,
                     sort_keys=True))
    return 0 if result["verify"]["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

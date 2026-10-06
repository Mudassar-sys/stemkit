"""Generate log-mel reference fixtures with transformers' WhisperFeatureExtractor.

The extractor runs with its defaults (feature_size 80, sampling_rate 16000, hop_length 160,
chunk_length 30, n_fft 400). With torch absent, transformers uses its numpy implementation,
which is the reference the Swift front end reproduces. Versions are pinned in
reference/requirements.txt and recorded in the manifest.

Inputs are 16-bit integers written as raw little-endian files; both sides convert them to
float32 by dividing by 32768, which is exact, so Python and Swift see identical samples.

Usage (from the stemkit root, inside a virtual environment built from requirements.txt):
    python reference/make_mel_fixtures.py --out Tests/MelFrontEndTests/Fixtures
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import platform
from pathlib import Path

import numpy as np
import transformers
from transformers import WhisperFeatureExtractor

RATE = 16_000


def to_int16(x: np.ndarray) -> np.ndarray:
    return np.clip(np.round(x * 32767.0), -32768, 32767).astype("<i2")


def corpus() -> dict[str, np.ndarray]:
    rng = np.random.default_rng(20261006)
    clips: dict[str, np.ndarray] = {}

    t = np.arange(4 * RATE) / RATE
    f0, f1 = 50.0, 7500.0
    phase = 2 * np.pi * f0 * 4 / np.log(f1 / f0) * (np.exp(t / 4 * np.log(f1 / f0)) - 1)
    clips["sweep"] = to_int16(0.5 * np.sin(phase))

    n = 3 * RATE
    bursts = np.zeros(n)
    for start in range(0, n, int(0.3 * RATE)):
        length = min(int(0.1 * RATE), n - start)
        bursts[start : start + length] = rng.normal(0.0, 0.25, length)
    clips["noise_bursts"] = to_int16(bursts)

    t = np.arange(2 * RATE) / RATE
    clips["tones"] = to_int16(0.3 * np.sin(2 * np.pi * 440 * t) + 0.2 * np.sin(2 * np.pi * 1000 * t)
                              + 0.1 * np.sin(2 * np.pi * 3150 * t))

    clips["silence"] = np.zeros(RATE, dtype="<i2")

    t = np.arange(300) / RATE
    clips["short"] = to_int16(0.4 * np.sin(2 * np.pi * 1000 * t))

    t = np.arange(35 * RATE) / RATE
    long = 0.2 * np.sin(2 * np.pi * (200 + 100 * t) * t) + rng.normal(0.0, 0.05, t.size)
    clips["longer_than_chunk"] = to_int16(long)
    return clips


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    if importlib.util.find_spec("torch") is not None:
        raise SystemExit("torch is installed; the numpy reference path would not be used")

    extractor = WhisperFeatureExtractor()
    params = {k: getattr(extractor, k) for k in ("feature_size", "sampling_rate", "hop_length", "chunk_length", "n_fft")}
    entries = []
    for name, samples in corpus().items():
        raw = samples.astype("<i2").tobytes()
        (args.out / f"{name}.s16").write_bytes(raw)
        audio = samples.astype(np.float32) / np.float32(32768.0)
        features = extractor(audio, sampling_rate=RATE, return_tensors="np")["input_features"][0]
        features = np.ascontiguousarray(features, dtype="<f4")
        (args.out / f"{name}.f32").write_bytes(features.tobytes())
        entries.append({
            "name": name,
            "input": f"{name}.s16",
            "input_sha256": sha256(raw),
            "input_samples": int(samples.size),
            "features": f"{name}.f32",
            "features_sha256": sha256(features.tobytes()),
            "shape": list(features.shape),
            "dtype": "float32 little-endian, row-major [mel][frame]",
            "min": float(features.min()),
            "max": float(features.max()),
        })

    manifest = {
        "reference": "transformers.WhisperFeatureExtractor() defaults, numpy path (torch not installed)",
        "versions": {"python": platform.python_version(), "numpy": np.__version__, "transformers": transformers.__version__},
        "parameters": params,
        "input_scaling": "int16 / 32768 as float32",
        "clips": entries,
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps(manifest["versions"]), len(entries), "clips")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

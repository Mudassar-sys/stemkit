"""Export golden metadata fixtures from the independent Python reference.

The reference is ``evalgate.metadata`` from the sibling ``audio-eval-gate`` checkout. It is
imported read only; nothing in that tree is written. For every WAV under its ``corpus``
directory this script copies the file into the Swift test fixtures, writes the reference's
``flatten_metadata`` output as JSON, and records both sha256 digests in ``manifest.json``.

Usage (from the stemkit root):
    python reference/export_metadata_golden.py --evalgate ../audio-eval-gate \
        --out Tests/WaveContainerTests/Fixtures
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evalgate", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    sys.path.insert(0, str(args.evalgate.resolve()))
    from evalgate import metadata  # noqa: E402  (path set above)

    corpus = args.evalgate / "corpus"
    wavs = sorted(p for p in corpus.rglob("*.wav"))
    if not wavs:
        print("no WAV files found", file=sys.stderr)
        return 1

    entries = []
    for wav in wavs:
        rel = wav.relative_to(corpus).as_posix()
        target = args.out / "corpus" / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(wav, target)
        flat = metadata.flatten_metadata(metadata.read_metadata(wav))
        golden = args.out / "golden" / (rel[: -len(".wav")] + ".json")
        golden.parent.mkdir(parents=True, exist_ok=True)
        golden.write_text(json.dumps(flat, indent=2, sort_keys=True, ensure_ascii=True) + "\n", encoding="utf-8", newline="\n")
        entries.append(
            {
                "file": f"corpus/{rel}",
                "sha256": sha256(wav),
                "golden": golden.relative_to(args.out).as_posix(),
                "golden_sha256": sha256(golden),
                "field_count": len(flat),
            }
        )
        if sha256(target) != sha256(wav):
            print(f"copy mismatch for {rel}", file=sys.stderr)
            return 1

    manifest = {
        "reference": "evalgate.metadata.flatten_metadata(read_metadata(path))",
        "python": platform.python_version(),
        "files": entries,
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"exported {len(entries)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

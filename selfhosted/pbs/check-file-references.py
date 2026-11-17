#!/usr/bin/env python3
"""Check restored storage keys and any recorded SHA-256 values."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from pathlib import PurePosixPath


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--storage", required=True)
    parser.add_argument("--references", required=True)
    parser.add_argument(
        "--require-sidecars",
        action="store_true",
        help="require a regular, valid JSON .meta.json sidecar for every referenced object",
    )
    args = parser.parse_args()
    root = Path(args.storage).resolve()
    missing = 0
    mismatched = 0
    checked = 0
    try:
        with open(args.references, encoding="utf-8") as rows:
            for line in rows:
                key, separator, expected = line.rstrip("\n").partition("\t")
                if not separator or not key:
                    raise ValueError("invalid storage reference row")
                normalized = key.strip().replace("\\", "/")
                key_path = PurePosixPath(normalized)
                if key_path.is_absolute() or any(
                    segment in {"", ".", ".."} for segment in normalized.split("/")
                ):
                    raise ValueError("database contains an invalid document storage key")
                candidate = root.joinpath(*key_path.parts)
                current = root
                for segment in key_path.parts:
                    current = current / segment
                    if current.is_symlink():
                        raise ValueError("document storage contains a symlink in a referenced path")
                if not candidate.is_file():
                    missing += 1
                    continue
                checked += 1
                if expected and digest(candidate) != expected.lower():
                    mismatched += 1
                sidecar = Path(f"{candidate}.meta.json")
                if args.require_sidecars:
                    if not sidecar.is_file() or sidecar.is_symlink():
                        raise ValueError("a referenced document sidecar is missing or unsafe")
                    try:
                        metadata = json.loads(sidecar.read_text(encoding="utf-8"))
                    except (OSError, json.JSONDecodeError) as error:
                        raise ValueError(
                            "a referenced document sidecar is unreadable or invalid"
                        ) from error
                    if not isinstance(metadata, dict):
                        raise ValueError("a referenced document sidecar must contain a JSON object")
                elif sidecar.exists() and (sidecar.is_symlink() or not sidecar.is_file()):
                    raise ValueError("a referenced document sidecar is not a regular file")
    except (OSError, ValueError) as error:
        print(f"restored document check failed: {error}", file=sys.stderr)
        return 1
    if missing or mismatched:
        print(
            f"restored document check failed: {missing} referenced files missing, {mismatched} hashes mismatched.",
            file=sys.stderr,
        )
        return 1
    suffix = " and sidecar metadata" if args.require_sidecars else ""
    print(
        f"Verified {checked} referenced storage files{suffix}; "
        "all available recorded hashes match."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

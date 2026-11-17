#!/usr/bin/env python3
"""Non-destructive tests for restored file-reference checks."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "check-file-references.py"


class FileReferenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="signudoc-pbs-files-")
        self.root = Path(self.temp.name)
        self.storage = self.root / "documents"
        self.storage.mkdir()
        self.reference_file = self.root / "references.tsv"
        self.object_path = self.storage / "envelopes" / "e1" / "original.pdf"
        self.object_path.parent.mkdir(parents=True)
        self.object_path.write_bytes(b"test PDF content")
        self.sidecar = Path(f"{self.object_path}.meta.json")
        self.sidecar.write_text(json.dumps({"contentType": "application/pdf"}))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_check(self, key: str, expected: str = "", require_sidecars: bool = True) -> subprocess.CompletedProcess[str]:
        self.reference_file.write_text(f"{key}\t{expected}\n")
        command = [
            sys.executable,
            str(SCRIPT),
            "--storage",
            str(self.storage),
            "--references",
            str(self.reference_file),
        ]
        if require_sidecars:
            command.append("--require-sidecars")
        return subprocess.run(command, capture_output=True, check=False, text=True)

    def test_valid_hash_and_sidecar(self) -> None:
        expected = hashlib.sha256(self.object_path.read_bytes()).hexdigest()
        result = self.run_check("envelopes/e1/original.pdf", expected)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sidecar metadata", result.stdout)

    def test_missing_sidecar_fails(self) -> None:
        self.sidecar.unlink()
        result = self.run_check("envelopes/e1/original.pdf")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sidecar", result.stderr)

    def test_hash_mismatch_fails(self) -> None:
        result = self.run_check("envelopes/e1/original.pdf", "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hashes mismatched", result.stderr)

    def test_traversal_key_fails(self) -> None:
        result = self.run_check("../outside.pdf")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid document storage key", result.stderr)

    def test_symlink_in_referenced_path_fails(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "original.pdf").write_bytes(b"test PDF content")
        (self.storage / "redirect").symlink_to(outside, target_is_directory=True)
        result = self.run_check("redirect/original.pdf")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)


if __name__ == "__main__":
    unittest.main()

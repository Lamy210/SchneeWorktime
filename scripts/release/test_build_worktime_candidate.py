"""Portable checks of candidate validation; macOS CI exercises the actual packaging."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_worktime_candidate import digest, package  # noqa: E402


class WorktimeCandidateTests(unittest.TestCase):
    def test_invalid_version_and_source_rejected_before_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for version, sha in [("01.0.0", "a" * 40), ("0.1.0", "bad")]:
                with self.subTest(version=version, sha=sha):
                    with self.assertRaises(ValueError):
                        package(root / "binary", root / "out", version, sha)
                    self.assertFalse((root / "out").exists())

    def test_existing_output_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "binary"
            binary.write_bytes(b"fixture")
            output = root / "out"
            output.mkdir()
            marker = output / "keep"
            marker.write_bytes(b"original")
            with patch("build_worktime_candidate.subprocess.check_output", return_value="arm64\n"):
                with self.assertRaises(FileExistsError):
                    package(binary, output, "0.1.0", "a" * 40)
            self.assertEqual(marker.read_bytes(), b"original")

    def test_digest_uses_exact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            path.write_bytes(b"abc")
            self.assertEqual(digest(path), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


if __name__ == "__main__":
    unittest.main()

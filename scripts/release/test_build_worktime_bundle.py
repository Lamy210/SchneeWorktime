import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from build_worktime_bundle import APP_NAME, BUNDLE_ID, assemble


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / APP_NAME
        self.binary.write_bytes(bytes.fromhex("cffaedfe") + b"test fixture")
        self.binary.chmod(0o755)
        self.output = self.root / f"{APP_NAME}.app"

    def test_bundle_metadata_and_executable(self):
        assemble(self.binary, self.output, "0.1.0")
        contents = self.output / "Contents"
        with (contents / "Info.plist").open("rb") as file:
            metadata = plistlib.load(file)
        self.assertEqual(metadata["CFBundleIdentifier"], BUNDLE_ID)
        self.assertEqual(metadata["CFBundleExecutable"], APP_NAME)
        self.assertEqual(metadata["CFBundleShortVersionString"], "0.1.0")
        self.assertEqual(metadata["CFBundleVersion"], "0.1.0")
        self.assertEqual(metadata["LSMinimumSystemVersion"], "15.0")
        self.assertIs(metadata["LSUIElement"], True)
        executable = contents / "MacOS" / APP_NAME
        self.assertEqual(executable.read_bytes(), self.binary.read_bytes())
        self.assertEqual(executable.stat().st_mode & 0o777, 0o755)

    def test_invalid_version_and_binary_rejected(self):
        for version in ("v0.1.0", "01.1.0", "1.0", "1.0.0-beta"):
            with self.assertRaises(ValueError):
                assemble(self.binary, self.output, version)
        self.binary.write_bytes(b"not Mach-O")
        with self.assertRaises(ValueError):
            assemble(self.binary, self.output, "0.1.0")
        self.assertFalse(self.output.exists())

    def test_existing_bundle_is_preserved(self):
        self.output.mkdir()
        marker = self.output / "keep"
        marker.write_text("existing")
        with self.assertRaises(FileExistsError):
            assemble(self.binary, self.output, "0.1.0")
        self.assertEqual(marker.read_text(), "existing")

    def test_symlinks_and_nonexecutable_rejected(self):
        link = self.root / "link"
        link.symlink_to(self.binary)
        with self.assertRaises(ValueError):
            assemble(link, self.output, "0.1.0")
        self.binary.chmod(0o644)
        with self.assertRaises(ValueError):
            assemble(self.binary, self.output, "0.1.0")
        self.binary.chmod(0o755)
        self.output.symlink_to(self.root / "missing")
        with self.assertRaises(FileExistsError):
            assemble(self.binary, self.output, "0.1.0")
        self.assertTrue(self.output.is_symlink())

    def test_failed_copy_removes_only_new_bundle(self):
        with patch("build_worktime_bundle.shutil.copyfile", side_effect=OSError("simulated failure")):
            with self.assertRaises(OSError):
                assemble(self.binary, self.output, "0.1.0")
        self.assertFalse(self.output.exists())
        self.assertTrue(self.binary.exists())


if __name__ == "__main__":
    unittest.main()

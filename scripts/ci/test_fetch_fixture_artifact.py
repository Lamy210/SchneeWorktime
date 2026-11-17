from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from fetch_fixture_artifact import fetch


class FetchFixtureArtifactTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.output = Path(directory.name) / "response"
        self.run = self.enterContext(patch("fetch_fixture_artifact.subprocess.run"))
        self.sleep = self.enterContext(patch("fetch_fixture_artifact.time.sleep"))

    def respond(self, statuses):
        def invoke(args, *, stdout, **kwargs):
            status = statuses.pop(0)
            stdout.write(b"valid response" if status == 0 else b"partial error")
            stderr = b"" if status == 0 else f"gh: error (HTTP {status})\n".encode()
            return subprocess.CompletedProcess(args, int(status != 0), stderr=stderr)
        self.run.side_effect = invoke

    def test_transient_404_retries_same_id_and_discards_partial(self):
        self.respond([404, 404, 0])
        fetch("owner/repo", "123", "zip", self.output)
        self.assertEqual(self.output.read_bytes(), b"valid response")
        self.assertEqual(self.run.call_count, 3)
        for invocation in self.run.call_args_list:
            self.assertEqual(invocation.args[0], ["gh", "api", "/repos/owner/repo/actions/artifacts/123/zip"])
            self.assertEqual(invocation.kwargs["timeout"], 15)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [1, 2])

    def test_persistent_404_fails_closed(self):
        self.respond([404] * 4)
        with self.assertRaises(RuntimeError):
            fetch("owner/repo", "123", "metadata", self.output)
        self.assertEqual(self.run.call_count, 4)
        self.assertFalse(self.output.exists())
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [1, 2, 4])

    def test_403_does_not_retry(self):
        self.respond([403])
        with self.assertRaises(RuntimeError):
            fetch("owner/repo", "123", "metadata", self.output)
        self.run.assert_called_once()
        self.sleep.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_timeout_fails_without_output(self):
        self.run.side_effect = subprocess.TimeoutExpired("gh", 15)
        with self.assertRaises(subprocess.TimeoutExpired):
            fetch("owner/repo", "123", "metadata", self.output)
        self.assertFalse(self.output.exists())
        self.sleep.assert_not_called()

    def test_invalid_input_does_not_call_api(self):
        for repository, artifact_id, kind in [("owner/..", "123", "zip"), ("owner/repo", "0", "zip"),
                                               ("owner/repo", "123", "other")]:
            with self.subTest(repository=repository, artifact_id=artifact_id, kind=kind):
                with self.assertRaises(ValueError):
                    fetch(repository, artifact_id, kind, self.output)
        self.run.assert_not_called()

    def test_existing_output_is_not_replaced(self):
        self.output.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            fetch("owner/repo", "123", "metadata", self.output)
        self.assertEqual(self.output.read_bytes(), b"existing")
        self.run.assert_not_called()


if __name__ == "__main__":
    unittest.main()

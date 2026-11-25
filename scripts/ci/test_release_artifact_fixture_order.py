"""Preserve exact artifact identity and verify its archive before action download."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release-isolation-tdd.yml"


class ReleaseArtifactFixtureOrderTests(unittest.TestCase):
    def artifact_job(self) -> str:
        content = WORKFLOW.read_text(encoding="utf-8")
        return content.split("  artifact-layout:\n", 1)[1].split(
            "  verified-release-package:\n", 1
        )[0]

    def test_exact_artifact_zip_is_verified_before_action_download(self):
        job = self.artifact_job()
        stages = [
            "      - name: Upload namespaced release artifact fixture",
            "      - name: Wait for uploaded artifact ID to become visible",
            "      - name: Verify raw Artifact API digest and strict ZIP contract",
            "      - name: Download namespaced release artifact fixture",
            "      - name: Require resolver-compatible artifact namespace",
        ]
        positions = [job.index(step) for step in stages]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("--kind zip --output artifact-api.zip", job)
        self.assertIn('test "${actual_digest}" = "${canonical_digest}"', job)
        self.assertIn("scripts/release/validate-actions-artifact.py", job)
        self.assertIn("artifact-ids: ${{ steps.upload.outputs.artifact-id }}", job)
        self.assertIn("github-token: ${{ github.token }}", job)
        self.assertIn("      actions: read", job)
        self.assertNotIn("continue-on-error:", job)

    def test_fixture_download_does_not_use_a_mutable_name_selector(self):
        job = self.artifact_job()
        download = job.split(
            "      - name: Download namespaced release artifact fixture", 1
        )[1].split("      - name: Require resolver-compatible artifact namespace", 1)[0]
        self.assertIn("artifact-ids:", download)
        self.assertNotIn("\n          name:", download)
        self.assertNotIn("\n          pattern:", download)


if __name__ == "__main__":
    unittest.main()

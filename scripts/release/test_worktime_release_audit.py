"""Regression tests for the source-bound P0 release evidence inventory."""
import copy
import unittest

from scripts.release.audit_worktime_release import (
    AuditError,
    GATES,
    check_record,
    matrix_p0,
)

SHA = "a" * 40
OTHER_SHA = "b" * 40
LINK = "https://github.com/Lamy210/SchneeWorktime/actions/runs/123456"


def entry(status="unverified", *, sha=None, tests=None, links=None):
    return {
        "status": status,
        "test_ids": [] if tests is None else tests,
        "evidence_urls": [] if links is None else links,
        "source_sha": sha,
        "note": "",
    }


def fixture():
    return {
        "schema_version": 1,
        "p0": {"AC-01": entry(), "AC-02": entry("blocked")},
        "release_gates": {name: entry() for name in GATES},
    }


class ReleaseAuditTests(unittest.TestCase):
    def test_baseline_matrix_extracts_only_p0(self):
        source = "| AC-01 | P0 | a | b |\n| AC-02 | P1 | c | d |\n"
        self.assertEqual(matrix_p0(source, enforce_baseline=False), {"AC-01"})

    def test_duplicate_acceptance_id_is_rejected(self):
        source = "| AC-01 | P0 | a | b |\n| AC-01 | P1 | c | d |\n"
        with self.assertRaisesRegex(AuditError, "duplicate"):
            matrix_p0(source, enforce_baseline=False)

    def test_inventory_lint_allows_known_blockers_without_approving_release(self):
        result = check_record(fixture(), {"AC-01", "AC-02"})
        self.assertEqual(result["passed"], 0)
        self.assertEqual(result["blocked"], 1)
        self.assertEqual(result["unverified"], len(GATES) + 1)

    def test_missing_or_fictitious_p0_is_rejected(self):
        evidence = fixture()
        evidence["p0"]["AC-99"] = entry()
        with self.assertRaisesRegex(AuditError, "coverage mismatch"):
            check_record(evidence, {"AC-01", "AC-02"})
        del evidence["p0"]["AC-99"]
        del evidence["p0"]["AC-01"]
        with self.assertRaisesRegex(AuditError, "coverage mismatch"):
            check_record(evidence, {"AC-01", "AC-02"})

    def test_no_empty_or_unbound_pass_evidence(self):
        evidence = fixture()
        evidence["p0"]["AC-01"] = entry("passed")
        with self.assertRaisesRegex(AuditError, "without source-bound"):
            check_record(evidence, {"AC-01", "AC-02"})
        evidence["p0"]["AC-01"] = entry("passed", sha=SHA, links=[LINK])
        with self.assertRaisesRegex(AuditError, "requires a test ID"):
            check_record(evidence, {"AC-01", "AC-02"})

    def test_complete_mode_rejects_unknown_even_if_other_entries_pass(self):
        evidence = fixture()
        with self.assertRaisesRegex(AuditError, "not passed"):
            check_record(evidence, {"AC-01", "AC-02"}, require_complete=True, source_sha=SHA)

    def test_complete_mode_rejects_stale_proof(self):
        evidence = fixture()
        for value in list(evidence["p0"].values()) + list(evidence["release_gates"].values()):
            value.update(entry("passed", sha=OTHER_SHA, tests=["Tests/File.swift"], links=[LINK]))
        with self.assertRaisesRegex(AuditError, "not bound"):
            check_record(evidence, {"AC-01", "AC-02"}, require_complete=True, source_sha=SHA)

    def test_complete_mode_accepts_well_formed_current_proofs_only(self):
        evidence = fixture()
        for value in list(evidence["p0"].values()) + list(evidence["release_gates"].values()):
            value.update(entry("passed", sha=SHA, tests=["Tests/File.swift"], links=[LINK]))
        count = check_record(evidence, {"AC-01", "AC-02"}, require_complete=True, source_sha=SHA)
        self.assertEqual(count["passed"], len(GATES) + 2)

    def test_unknown_gate_or_outside_repository_url_is_rejected(self):
        evidence = fixture()
        evidence["release_gates"]["invented_gate"] = entry()
        with self.assertRaisesRegex(AuditError, "gate names"):
            check_record(evidence, {"AC-01", "AC-02"})
        evidence = fixture()
        evidence["p0"]["AC-01"] = entry("passed", sha=SHA, tests=["Tests/File.swift"], links=[
            "https://evil.example/evidence"
        ])
        with self.assertRaisesRegex(AuditError, "URLs"):
            check_record(evidence, {"AC-01", "AC-02"})

    def test_records_must_not_gain_unreviewed_fields(self):
        evidence = copy.deepcopy(fixture())
        evidence["p0"]["AC-01"]["skip"] = True
        with self.assertRaisesRegex(AuditError, "fields"):
            check_record(evidence, {"AC-01", "AC-02"})


if __name__ == "__main__":
    unittest.main()

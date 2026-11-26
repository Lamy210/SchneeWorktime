#!/usr/bin/env python3
"""Fail-closed evidence inventory for SchneeWorktime v1.0 (not a GO decision).

Default mode validates coverage and data shape without asserting any AC has passed.
--require-complete additionally requires all P0 and release gates to have source-bound
evidence; a human must still independently verify the evidence before publication.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / "docs/SchneeWorktime/ACCEPTANCE_MATRIX.md"
EVIDENCE = ROOT / "docs/SchneeWorktime/P0_RELEASE_EVIDENCE.json"
ROW = re.compile(r"^\|\s*(AC-\d{2,3})\s*\|\s*(P[01])\s*\|")
SHA = re.compile(r"^[0-9a-f]{40}$")
STATES = {"unverified", "blocked", "passed"}
# Pin identities, not only counts: exchanging a P0 and a P1 must not
# silently remove a release requirement. Change only by explicit scope review.
BASELINE_P1 = {
    "AC-33", "AC-34", "AC-35", "AC-36",
    "AC-37", "AC-38", "AC-39", "AC-40",
    "AC-54", "AC-55", "AC-56", "AC-76",
    "AC-77", "AC-78", "AC-79", "AC-80",
    "AC-81", "AC-82", "AC-83", "AC-84",
    "AC-89", "AC-100", "AC-117", "AC-138",
}
GATES = {
    "openspec_strict",
    "main_required_ci",
    "macos_real_device_qa",
    "recovery_fault_injection",
    "data_erasure",
    "journal_capacity",
    "release_candidate",
    "performance_qa",
}


class AuditError(ValueError):
    """Evidence inventory is malformed or incomplete."""


def matrix_p0(text: str, *, enforce_baseline: bool = True) -> set[str]:
    found: dict[str, str] = {}
    for line in text.splitlines():
        match = ROW.match(line)
        if match is None:
            continue
        ac_id, priority = match.groups()
        if ac_id in found:
            raise AuditError(f"duplicate acceptance ID: {ac_id}")
        found[ac_id] = priority
    if not found:
        raise AuditError("no acceptance IDs found")
    if enforce_baseline:
        all_ids = {f"AC-{n:02d}" for n in range(1, 173)}
        if set(found) != all_ids:
            raise AuditError("acceptance matrix IDs changed; review the 172-case baseline")
    p0 = {ac_id for ac_id, priority in found.items() if priority == "P0"}
    if enforce_baseline and len(p0) != 148:
        raise AuditError(f"P0 baseline changed: expected 148, got {len(p0)}")
    if enforce_baseline and set(found) - p0 != BASELINE_P1:
        raise AuditError("acceptance priority baseline changed; review P0/P1 identities")
    return p0


def unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Reject duplicate JSON keys at every depth instead of silently overwriting."""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AuditError(f"duplicate evidence JSON key: {key}")
        result[key] = value
    return result


def parse_evidence(text: str) -> Any:
    return json.loads(text, object_pairs_hook=unique_json_object)


def check_record(
    record: Any, p0: set[str], *, require_complete: bool = False,
    source_sha: str | None = None,
) -> dict[str, int]:
    if (not isinstance(record, dict) or type(record.get("schema_version")) is not int
            or record["schema_version"] != 1):
        raise AuditError("unsupported evidence schema")
    if set(record) != {"schema_version", "p0", "release_gates"}:
        raise AuditError("missing or extra evidence root fields")
    entries = record.get("p0")
    if not isinstance(entries, dict) or set(entries) != p0:
        missing = sorted(p0 - set(entries)) if isinstance(entries, dict) else sorted(p0)
        extra = sorted(set(entries) - p0) if isinstance(entries, dict) else []
        raise AuditError(f"P0 coverage mismatch: missing={missing}, extra={extra}")
    gates = record.get("release_gates")
    if not isinstance(gates, dict) or set(gates) != GATES:
        raise AuditError("release gate names are missing or unknown")
    if require_complete and (source_sha is None or SHA.fullmatch(source_sha) is None):
        raise AuditError("--require-complete requires a 40-character lowercase --source-sha")

    counts = {key: 0 for key in STATES}
    for name, entry in list(entries.items()) + list(gates.items()):
        if not isinstance(entry, dict):
            raise AuditError(f"{name}: invalid evidence entry")
        if set(entry) != {"status", "test_ids", "evidence_urls", "source_sha", "note"}:
            raise AuditError(f"{name}: missing or extra evidence fields")
        state = entry["status"]
        if not isinstance(state, str) or state not in STATES:
            raise AuditError(f"{name}: invalid state {state!r}")
        counts[state] += 1
        if not isinstance(entry["note"], str):
            raise AuditError(f"{name}: note must be text")
        for key in ("test_ids", "evidence_urls"):
            value = entry[key]
            if not isinstance(value, list) or any(
                not isinstance(item, str) or not item.strip() for item in value
            ) or len(value) != len(set(value)):
                raise AuditError(f"{name}: {key} must be a list of distinct nonempty strings")
        proof_sha = entry["source_sha"]
        if proof_sha is not None and (
            not isinstance(proof_sha, str) or SHA.fullmatch(proof_sha) is None
        ):
            raise AuditError(f"{name}: invalid source_sha")
        if any(
            not url.startswith("https://github.com/Lamy210/SchneeWorktime/")
            for url in entry["evidence_urls"]
        ):
            raise AuditError(f"{name}: evidence URLs must point to this repository")
        if state == "passed":
            if not entry["evidence_urls"] or proof_sha is None:
                raise AuditError(f"{name}: passed without source-bound evidence")
            if name in p0 and not entry["test_ids"]:
                raise AuditError(f"{name}: passed P0 requires a test ID")
        if require_complete:
            if state != "passed":
                raise AuditError(f"{name}: not passed ({state})")
            if proof_sha != source_sha:
                raise AuditError(f"{name}: evidence is not bound to requested source SHA")
    return counts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix", type=Path, default=MATRIX)
    parser.add_argument("--evidence", type=Path, default=EVIDENCE)
    parser.add_argument("--require-complete", action="store_true")
    parser.add_argument("--source-sha")
    args = parser.parse_args(argv)
    try:
        p0 = matrix_p0(args.matrix.read_text(encoding="utf-8"))
        record = parse_evidence(args.evidence.read_text(encoding="utf-8"))
        counts = check_record(
            record, p0, require_complete=args.require_complete,
            source_sha=args.source_sha,
        )
    except (OSError, ValueError, TypeError) as exc:
        print(f"Worktime release evidence: BLOCKED: {exc}", file=sys.stderr)
        return 1
    print(
        f"Worktime P0 inventory: {len(p0)} cases; "
        f"evidence entries={len(p0)}; gates={len(GATES)}; "
        f"passed={counts['passed']} blocked={counts['blocked']} "
        f"unverified={counts['unverified']}."
    )
    if args.require_complete:
        print("Evidence inventory complete. Independent release approval is still required.")
    else:
        print("Inventory syntax only: this is NOT a release GO decision.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Bounded retry for the CI fixture's freshly uploaded exact artifact ID."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def fetch(repository: str, artifact_id: str, kind: str, output: Path) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("invalid repository")
    if any(part in (".", "..") for part in repository.split("/")):
        raise ValueError("invalid repository")
    if not re.fullmatch(r"[1-9][0-9]*", artifact_id):
        raise ValueError("invalid artifact ID")
    if kind not in ("metadata", "zip"):
        raise ValueError("invalid artifact endpoint")
    endpoint = f"/repos/{repository}/actions/artifacts/{artifact_id}"
    if kind == "zip":
        endpoint += "/zip"
    if output.exists() or output.is_symlink():
        raise FileExistsError(output)
    with tempfile.TemporaryDirectory(dir=output.parent) as directory:
        partial = Path(directory) / "response"
        for attempt in range(4):
            with partial.open("wb") as handle:
                result = subprocess.run(
                    ["gh", "api", endpoint], stdout=handle, stderr=subprocess.PIPE,
                    timeout=15, check=False,
                )
            if result.returncode == 0:
                os.link(partial, output)
                return
            if attempt == 3 or not re.search(rb"\(HTTP 404\)\s*$", result.stderr):
                raise RuntimeError(f"artifact {kind} fetch failed (exit {result.returncode})")
            print(f"Artifact {kind} not visible yet; retry {attempt + 1}/3", flush=True)
            time.sleep(2 ** attempt)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--artifact-id", required=True)
    parser.add_argument("--kind", choices=("metadata", "zip"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fetch(args.repository, args.artifact_id, args.kind, args.output)


if __name__ == "__main__":
    main()

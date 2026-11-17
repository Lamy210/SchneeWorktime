"""Build a Developer-ID-free macOS ZIP candidate, not a public release."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from build_worktime_bundle import APP_NAME, BUNDLE_ID, VERSION_PATTERN, assemble


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def package(binary: Path, output: Path, version: str, source_sha: str) -> None:
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("Version must be canonical X.Y.Z")
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("Expected source commit SHA")
    if binary.is_symlink() or not binary.is_file():
        raise ValueError("Expected a regular executable")
    arch = subprocess.check_output(
        ["lipo", "-archs", str(binary.resolve())], text=True
    ).strip()
    if arch not in {"arm64", "x86_64"}:
        raise ValueError("Expected one supported architecture")
    # Never replace an existing output directory. No release token or Apple credential is used.
    output = output.absolute()
    output.mkdir(mode=0o700, exist_ok=False)
    try:
        with tempfile.TemporaryDirectory(prefix="worktime-candidate-") as directory:
            stage = Path(directory)
            app = stage / f"{APP_NAME}.app"
            assemble(binary, app, version)
            run("plutil", "-lint", str(app / "Contents/Info.plist"))
            run("codesign", "--force", "--sign", "-", "--timestamp=none", str(app))
            run("codesign", "--verify", "--strict", "--verbose=2", str(app))
            name = f"{APP_NAME}-{version}-macos-{arch}-adhoc.zip"
            archive = output / name
            run("ditto", "-c", "-k", "--keepParent", str(app), str(archive))
            unpacked = stage / "roundtrip"
            unpacked.mkdir()
            run("ditto", "-x", "-k", str(archive), str(unpacked))
            restored = unpacked / app.name
            run("codesign", "--verify", "--strict", "--verbose=2", str(restored))
            run("plutil", "-lint", str(restored / "Contents/Info.plist"))
            if digest(restored / "Contents/MacOS" / APP_NAME) != digest(app / "Contents/MacOS" / APP_NAME):
                raise ValueError("Executable changed during archive roundtrip")
            if digest(restored / "Contents/Info.plist") != digest(app / "Contents/Info.plist"):
                raise ValueError("Bundle metadata changed during archive roundtrip")
            checksum = digest(archive)
            (output / "SHA256SUMS").write_text(f"{checksum}  {name}\n", encoding="ascii")
            metadata = {
                "schema_version": 1,
                "source_sha": source_sha,
                "app_version": version,
                "bundle_id": BUNDLE_ID,
                "architecture": arch,
                "minimum_macos": "15.0",
                "signing": "ad-hoc",
                "notarized": False,
                "archive": name,
                "sha256": checksum,
            }
            (output / "candidate.json").write_text(
                json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
    except BaseException:
        shutil.rmtree(output)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    package(args.binary, args.output, args.version, args.source_sha)


if __name__ == "__main__":
    main()

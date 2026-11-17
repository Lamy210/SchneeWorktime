"""Assemble a local macOS app bundle from a prebuilt executable; never publish it."""
import argparse
import plistlib
import re
import shutil
import stat
from pathlib import Path

APP_NAME = "SchneeWorktime"
BUNDLE_ID = "uk.lamysnow.schneeworktime"
VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "cffaedfe", "feedfacf", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}


def assemble(binary: Path, output: Path, version: str) -> None:
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("Version must be canonical X.Y.Z")
    if output.name != f"{APP_NAME}.app":
        raise ValueError("Unexpected app bundle name")
    if binary.is_symlink() or not binary.is_file() or not binary.stat().st_mode & stat.S_IXUSR:
        raise ValueError("Expected a regular executable file")
    with binary.open("rb") as source:
        if source.read(4) not in MACHO_MAGICS:
            raise ValueError("Expected a Mach-O executable")
    # An existing bundle must never be replaced or removed, including a symlink.
    output.mkdir(parents=False, exist_ok=False)
    try:
        contents = output / "Contents"
        executable = contents / "MacOS" / APP_NAME
        executable.parent.mkdir(parents=True)
        shutil.copyfile(binary, executable)
        executable.chmod(0o755)
        metadata = {
            "CFBundleDevelopmentRegion": "ja",
            "CFBundleDisplayName": APP_NAME,
            "CFBundleExecutable": APP_NAME,
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": APP_NAME,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": "15.0",
            "LSUIElement": True,
            "NSHighResolutionCapable": True,
        }
        with (contents / "Info.plist").open("wb") as destination:
            plistlib.dump(metadata, destination)
    except BaseException:
        shutil.rmtree(output)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    assemble(args.binary, args.output, args.version)


if __name__ == "__main__":
    main()

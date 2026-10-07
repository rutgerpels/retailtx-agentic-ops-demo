"""Build a deterministic, non-secret source release for the private guest bridge."""

import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


def package(root: Path, destination: Path) -> dict[str, str | int]:
    files = [root / "pyproject.toml", root / "requirements-dev.lock"]
    for directory, suffixes in (
        ("app", {".py", ".sql"}),
        ("sim", {".py"}),
        ("chaos", {".py"}),
        ("scripts/azure", {".py", ".sh"}),
    ):
        files.extend(
            path
            for path in (root / directory).rglob("*")
            if path.is_file() and path.suffix in suffixes and "__pycache__" not in path.parts
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(files):
            if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError("Release input escapes the repository")
            info = ZipInfo(path.relative_to(root).as_posix(), (2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes().replace(b"\r\n", b"\n"))
    content = destination.read_bytes()
    if len(content) > 180_000:
        destination.unlink()
        raise ValueError("Source release exceeds the bounded guest bridge size")
    return {"sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(package(Path(__file__).resolve().parents[2], args.output)))

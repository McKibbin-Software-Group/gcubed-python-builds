#!/usr/bin/env python3
"""Generate a G-Cubed CPython archive manifest from release assets."""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path

INSTALL_ROOT = "/opt/gcubed/python-builds/pyenv"
ASSET_RE = re.compile(
    r"^cpython-(?P<version>[0-9]+[.][0-9]+[.][0-9]+)-(?P<platform>.+)[.]tar[.]gz$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        default=Path("dist"),
        help="Directory containing cpython-*.tar.gz and .sha256 files.",
    )
    parser.add_argument(
        "--repo",
        required=True,
        help="GitHub repository in owner/name form.",
    )
    parser.add_argument(
        "--release-tag",
        default="python-builds-latest",
        help="GitHub Release tag used for asset URLs.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("manifest.json"),
        help="Manifest path to write.",
    )
    return parser.parse_args()


def read_sha256(path: Path) -> str:
    if not path.is_file():
        raise FileNotFoundError(f"missing sha256 file: {path}")

    content = path.read_text(encoding="utf-8").strip()
    if not content:
        raise ValueError(f"empty sha256 file: {path}")

    digest = content.split()[0]
    if len(digest) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in digest):
        raise ValueError(f"invalid sha256 digest in {path}: {digest}")
    return digest.lower()


def version_key(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def build_manifest(artifacts_dir: Path, repo: str, release_tag: str) -> dict:
    archives = []

    for archive_path in sorted(artifacts_dir.glob("cpython-*.tar.gz")):
        match = ASSET_RE.match(archive_path.name)
        if not match:
            continue

        version = match.group("version")
        platform = match.group("platform")
        sha_name = f"cpython-{version}-{platform}.sha256"
        sha256 = read_sha256(artifacts_dir / sha_name)

        archives.append(
            {
                "implementation": "cpython",
                "version": version,
                "platform": platform,
                "archive_format": "tar.gz",
                "asset_name": archive_path.name,
                "url": (
                    f"https://github.com/{repo}/releases/download/"
                    f"{release_tag}/{archive_path.name}"
                ),
                "sha256": sha256,
                "python": f"versions/{version}/bin/python",
                "build_tool": "pyenv/python-build",
            }
        )

    if not archives:
        raise ValueError(f"no cpython-*.tar.gz archives found in {artifacts_dir}")

    archives.sort(key=lambda item: (version_key(item["version"]), item["platform"]))

    return {
        "schema_version": 1,
        "install_root": INSTALL_ROOT,
        "generated_at": datetime.now(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "archives": archives,
    }


def main() -> None:
    args = parse_args()
    manifest = build_manifest(args.artifacts_dir, args.repo, args.release_tag)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()

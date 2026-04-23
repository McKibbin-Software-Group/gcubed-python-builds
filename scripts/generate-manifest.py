#!/usr/bin/env python3
"""Generate a G-Cubed CPython archive manifest from release assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import tarfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from pathlib import PurePosixPath

INSTALL_ROOT = "/opt/gcubed/python-builds/pyenv"
ASSET_RE = re.compile(
    r"^cpython-(?P<version>[0-9]+[.][0-9]+[.][0-9]+)-(?P<platform>.+)[.]tar[.]gz$"
)


@dataclass(frozen=True)
class ArchiveInspection:
    version: str
    platform: str
    python_path: str


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


def compute_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def version_key(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def validate_member_name(archive_path: Path, member_name: str) -> PurePosixPath:
    path = PurePosixPath(member_name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"{archive_path.name}: unsafe archive member: {member_name}")
    return path


def inspect_archive(
    archive_path: Path,
    expected_version: str,
    expected_platform: str,
) -> ArchiveInspection:
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            members = archive.getmembers()
            names: set[str] = set()
            version_dirs: set[str] = set()

            for member in members:
                path = validate_member_name(archive_path, member.name)
                if not path.parts:
                    continue
                if path.parts[0] != "versions":
                    raise ValueError(
                        f"{archive_path.name}: unexpected top-level path: {member.name}"
                    )
                names.add(str(path).rstrip("/"))
                if len(path.parts) >= 2:
                    version_dirs.add(path.parts[1])

            if version_dirs != {expected_version}:
                found = ", ".join(sorted(version_dirs)) or "<none>"
                raise ValueError(
                    f"{archive_path.name}: archive version directory {found!r} "
                    f"does not match filename version {expected_version!r}"
                )

            required_files = [
                f"versions/{expected_version}/bin/python",
                f"versions/{expected_version}/bin/python3",
                f"versions/{expected_version}/build-info.json",
            ]
            for required in required_files:
                if required not in names:
                    raise ValueError(
                        f"{archive_path.name}: required archive member missing: "
                        f"{required}"
                    )

            required_dirs = [
                f"versions/{expected_version}/lib",
                f"versions/{expected_version}/include",
            ]
            for required in required_dirs:
                has_required_subtree = any(
                    name == required or name.startswith(f"{required}/")
                    for name in names
                )
                if not has_required_subtree:
                    raise ValueError(
                        f"{archive_path.name}: required archive subtree missing: "
                        f"{required}"
                    )

            build_info_name = f"versions/{expected_version}/build-info.json"
            build_info_member = archive.getmember(build_info_name)
            build_info_file = archive.extractfile(build_info_member)
            if build_info_file is None:
                raise ValueError(
                    f"{archive_path.name}: cannot read {build_info_name}"
                )

            with build_info_file:
                build_info = json.load(build_info_file)
    except tarfile.TarError as exc:
        raise ValueError(f"{archive_path.name}: invalid tar.gz archive: {exc}") from exc

    actual_version = build_info.get("python_version")
    if actual_version != expected_version:
        raise ValueError(
            f"{archive_path.name}: build-info.json python_version "
            f"{actual_version!r} does not match filename version "
            f"{expected_version!r}"
        )

    actual_executable_version = build_info.get("executable_version")
    if (
        actual_executable_version is not None
        and actual_executable_version != expected_version
    ):
        raise ValueError(
            f"{archive_path.name}: build-info.json executable_version "
            f"{actual_executable_version!r} does not match filename version "
            f"{expected_version!r}"
        )

    actual_platform = build_info.get("platform")
    if actual_platform != expected_platform:
        raise ValueError(
            f"{archive_path.name}: build-info.json platform {actual_platform!r} "
            f"does not match filename platform {expected_platform!r}"
        )

    validation = build_info.get("validation")
    if not isinstance(validation, dict) or validation.get("status") != "passed":
        raise ValueError(
            f"{archive_path.name}: build-info.json validation status is not passed"
        )

    relocation = build_info.get("relocation")
    if relocation is not None:
        if not isinstance(relocation, dict) or relocation.get("status") != "passed":
            raise ValueError(
                f"{archive_path.name}: build-info.json relocation status is not passed"
            )

    return ArchiveInspection(
        version=expected_version,
        platform=expected_platform,
        python_path=f"versions/{expected_version}/bin/python",
    )


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
        computed_sha256 = compute_sha256(archive_path)
        if sha256 != computed_sha256:
            raise ValueError(
                f"{archive_path.name}: sha256 file {sha256} does not match "
                f"archive digest {computed_sha256}"
            )

        inspection = inspect_archive(archive_path, version, platform)

        archives.append(
            {
                "implementation": "cpython",
                "version": inspection.version,
                "platform": inspection.platform,
                "archive_format": "tar.gz",
                "asset_name": archive_path.name,
                "url": (
                    f"https://github.com/{repo}/releases/download/"
                    f"{release_tag}/{archive_path.name}"
                ),
                "sha256": sha256,
                "python": inspection.python_path,
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

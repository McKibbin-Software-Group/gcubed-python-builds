#!/usr/bin/env python3
"""Lightweight tests for manifest archive validation."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from io import BytesIO
from pathlib import Path

SCRIPT = Path(__file__).with_name("generate-manifest.py")


def add_file(archive: tarfile.TarFile, name: str, content: bytes = b"") -> None:
    info = tarfile.TarInfo(name)
    info.size = len(content)
    archive.addfile(info, BytesIO(content))


def write_archive(
    artifacts_dir: Path,
    filename_version: str,
    internal_version: str,
    platform: str = "linux-x86_64-glibc",
    build_info_version: str | None = None,
    executable_version: str | None = None,
) -> Path:
    archive_path = artifacts_dir / f"cpython-{filename_version}-{platform}.tar.gz"
    build_info = {
        "python_version": build_info_version or internal_version,
        "executable_version": executable_version or internal_version,
        "platform": platform,
        "runner": "ubuntu-22.04",
        "built_at": "2026-04-23T00:00:00Z",
        "pyenv_version": "pyenv test",
        "python_build_version": "python-build test",
        "configure_flags": None,
        "relocation": {"status": "passed", "library_path": "$ORIGIN/../lib"},
        "validation": {"status": "passed", "checks": []},
    }

    with tarfile.open(archive_path, "w:gz") as archive:
        prefix = f"versions/{internal_version}"
        add_file(archive, f"{prefix}/bin/python")
        add_file(archive, f"{prefix}/bin/python3")
        add_file(archive, f"{prefix}/lib/os.py")
        add_file(archive, f"{prefix}/include/Python.h")
        add_file(
            archive,
            f"{prefix}/build-info.json",
            json.dumps(build_info).encode("utf-8"),
        )

    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    (artifacts_dir / f"cpython-{filename_version}-{platform}.sha256").write_text(
        f"{digest}  {archive_path.name}\n",
        encoding="utf-8",
    )
    return archive_path


def run_manifest(artifacts_dir: Path, output_path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--artifacts-dir",
            str(artifacts_dir),
            "--repo",
            "AshieSlashy/gcubed-python-builds",
            "--output",
            str(output_path),
        ],
        check=False,
        text=True,
        capture_output=True,
    )


class GenerateManifestTests(unittest.TestCase):
    def test_valid_archive_generates_manifest_entry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifacts_dir = root / "artifacts"
            artifacts_dir.mkdir()
            write_archive(artifacts_dir, "3.13.11", "3.13.11")

            result = run_manifest(artifacts_dir, root / "manifest.json")

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["archives"][0]["version"], "3.13.11")
            self.assertEqual(
                manifest["archives"][0]["python"],
                "versions/3.13.11/bin/python",
            )

    def test_archive_directory_must_match_filename_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifacts_dir = root / "artifacts"
            artifacts_dir.mkdir()
            write_archive(artifacts_dir, "3.13.11", "3.13.13")

            result = run_manifest(artifacts_dir, root / "manifest.json")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match filename version", result.stderr)

    def test_build_info_version_must_match_filename_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifacts_dir = root / "artifacts"
            artifacts_dir.mkdir()
            write_archive(
                artifacts_dir,
                "3.13.11",
                "3.13.11",
                build_info_version="3.13.13",
            )

            result = run_manifest(artifacts_dir, root / "manifest.json")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("build-info.json python_version", result.stderr)

    def test_executable_version_must_match_filename_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifacts_dir = root / "artifacts"
            artifacts_dir.mkdir()
            write_archive(
                artifacts_dir,
                "3.13.11",
                "3.13.11",
                executable_version="3.13.13",
            )

            result = run_manifest(artifacts_dir, root / "manifest.json")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("build-info.json executable_version", result.stderr)


if __name__ == "__main__":
    unittest.main()

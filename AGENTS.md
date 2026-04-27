# G-Cubed CPython Builds

This repository produces MSG-managed prebuilt CPython archives for G-Cubed
devcontainers. The build chain is intentionally small: GitHub Actions, shell
scripts, `pyenv/python-build` in CI, and one Python script for manifest
generation.

## Project Goal

Build selected official CPython source releases for selected platforms, package
the resulting pyenv-style installs into release archives, publish them as GitHub
Release assets, and generate a machine-readable `manifest.json` for runtime
tools.

Use `pyenv` only during CI builds. Customer/devcontainer runtime environments
must not need `pyenv`; they should download an archive, verify its sha256,
extract it under the install root, validate the Python executable, and pass the
absolute Python path to tools such as `uv venv --python`.

## Runtime Layout

Archives must unpack under:

```text
/opt/gcubed/python-builds/pyenv/
```

Each archive must contain:

```text
versions/<python-version>/bin/python
versions/<python-version>/bin/python3
versions/<python-version>/lib/...
versions/<python-version>/include/...
versions/<python-version>/build-info.json
```

Archive asset names must use:

```text
cpython-<version>-<platform>.tar.gz
cpython-<version>-<platform>.sha256
manifest.json
```

## Current Matrix

Current Python versions:

```text
3.13.11
3.13.13
3.14.4
```

Current targets:

```text
linux-x86_64-glibc via ubuntu-22.04
linux-arm64-glibc via ubuntu-22.04-arm
macos-arm64 via macos-14
```

## Expected Repository Structure

Keep the implementation pragmatic and dependency-light:

```text
versions.yml
scripts/build-python.sh
scripts/package-python.sh
scripts/generate-manifest.py
.github/workflows/build-python.yml
README.md
```

Do not add a package manager, Python project framework, or generated scaffolding
unless there is a clear need. Plain shell plus one small Python script is the
preferred shape.

## versions.yml Contract

`versions.yml` declares Python versions and target matrix data:

```yaml
versions:
  - "3.13.11"
  - "3.13.13"
  - "3.14.4"

targets:
  - id: linux-x86_64-glibc
    runner: ubuntu-22.04
  - id: linux-arm64-glibc
    runner: ubuntu-22.04-arm
  - id: macos-arm64
    runner: macos-14
```

The workflow should derive the full version x target matrix from this file.

## Build Requirements

CI must use `pyenv/python-build` to build CPython from official Python source
releases. Use:

```sh
pyenv install --skip-existing "$PYTHON_VERSION"
```

Validate each built interpreter with:

```sh
python -V
python -c "import ssl, sqlite3, ctypes, venv; print('ok')"
python -m venv /tmp/gcubed-python-smoke
/tmp/gcubed-python-smoke/bin/python -V
```

Package the pyenv-installed version directory, not a separately installed or
system Python.

## build-info.json Contract

Each archive must include `versions/<version>/build-info.json` with:

- `python_version`
- `platform`
- `runner`
- `built_at`
- `pyenv_version`
- `python_build_version` when available
- configure flags when available
- validation status

Prefer stable, simple JSON fields over large logs.

## Manifest Contract

`manifest.json` must include:

- `schema_version: 1`
- `install_root: "/opt/gcubed/python-builds/pyenv"`
- `generated_at` as an ISO timestamp
- one `archives[]` entry per archive

Each archive entry should include:

- `implementation: "cpython"`
- `version`
- `platform`
- `archive_format: "tar.gz"`
- `asset_name`
- `url`
- `sha256`
- `python`, for example `versions/3.13.11/bin/python`
- `build_tool: "pyenv/python-build"`

Release download URLs should target the documented release tag, initially
`python-builds-latest`, using:

```text
https://github.com/<owner>/<repo>/releases/download/python-builds-latest/<asset>
```

## GitHub Actions Requirements

The workflow should:

- Support `workflow_dispatch`.
- Run when `versions.yml`, workflow files, or scripts change.
- Build every Python version x target combination.
- Upload matrix job artifacts.
- Have a final release job that downloads all artifacts, generates
  `manifest.json`, and uploads all release assets.
- Use maintained release tooling such as `softprops/action-gh-release`.
- Replace/overwrite release assets safely for rebuilds.

Document the chosen release tag (`python-builds-latest`) in `README.md`.

## Documentation Requirements

`README.md` should explain:

- Why this repo exists.
- How to add a new Python version.
- How to trigger the workflow.
- What release assets are produced.
- How consuming runtime code should use `manifest.json`.
- That Linux x86_64 archives are glibc builds from `ubuntu-22.04`.
- That Linux arm64 archives are glibc builds from `ubuntu-22.04-arm`.
- That macOS ARM archives are built on GitHub `macos-14` runners.

## Agent Guidance

When making changes:

- Preserve the simple shell/Python implementation style.
- Keep runtime assumptions explicit and avoid introducing pyenv runtime
  dependencies.
- Treat archive layout and naming as compatibility contracts.
- Prefer deterministic, readable CI steps over clever abstractions.
- Validate generated JSON and shell scripts where practical.
- Do not modify unrelated untracked files, including local tool state.
- Wherever possible scripts and processes should be idempotent

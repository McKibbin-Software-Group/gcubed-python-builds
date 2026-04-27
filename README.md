# G-Cubed CPython Builds

This repository builds MSG-managed CPython archives for G-Cubed devcontainers.
It uses `pyenv/python-build` in GitHub Actions to compile official CPython
source releases, then publishes the resulting pyenv-style installs as GitHub
Release assets.

Runtime environments do not need `pyenv`. They download `manifest.json`, choose
an archive, verify its sha256, extract it under their chosen install root,
validate the Python executable, and pass the absolute interpreter path to tools
such as `uv venv --python`. Archives are built to be relocatable so consumers
can extract them under paths such as `~/.gcubed` or a temporary staging
directory.

## Release Tag

The workflow publishes and replaces assets on this stable release tag:

```text
python-builds-latest
```

Assets are available at URLs like:

```text
https://github.com/<owner>/<repo>/releases/download/python-builds-latest/cpython-3.13.11-linux-x86_64-glibc.tar.gz
```

## Supported Builds

Build targets are declared in `versions.yml`.

Current Python versions:

```text
3.13.11
3.13.13
3.14.4
```

Current platforms:

```text
linux-x86_64-glibc
linux-arm64-glibc
macos-arm64
```

Linux x86_64 archives are built for glibc on GitHub `ubuntu-22.04` runners.
Linux arm64 archives are built for glibc on GitHub `ubuntu-22.04-arm`
runners. macOS ARM archives are built on GitHub `macos-14` runners.

## Adding A Python Version

Edit `versions.yml` and add a quoted CPython patch version:

```yaml
versions:
  - "3.13.11"
  - "3.13.13"
  - "3.14.4"
```

The workflow builds every version x target combination from the file. CPython
versions must be available to `pyenv/python-build`, which downloads official
Python source releases during CI.

## Triggering Builds

Builds run automatically on pushes to `main` that change:

```text
versions.yml
scripts/**
.github/workflows/build-python.yml
```

You can also run the workflow manually from GitHub Actions with
`workflow_dispatch`.

## Produced Assets

For each Python version and platform, the release contains:

```text
cpython-<version>-<platform>.tar.gz
cpython-<version>-<platform>.sha256
```

The release also contains:

```text
manifest.json
```

Each archive unpacks into this layout:

```text
versions/<python-version>/bin/python
versions/<python-version>/bin/python3
versions/<python-version>/lib/...
versions/<python-version>/include/...
versions/<python-version>/build-info.json
```

The manifest includes this default install root:

```text
/opt/gcubed/python-builds/pyenv
```

Consumers may choose a different root. The archive paths and manifest `python`
field are relative to the chosen extraction root.

## Consuming The Manifest

Runtime tooling should:

1. Download `manifest.json` from the `python-builds-latest` release.
2. Select an entry matching the requested `version` and `platform`.
3. Download the entry's `asset_name` from `url`.
4. Verify the archive using `sha256`.
5. Extract the archive under the consumer's chosen install root.
6. Validate `<install-root>/<python>` from the manifest entry.
7. Use that absolute interpreter path with `uv venv --python`.

If a consumer extracts the archive to a temporary location only to create a uv
environment elsewhere, keep the extracted interpreter available for the duration
of the uv command and set uv options explicitly for that command. For example,
`UV_LINK_MODE=copy` avoids package/cache symlinks during package installation,
but archive relocation is still required so the base interpreter can start from
the temporary extraction path.

Example manifest entry:

```json
{
  "archive_format": "tar.gz",
  "asset_name": "cpython-3.13.11-linux-x86_64-glibc.tar.gz",
  "build_tool": "pyenv/python-build",
  "implementation": "cpython",
  "platform": "linux-x86_64-glibc",
  "python": "versions/3.13.11/bin/python",
  "sha256": "<sha256>",
  "url": "https://github.com/<owner>/<repo>/releases/download/python-builds-latest/cpython-3.13.11-linux-x86_64-glibc.tar.gz",
  "version": "3.13.11"
}
```

## Local Script Usage

The scripts are designed to be idempotent where practical. Existing pyenv builds
are reused via `pyenv install --skip-existing`, packaging overwrites prior local
outputs for the same version/platform, and manifest generation overwrites the
target manifest file.

To run the build scripts locally, install `pyenv` first and provide the same
environment variables used by CI. `PYENV_ROOT` can be any writable build
location; packaged archives are validated after extraction to a different
temporary path.

```sh
export PYENV_ROOT="$HOME/.pyenv"
export PYTHON_VERSION="3.13.11"
export TARGET_ID="linux-arm64-glibc"
export TARGET_RUNNER="ubuntu-22.04-arm"

scripts/build-python.sh
scripts/package-python.sh
scripts/generate-manifest.py \
  --artifacts-dir dist \
  --repo "<owner>/<repo>" \
  --release-tag python-builds-latest \
  --output dist/manifest.json
```

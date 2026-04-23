#!/usr/bin/env bash
set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:?PYTHON_VERSION is required}"
TARGET_ID="${TARGET_ID:?TARGET_ID is required}"
TARGET_RUNNER="${TARGET_RUNNER:-${RUNNER_NAME:-unknown}}"
PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"

export PYENV_ROOT
export PYTHON_VERSION
export TARGET_ID
export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/plugins/python-build/bin:$PATH"

if ! command -v pyenv >/dev/null 2>&1; then
  echo "pyenv is required in CI but was not found on PATH" >&2
  exit 1
fi

echo "Building CPython ${PYTHON_VERSION} for ${TARGET_ID} with pyenv"
pyenv install --skip-existing "$PYTHON_VERSION"

INSTALL_DIR="$PYENV_ROOT/versions/$PYTHON_VERSION"
PYTHON_BIN="$INSTALL_DIR/bin/python"
PYTHON3_BIN="$INSTALL_DIR/bin/python3"
BUILD_INFO="$INSTALL_DIR/build-info.json"
SMOKE_VENV="/tmp/gcubed-python-smoke"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Expected executable not found: $PYTHON_BIN" >&2
  exit 1
fi

if [[ ! -x "$PYTHON3_BIN" ]]; then
  echo "Expected executable not found: $PYTHON3_BIN" >&2
  exit 1
fi

rm -rf "$SMOKE_VENV"

"$PYTHON_BIN" -V
"$PYTHON_BIN" -c "import ssl, sqlite3, ctypes, venv; print('ok')"
"$PYTHON_BIN" -m venv "$SMOKE_VENV"
"$SMOKE_VENV/bin/python" -V

export BUILD_INFO
export BUILT_AT
export PYENV_VERSION_TEXT
export PYTHON_BUILD_VERSION_TEXT
export TARGET_RUNNER
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PYENV_VERSION_TEXT="$(pyenv --version 2>/dev/null || true)"
PYTHON_BUILD_VERSION_TEXT="$(python-build --version 2>/dev/null || true)"

"$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

build_info = {
    "python_version": os.environ["PYTHON_VERSION"],
    "platform": os.environ["TARGET_ID"],
    "runner": os.environ["TARGET_RUNNER"],
    "built_at": os.environ["BUILT_AT"],
    "pyenv_version": os.environ.get("PYENV_VERSION_TEXT") or None,
    "python_build_version": os.environ.get("PYTHON_BUILD_VERSION_TEXT") or None,
    "configure_flags": os.environ.get("PYTHON_CONFIGURE_OPTS") or None,
    "validation": {
        "status": "passed",
        "checks": [
            "python -V",
            "python -c \"import ssl, sqlite3, ctypes, venv; print('ok')\"",
            "python -m venv /tmp/gcubed-python-smoke",
            "/tmp/gcubed-python-smoke/bin/python -V",
        ],
    },
}

Path(os.environ["BUILD_INFO"]).write_text(
    json.dumps(build_info, indent=2) + "\n",
    encoding="utf-8",
)
PY

echo "Wrote $BUILD_INFO"

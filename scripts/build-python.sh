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
PYTHON_ABI="${PYTHON_VERSION%.*}"
RELOCATION_LIBRARY_PATH="not-required"

resolve_path() {
  local path="$1"
  local dir
  local base
  local target

  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
    return
  fi

  dir="$(cd "$(dirname "$path")" && pwd -P)"
  base="$(basename "$path")"

  while [[ -L "$dir/$base" ]]; do
    target="$(readlink "$dir/$base")"
    if [[ "$target" = /* ]]; then
      dir="$(cd "$(dirname "$target")" && pwd -P)"
      base="$(basename "$target")"
    else
      base="$target"
    fi
  done

  printf '%s/%s\n' "$dir" "$base"
}

make_linux_relocatable() {
  local real_python

  if ! command -v patchelf >/dev/null 2>&1; then
    echo "patchelf is required to make Linux archives relocatable" >&2
    exit 1
  fi

  real_python="$(resolve_path "$PYTHON_BIN")"
  patchelf --set-rpath '$ORIGIN/../lib' "$real_python"

  if command -v readelf >/dev/null 2>&1; then
    if ! readelf -d "$real_python" | grep -F '$ORIGIN/../lib' >/dev/null; then
      echo "Failed to set relative RUNPATH on $real_python" >&2
      exit 1
    fi
  fi

  RELOCATION_LIBRARY_PATH='$ORIGIN/../lib'
}

make_macos_relocatable() {
  local real_python
  local lib_name
  local lib_path
  local ref
  local rpath

  if ! command -v install_name_tool >/dev/null 2>&1; then
    echo "install_name_tool is required to make macOS archives relocatable" >&2
    exit 1
  fi

  real_python="$(resolve_path "$PYTHON_BIN")"
  lib_name="libpython${PYTHON_ABI}.dylib"
  lib_path="$INSTALL_DIR/lib/$lib_name"
  rpath="@executable_path/../lib"

  if [[ -f "$lib_path" ]]; then
    install_name_tool -id "@rpath/$lib_name" "$lib_path"

    while IFS= read -r ref; do
      if [[ -n "$ref" && "$ref" != @rpath/* ]]; then
        install_name_tool -change "$ref" "@rpath/$lib_name" "$real_python"
      fi
    done < <(otool -L "$real_python" | awk -v lib="$lib_name" '$1 ~ lib {print $1}')
  fi

  if ! otool -l "$real_python" | grep -A2 LC_RPATH | grep -F "$rpath" >/dev/null; then
    install_name_tool -add_rpath "$rpath" "$real_python"
  fi

  RELOCATION_LIBRARY_PATH="$rpath"
}

make_relocatable() {
  case "$(uname -s)" in
    Linux)
      make_linux_relocatable
      ;;
    Darwin)
      make_macos_relocatable
      ;;
    *)
      echo "Unsupported build OS for relocatable archive: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Expected executable not found: $PYTHON_BIN" >&2
  exit 1
fi

if [[ ! -x "$PYTHON3_BIN" ]]; then
  echo "Expected executable not found: $PYTHON3_BIN" >&2
  exit 1
fi

make_relocatable
rm -rf "$SMOKE_VENV"

"$PYTHON_BIN" -V
REPORTED_VERSION="$("$PYTHON_BIN" -c "import platform; print(platform.python_version())")"
if [[ "$REPORTED_VERSION" != "$PYTHON_VERSION" ]]; then
  echo "Built interpreter reports $REPORTED_VERSION, expected $PYTHON_VERSION" >&2
  exit 1
fi
export REPORTED_VERSION
"$PYTHON_BIN" -c "import ssl, sqlite3, ctypes, venv; print('ok')"
"$PYTHON_BIN" -m venv "$SMOKE_VENV"
"$SMOKE_VENV/bin/python" -V
SMOKE_VERSION="$("$SMOKE_VENV/bin/python" -c "import platform; print(platform.python_version())")"
if [[ "$SMOKE_VERSION" != "$PYTHON_VERSION" ]]; then
  echo "Smoke venv interpreter reports $SMOKE_VERSION, expected $PYTHON_VERSION" >&2
  exit 1
fi

export BUILD_INFO
export BUILT_AT
export PYENV_VERSION_TEXT
export PYTHON_BUILD_VERSION_TEXT
export RELOCATION_LIBRARY_PATH
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
    "executable_version": os.environ["REPORTED_VERSION"],
    "platform": os.environ["TARGET_ID"],
    "runner": os.environ["TARGET_RUNNER"],
    "built_at": os.environ["BUILT_AT"],
    "pyenv_version": os.environ.get("PYENV_VERSION_TEXT") or None,
    "python_build_version": os.environ.get("PYTHON_BUILD_VERSION_TEXT") or None,
    "configure_flags": os.environ.get("PYTHON_CONFIGURE_OPTS") or None,
    "relocation": {
        "status": "passed",
        "library_path": os.environ["RELOCATION_LIBRARY_PATH"],
    },
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

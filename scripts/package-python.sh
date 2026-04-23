#!/usr/bin/env bash
set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:?PYTHON_VERSION is required}"
TARGET_ID="${TARGET_ID:?TARGET_ID is required}"
PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"

INSTALL_DIR="$PYENV_ROOT/versions/$PYTHON_VERSION"
ARCHIVE_NAME="cpython-${PYTHON_VERSION}-${TARGET_ID}.tar.gz"
SHA_NAME="cpython-${PYTHON_VERSION}-${TARGET_ID}.sha256"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
SHA_PATH="$OUTPUT_DIR/$SHA_NAME"

for required in \
  "$INSTALL_DIR/bin/python" \
  "$INSTALL_DIR/bin/python3" \
  "$INSTALL_DIR/lib" \
  "$INSTALL_DIR/include" \
  "$INSTALL_DIR/build-info.json"; do
  if [[ ! -e "$required" ]]; then
    echo "Required archive input missing: $required" >&2
    exit 1
  fi
done

REPORTED_VERSION="$("$INSTALL_DIR/bin/python" -c "import platform; print(platform.python_version())")"
if [[ "$REPORTED_VERSION" != "$PYTHON_VERSION" ]]; then
  echo "Packaged interpreter reports $REPORTED_VERSION, expected $PYTHON_VERSION" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

STAGING="$(mktemp -d "${RUNNER_TEMP:-/tmp}/gcubed-python-package.XXXXXX")"
VALIDATION_DIR=""
VALIDATION_VENV_DIR=""
cleanup() {
  rm -rf "$STAGING"
  if [[ -n "$VALIDATION_DIR" ]]; then
    rm -rf "$VALIDATION_DIR"
  fi
  if [[ -n "$VALIDATION_VENV_DIR" ]]; then
    rm -rf "$VALIDATION_VENV_DIR"
  fi
}
trap cleanup EXIT

without_python_loader_env() {
  env \
    -u PYTHONHOME \
    -u PYTHONPATH \
    -u LD_LIBRARY_PATH \
    -u DYLD_LIBRARY_PATH \
    "$@"
}

validate_archive_relocation() {
  local extracted_python
  local extracted_version
  local smoke_venv
  local smoke_version

  VALIDATION_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/gcubed-python-archive-smoke.XXXXXX")"
  VALIDATION_VENV_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/gcubed-python-venv-smoke.XXXXXX")"
  tar -xzf "$ARCHIVE_PATH" -C "$VALIDATION_DIR"

  extracted_python="$VALIDATION_DIR/versions/$PYTHON_VERSION/bin/python"
  smoke_venv="$VALIDATION_VENV_DIR/smoke-venv"

  if [[ ! -x "$extracted_python" ]]; then
    echo "Extracted archive is missing executable: $extracted_python" >&2
    exit 1
  fi

  without_python_loader_env "$extracted_python" -V
  extracted_version="$(
    without_python_loader_env "$extracted_python" \
      -c "import platform; print(platform.python_version())"
  )"
  if [[ "$extracted_version" != "$PYTHON_VERSION" ]]; then
    echo "Extracted interpreter reports $extracted_version, expected $PYTHON_VERSION" >&2
    exit 1
  fi

  without_python_loader_env "$extracted_python" \
    -c "import ssl, sqlite3, ctypes, venv; print('ok')"
  without_python_loader_env "$extracted_python" -m venv "$smoke_venv"
  without_python_loader_env "$smoke_venv/bin/python" -V
  smoke_version="$(
    without_python_loader_env "$smoke_venv/bin/python" \
      -c "import platform; print(platform.python_version())"
  )"
  if [[ "$smoke_version" != "$PYTHON_VERSION" ]]; then
    echo "Extracted smoke venv reports $smoke_version, expected $PYTHON_VERSION" >&2
    exit 1
  fi
}

mkdir -p "$STAGING/versions/$PYTHON_VERSION"
cp -a "$INSTALL_DIR/." "$STAGING/versions/$PYTHON_VERSION/"

ARCHIVE_TMP="$ARCHIVE_PATH.tmp"
SHA_TMP="$SHA_PATH.tmp"
rm -f "$ARCHIVE_TMP" "$SHA_TMP"

tar -C "$STAGING" -czf "$ARCHIVE_TMP" "versions"
mv "$ARCHIVE_TMP" "$ARCHIVE_PATH"

validate_archive_relocation

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUTPUT_DIR" && sha256sum "$ARCHIVE_NAME" > "$SHA_NAME.tmp")
else
  (cd "$OUTPUT_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$SHA_NAME.tmp")
fi

mv "$SHA_TMP" "$SHA_PATH"

echo "Wrote $ARCHIVE_PATH"
echo "Wrote $SHA_PATH"

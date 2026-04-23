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

mkdir -p "$OUTPUT_DIR"

STAGING="$(mktemp -d "${RUNNER_TEMP:-/tmp}/gcubed-python-package.XXXXXX")"
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

mkdir -p "$STAGING/versions/$PYTHON_VERSION"
cp -a "$INSTALL_DIR/." "$STAGING/versions/$PYTHON_VERSION/"

ARCHIVE_TMP="$ARCHIVE_PATH.tmp"
SHA_TMP="$SHA_PATH.tmp"
rm -f "$ARCHIVE_TMP" "$SHA_TMP"

tar -C "$STAGING" -czf "$ARCHIVE_TMP" "versions"
mv "$ARCHIVE_TMP" "$ARCHIVE_PATH"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUTPUT_DIR" && sha256sum "$ARCHIVE_NAME" > "$SHA_NAME.tmp")
else
  (cd "$OUTPUT_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$SHA_NAME.tmp")
fi

mv "$SHA_TMP" "$SHA_PATH"

echo "Wrote $ARCHIVE_PATH"
echo "Wrote $SHA_PATH"

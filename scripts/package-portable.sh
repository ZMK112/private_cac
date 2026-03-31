#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist}"
PKG_NAME="cac-portable-latest"
TMP_DIR="$(mktemp -d)"
PKG_ROOT="${TMP_DIR}/${PKG_NAME}"
ZIP_PATH="${OUT_DIR}/${PKG_NAME}.zip"
SHA_PATH="${OUT_DIR}/${PKG_NAME}.sha256"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

mkdir -p "$OUT_DIR"

echo "Building latest cac ..."
bash build.sh >/dev/null

echo "Collecting project files ..."
rsync -a \
    --exclude '.git/' \
    --exclude '.cac/' \
    --exclude '.cac-dist/' \
    --exclude 'dist/' \
    --exclude 'release/' \
    --exclude '.DS_Store' \
    "${ROOT_DIR}/" "${PKG_ROOT}/"

echo "Creating zip archive ..."
rm -f "$ZIP_PATH" "$SHA_PATH"
(cd "$TMP_DIR" && zip -qry "$ZIP_PATH" "$PKG_NAME")

echo "Writing checksum ..."
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$SHA_PATH")")

echo "Created:"
echo "  $ZIP_PATH"
echo "  $SHA_PATH"

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
OUTPUT_DIR="${1:-$ROOT_DIR/dist}"
ARCHIVE_NAME="linux-bootstrap-v${VERSION}.zip"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linux-bootstrap-release.XXXXXX")"

cleanup() {
  find "$STAGE_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for command_name in git go tar zip sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Release packaging requires %s.\n' "$command_name" >&2
    exit 1
  }
done

mkdir -p "$OUTPUT_DIR" "$STAGE_DIR/linux-bootstrap/bin"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
"$ROOT_DIR/tools/build-tui.sh" --all --output-dir "$STAGE_DIR/linux-bootstrap/bin"
git -C "$ROOT_DIR" archive --format=tar HEAD | tar -xf - -C "$STAGE_DIR/linux-bootstrap"
chmod +x "$STAGE_DIR/linux-bootstrap/setup.sh" "$STAGE_DIR/linux-bootstrap/bin/"*

rm -f "$OUTPUT_DIR/$ARCHIVE_NAME" "$OUTPUT_DIR/$ARCHIVE_NAME.sha256"
(cd "$STAGE_DIR" && zip -qr "$OUTPUT_DIR/$ARCHIVE_NAME" linux-bootstrap)
(cd "$OUTPUT_DIR" && sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")

printf 'Created %s\n' "$OUTPUT_DIR/$ARCHIVE_NAME"
printf 'Created %s\n' "$OUTPUT_DIR/$ARCHIVE_NAME.sha256"

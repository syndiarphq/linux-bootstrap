#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_VERSION="1.1.0"
readonly RELEASE_BASE="https://github.com/syndiarphq/linux-bootstrap/releases/download/v${BOOTSTRAP_VERSION}"
readonly ARCHIVE_NAME="linux-bootstrap-v${BOOTSTRAP_VERSION}.zip"

for command_name in curl unzip sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Linux Bootstrap requires %s for the one-line installer.\n' "$command_name" >&2
    exit 1
  }
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-bootstrap.XXXXXX")"
cleanup() {
  chmod -R u+w "$temporary_dir" 2>/dev/null || true
  find "$temporary_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM

printf 'Downloading Linux Bootstrap v%s...\n' "$BOOTSTRAP_VERSION"
curl --fail --silent --show-error --location --retry 3 \
  --output "$temporary_dir/$ARCHIVE_NAME" "$RELEASE_BASE/$ARCHIVE_NAME"
curl --fail --silent --show-error --location --retry 3 \
  --output "$temporary_dir/$ARCHIVE_NAME.sha256" "$RELEASE_BASE/$ARCHIVE_NAME.sha256"

(
  cd "$temporary_dir"
  sha256sum --check "$ARCHIVE_NAME.sha256"
)
unzip -q "$temporary_dir/$ARCHIVE_NAME" -d "$temporary_dir/extracted"

setup="$temporary_dir/extracted/linux-bootstrap/setup.sh"
[[ -x "$setup" ]] || {
  printf 'The verified release archive does not contain an executable setup.sh.\n' >&2
  exit 1
}

if [[ -t 0 ]]; then
  "$setup" "$@"
elif [[ -r /dev/tty ]]; then
  "$setup" "$@" </dev/tty
else
  printf 'An interactive terminal is required. Run with bash process substitution instead of curl | bash.\n' >&2
  exit 1
fi

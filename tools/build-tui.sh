#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v go >/dev/null 2>&1 || { printf 'Go is required to build the TUI.\n' >&2; exit 1; }
mkdir -p "$ROOT_DIR/bin"
BUILD_CACHE_ROOT="${TMPDIR:-/tmp}/linux-bootstrap-go-cache-$UID"
mkdir -p "$BUILD_CACHE_ROOT/build" "$BUILD_CACHE_ROOT/mod" "$BUILD_CACHE_ROOT/path"
(cd "$ROOT_DIR/tui" && env \
  GOCACHE="$BUILD_CACHE_ROOT/build" \
  GOMODCACHE="$BUILD_CACHE_ROOT/mod" \
  GOPATH="$BUILD_CACHE_ROOT/path" \
  go build -buildvcs=false -trimpath -ldflags='-s -w' -o "$ROOT_DIR/bin/linux-bootstrap-tui" .)
printf 'Built %s\n' "$ROOT_DIR/bin/linux-bootstrap-tui"

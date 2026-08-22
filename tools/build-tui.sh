#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v go >/dev/null 2>&1 || { printf 'Go is required to build the TUI.\n' >&2; exit 1; }
OUTPUT_DIR="$ROOT_DIR/bin"
BUILD_ALL=false

while (($#)); do
  case "$1" in
    --all) BUILD_ALL=true ;;
    --output-dir)
      (($# >= 2)) || { printf '%s\n' 'Missing directory after --output-dir.' >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift
      ;;
    -h|--help)
      printf 'Usage: %s [--all] [--output-dir DIR]\n' "$0"
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$OUTPUT_DIR"
BUILD_CACHE_ROOT="${TMPDIR:-/tmp}/linux-bootstrap-go-cache-$UID"
mkdir -p "$BUILD_CACHE_ROOT/build" "$BUILD_CACHE_ROOT/mod" "$BUILD_CACHE_ROOT/path"

build_tui() {
  local go_arch="$1" output="$OUTPUT_DIR/linux-bootstrap-tui-$1"
  (cd "$ROOT_DIR/tui" && env \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH="$go_arch" \
    GOCACHE="$BUILD_CACHE_ROOT/build" \
    GOMODCACHE="$BUILD_CACHE_ROOT/mod" \
    GOPATH="$BUILD_CACHE_ROOT/path" \
    go build -buildvcs=false -trimpath -ldflags='-s -w' -o "$output" .)
  printf 'Built %s\n' "$output"
}

if [[ "$BUILD_ALL" == true ]]; then
  build_tui amd64
  build_tui arm64
else
  case "$(uname -m)" in
    x86_64|amd64) build_tui amd64 ;;
    aarch64|arm64) build_tui arm64 ;;
    *)
      printf 'The full TUI does not currently support architecture: %s\n' "$(uname -m)" >&2
      exit 1
      ;;
  esac
fi

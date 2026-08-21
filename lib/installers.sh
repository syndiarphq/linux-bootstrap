#!/usr/bin/env bash

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/linux-bootstrap"
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
  LOG_DIR="${TMPDIR:-/tmp}/linux-bootstrap-$UID"
  mkdir -p "$LOG_DIR"
fi
LOG_FILE="$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
if ! : 2>/dev/null > "$LOG_FILE"; then
  LOG_DIR="${TMPDIR:-/tmp}/linux-bootstrap-$UID"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
  : > "$LOG_FILE"
fi

run() {
  printf '+ ' | tee -a "$LOG_FILE"
  printf '%q ' "$@" | tee -a "$LOG_FILE"
  printf '\n' | tee -a "$LOG_FILE"
  [[ "$DRY_RUN" == true ]] || "$@" 2>&1 | tee -a "$LOG_FILE"
}

run_interactive() {
  printf '+ interactive: ' | tee -a "$LOG_FILE"
  printf '%q ' "$@" | tee -a "$LOG_FILE"
  printf '\n' | tee -a "$LOG_FILE"
  [[ "$DRY_RUN" == true ]] || "$@"
}

run_interactive_as_root() {
  if ((EUID == 0)); then run_interactive "$@"
  elif command -v sudo >/dev/null 2>&1; then run_interactive sudo "$@"
  else die "Root privileges are required; install sudo or run as root."
  fi
}

as_root() {
  if ((EUID == 0)); then run "$@"
  elif command -v sudo >/dev/null 2>&1; then run sudo "$@"
  else die "Root privileges are required; install sudo or run as root."
  fi
}

profile_groups() {
  case "$1/$2" in
    arch/desktop) printf '%s\n' base terminal graphical development backup storage network virtualization gaming fonts ;;
    arch/server) printf '%s\n' base server development monitoring backup storage network ;;
    debian/server) printf '%s\n' base server development monitoring ;;
    debian/desktop) printf '%s\n' base terminal graphical development fonts ;;
    fedora/server) printf '%s\n' base server development monitoring ;;
    fedora/desktop) printf '%s\n' base terminal graphical development gaming fonts ;;
    suse/server) printf '%s\n' base server development monitoring ;;
    suse/desktop) printf '%s\n' base terminal graphical development fonts ;;
    *) die "No package profile for $1/$2" ;;
  esac
}

profile_packages() {
  local family="$1" profile="$2" group file
  while IFS= read -r group; do
    file="$ROOT_DIR/packages/$family/$profile/$group.txt"
    [[ -r "$file" ]] || die "Missing package list: $file"
    read_packages "$file"
  done < <(profile_groups "$family" "$profile") | sort -u
  return 0
}

read_packages() {
  local file="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r line <<<"$line"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done < "$file"
  return 0
}

install_group_files() {
  local family="$1" profile="$2"; shift 2
  local group file
  local -a requested=()
  for group in "$@"; do
    file="$ROOT_DIR/packages/$family/$profile/$group.txt"
    [[ -r "$file" ]] || die "Missing package list: $file"
    mapfile -t group_packages < <(read_packages "$file")
    requested+=("${group_packages[@]}")
  done
  install_packages "$family" "${requested[@]}"
}

install_packages() {
  local family="$1" pkg; shift
  local -a missing=()
  local -A seen=()
  for pkg in "$@"; do
    [[ -n "${seen[$pkg]:-}" ]] && continue
    seen[$pkg]=1
    is_package_installed "$family" "$pkg" || missing+=("$pkg")
  done
  ((${#missing[@]})) || { ui_success "All selected packages are already installed."; return; }
  case "$family" in
    arch) as_root pacman -S --needed --noconfirm "${missing[@]}" ;;
    debian)
      as_root apt-get update
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
      ;;
    fedora) as_root dnf install -y "${missing[@]}" ;;
    suse) as_root zypper --non-interactive install --no-recommends "${missing[@]}" ;;
  esac
}

is_package_installed() {
  local family="$1" pkg="$2"
  case "$family" in
    arch) pacman -Q "$pkg" >/dev/null 2>&1 ;;
    debian) dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' ;;
    fedora|suse) rpm -q "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

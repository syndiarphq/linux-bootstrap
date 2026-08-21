#!/usr/bin/env bash

EXTERNAL_STATUS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/linux-bootstrap/external-versions.tsv"

external_primary_binary() {
  external_binary_names "$1" | sed -n '1p'
}

official_package_version() {
  local package="$1"
  case "$DISTRO_FAMILY" in
    arch) pacman -Q "$package" 2>/dev/null | awk '{print $2}' ;;
    debian) dpkg-query -W -f='${Version}\n' "$package" 2>/dev/null ;;
    fedora|suse) rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$package" 2>/dev/null ;;
  esac
}

external_install_source() {
  local id="$1"
  if [[ "$id" == fastfetch || ( "$DISTRO_FAMILY" == arch && "$id" =~ ^(starship|superfile)$ ) ]]; then
    printf '%s repository\n' "$DISTRO_PRETTY"
  else
    external_field "$id" 7
  fi
}

external_install_method() {
  local id="$1"
  if [[ "$id" == fastfetch || ( "$DISTRO_FAMILY" == arch && "$id" =~ ^(starship|superfile)$ ) ]]; then
    printf 'official-package\n'
  else
    external_field "$id" 4
  fi
}

external_installed_version() {
  local id="$1" binary output source_dir
  if [[ "$id" == fastfetch || ( "$DISTRO_FAMILY" == arch && "$id" =~ ^(starship|superfile)$ ) ]]; then
    official_package_version "$id"
    return
  fi
  case "$id" in
    fnf|fetch|neofetch)
      source_dir="${XDG_CACHE_HOME:-$HOME/.cache}/linux-bootstrap/$id"
      [[ -d "$source_dir/.git" ]] && git -C "$source_dir" rev-parse --short=12 HEAD 2>/dev/null
      return
      ;;
    nerd-font-*) printf 'installed (font release unknown)\n'; return ;;
  esac
  binary="$(external_primary_binary "$id")"
  [[ -n "$binary" ]] || return 0
  if command -v "$binary" >/dev/null 2>&1; then binary="$(command -v "$binary")"
  elif [[ -x "$HOME/.local/bin/$binary" ]]; then binary="$HOME/.local/bin/$binary"
  else return 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    output="$(timeout 2 "$binary" --version 2>/dev/null | sed -n '1p' || true)"
  else
    output="$("$binary" --version 2>/dev/null | sed -n '1p' || true)"
  fi
  printf '%s\n' "${output:-installed (version unavailable)}"
}

external_cached_latest() {
  local id="$1" now timestamp cached_id version
  [[ -r "$EXTERNAL_STATUS_CACHE" ]] || return 1
  now="$(date +%s)"
  while IFS=$'\t' read -r cached_id timestamp version; do
    [[ "$cached_id" == "$id" ]] || continue
    ((now - timestamp < 21600)) || return 1
    printf '%s\n' "$version"
    return 0
  done < "$EXTERNAL_STATUS_CACHE"
  return 1
}

external_latest_version() {
  local id="$1" source latest temporary
  if latest="$(external_cached_latest "$id")"; then printf '%s\n' "$latest"; return 0; fi
  source="$(external_field "$id" 7)"
  [[ "$source" == https://github.com/*/* ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    latest="$(timeout 6 git ls-remote --tags --refs "${source}.git" 'v*' 2>/dev/null | sed 's#.*refs/tags/##' | sort -V | tail -n 1)"
  else
    latest="$(git ls-remote --tags --refs "${source}.git" 'v*' 2>/dev/null | sed 's#.*refs/tags/##' | sort -V | tail -n 1)"
  fi
  [[ -n "$latest" ]] || return 1
  mkdir -p "$(dirname "$EXTERNAL_STATUS_CACHE")"
  temporary="${EXTERNAL_STATUS_CACHE}.partial.$$"
  if [[ -r "$EXTERNAL_STATUS_CACHE" ]]; then awk -F '\t' -v id="$id" '$1 != id' "$EXTERNAL_STATUS_CACHE" > "$temporary"
  else : > "$temporary"
  fi
  printf '%s\t%s\t%s\n' "$id" "$(date +%s)" "$latest" >> "$temporary"
  chmod 0600 "$temporary"
  mv "$temporary" "$EXTERNAL_STATUS_CACHE"
  printf '%s\n' "$latest"
}

external_status_line() {
  local id="$1" installed latest method status=unknown
  method="$(external_install_method "$id")"
  installed="$(external_installed_version "$id")"
  latest="$(external_latest_version "$id" 2>/dev/null || true)"
  if [[ -n "$installed" && -n "$latest" && "$method" == git-* ]]; then
    status="installed commit; latest release $latest"
    latest=""
  elif [[ -n "$installed" && -n "$latest" ]]; then
    if [[ "${installed#v}" == *"${latest#v}"* ]]; then status=current
    else status="update may be available"
    fi
  elif [[ -n "$installed" ]]; then status="installed; latest unknown"
  else status="not installed"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$method" "$(external_install_source "$id")" "${installed:-none}" "$status${latest:+; latest $latest}"
}

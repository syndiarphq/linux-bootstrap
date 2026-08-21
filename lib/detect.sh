#!/usr/bin/env bash

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

detect_platform() {
  [[ "$(uname -s)" == Linux ]] || die "This bootstrap supports Linux only."
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  source /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID}"
  local like=" ${ID_LIKE:-} "
  case "$DISTRO_ID" in
    arch|cachyos|endeavouros|manjaro) DISTRO_FAMILY=arch ;;
    debian|ubuntu|linuxmint|pop) DISTRO_FAMILY=debian ;;
    fedora|rhel|centos|rocky|almalinux) DISTRO_FAMILY=fedora ;;
    opensuse*|suse|sles) DISTRO_FAMILY=suse ;;
    nixos) DISTRO_FAMILY=nixos ;;
    *)
      if [[ "$like" == *" arch "* ]]; then DISTRO_FAMILY=arch
      elif [[ "$like" == *" debian "* ]]; then DISTRO_FAMILY=debian
      elif [[ "$like" == *" fedora "* || "$like" == *" rhel "* ]]; then DISTRO_FAMILY=fedora
      elif [[ "$like" == *" suse "* ]]; then DISTRO_FAMILY=suse
      else DISTRO_FAMILY=unsupported
      fi
      ;;
  esac
  if [[ -e /run/ostree-booted ]]; then
    DISTRO_FAMILY=immutable
  fi
  export DISTRO_ID DISTRO_PRETTY DISTRO_FAMILY
}

detect_profile_hint() {
  local marker
  if [[ -n "${XDG_CURRENT_DESKTOP:-}" || -n "${DESKTOP_SESSION:-}" || -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
    printf 'desktop\n'
    return
  fi

  for marker in startplasma-wayland startplasma-x11 gnome-shell xfce4-session cinnamon \
    mate-session lxqt-session sway hyprland i3 awesome bspwm dwm openbox-session \
    labwc niri; do
    if command -v "$marker" >/dev/null 2>&1; then
      printf 'desktop\n'
      return
    fi
  done

  if compgen -G '/usr/share/xsessions/*.desktop' >/dev/null 2>&1 || \
     compgen -G '/usr/share/wayland-sessions/*.desktop' >/dev/null 2>&1; then
    printf 'desktop\n'
    return
  fi

  printf 'server\n'
}

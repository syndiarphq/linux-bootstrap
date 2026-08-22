#!/usr/bin/env bash

enable_service() {
  command -v systemctl >/dev/null 2>&1 || { ui_warn "systemd not found; skipping service enablement."; return; }
  as_root systemctl enable --now "$1"
}

setup_docker() {
  local pkg=docker service=docker
  [[ "$DISTRO_FAMILY" == debian ]] && pkg=docker.io
  [[ "$DISTRO_FAMILY" == fedora ]] && pkg=moby-engine
  install_named_package "$pkg"
  enable_service "$service"
  ui_warn "Docker is installed. This script does not add users to the docker group (which grants root-equivalent access)."
}

setup_ssh() {
  local pkg=openssh service=sshd
  [[ "$DISTRO_FAMILY" == debian ]] && { pkg=openssh-server; service=ssh; }
  [[ "$DISTRO_FAMILY" == fedora ]] && pkg=openssh-server
  install_named_package "$pkg"
  enable_service "$service"
  ui_success "SSH installed/enabled. No daemon configuration, keys, users, or firewall rules were changed."
}

setup_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then ui_success "Tailscale is already installed."
  elif [[ "$DISTRO_FAMILY" == arch ]]; then install_named_package tailscale
  elif [[ "$DISTRO_FAMILY" == debian ]]; then install_tailscale_apt
  else
    ui_warn "Tailscale is not in this family's standard repositories."
    ui_warn "Install it from https://tailscale.com/download/linux, then re-run this service step."
    return
  fi
  enable_service tailscaled
  ui_success "Run 'sudo tailscale up' when ready to authenticate."
}

install_tailscale_apt() {
  local repository_family codename base_url temp_dir key_file list_file
  # os-release has already been loaded by platform detection.
  case "$DISTRO_ID" in
    debian) repository_family=debian; codename="${VERSION_CODENAME:-}" ;;
    ubuntu) repository_family=ubuntu; codename="${VERSION_CODENAME:-}" ;;
    linuxmint|pop) repository_family=ubuntu; codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
    *) die "Tailscale's apt repository is not configured for $DISTRO_PRETTY." ;;
  esac
  [[ "$codename" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "Could not identify the Debian/Ubuntu codename for Tailscale."
  base_url="https://pkgs.tailscale.com/stable/$repository_family/$codename"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-bootstrap-tailscale.XXXXXX")"
  register_temp_artifact "$temp_dir"
  key_file="$temp_dir/tailscale-archive-keyring.gpg"
  list_file="$temp_dir/tailscale.list"

  if [[ "$DRY_RUN" == true ]]; then
    run curl --fail --location --retry 3 --output "$key_file" "$base_url.noarmor.gpg"
    run curl --fail --location --retry 3 --output "$list_file" "$base_url.tailscale-keyring.list"
    as_root install -D -m 0644 "$key_file" /usr/share/keyrings/tailscale-archive-keyring.gpg
    as_root install -D -m 0644 "$list_file" /etc/apt/sources.list.d/tailscale.list
    install_named_package tailscale
    return 0
  fi

  command -v curl >/dev/null 2>&1 || install_named_package curl
  run curl --fail --location --retry 3 --output "$key_file" "$base_url.noarmor.gpg"
  run curl --fail --location --retry 3 --output "$list_file" "$base_url.tailscale-keyring.list"
  [[ -s "$key_file" ]] || die "Tailscale's repository key download was empty."
  grep -Fq "https://pkgs.tailscale.com/stable/$repository_family $codename main" "$list_file" || die "Tailscale's repository file did not match this system."
  grep -Fq 'signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg' "$list_file" || die "Tailscale's repository file did not use the expected signing key."
  as_root install -D -m 0644 "$key_file" /usr/share/keyrings/tailscale-archive-keyring.gpg
  as_root install -D -m 0644 "$list_file" /etc/apt/sources.list.d/tailscale.list
  install_named_package tailscale
}

install_named_package() {
  local pkg="$1"
  install_packages "$DISTRO_FAMILY" "$pkg"
}

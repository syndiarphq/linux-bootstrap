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
  else
    ui_warn "Tailscale is not in this family's standard repositories."
    ui_warn "Install it from https://tailscale.com/download/linux, then re-run this service step."
    return
  fi
  enable_service tailscaled
  ui_success "Run 'sudo tailscale up' when ready to authenticate."
}

install_named_package() {
  local pkg="$1"
  install_packages "$DISTRO_FAMILY" "$pkg"
}

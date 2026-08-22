#!/usr/bin/env bash

external_catalog_ids() {
  awk -F '\t' '!/^#/ && NF >= 6 {print $1}' "$ROOT_DIR/external/catalog.tsv"
}

external_automated_ids_for_profile() {
  local profile="$1"
  awk -F '\t' -v profile="$profile" '!/^#/ && NF >= 6 && ($3 == "all" || $3 == profile) && $4 != "manual" {print $1}' "$ROOT_DIR/external/catalog.tsv"
}

external_field() {
  local id="$1" column="$2"
  awk -F '\t' -v id="$id" -v column="$column" '$1 == id {print $column; exit}' "$ROOT_DIR/external/catalog.tsv"
}

external_binary_names() {
  local detection
  detection="$(external_field "$1" 6)"
  [[ "$detection" == cmd:* ]] || return 0
  tr ',' '\n' <<<"${detection#cmd:}"
}

external_is_installed() {
  local id="$1" binary detection family
  detection="$(external_field "$id" 6)"
  if [[ "$detection" == font:* ]]; then
    family="${detection#font:}"
    find "$HOME/.local/share/fonts" /usr/local/share/fonts /usr/share/fonts -type f \
      \( -iname "*${family}*NerdFont*.ttf" -o -iname "*${family}*NerdFont*.otf" \) \
      -print -quit 2>/dev/null | grep -q .
    return
  fi
  while IFS= read -r binary; do
    command -v "$binary" >/dev/null 2>&1 && return 0
    [[ -x "$HOME/.local/bin/$binary" || -x "$HOME/.cargo/bin/$binary" || -x "$HOME/.nimble/bin/$binary" ]] && return 0
  done < <(external_binary_names "$id")
  return 1
}

external_native_dependency_packages() {
  local id="$1"
  case "$DISTRO_FAMILY/$id" in
    arch/concord) printf '%s\n' alsa-lib opus pkgconf ;;
    debian/concord) printf '%s\n' libasound2-dev libopus-dev pkg-config ;;
    fedora/concord) printf '%s\n' alsa-lib-devel opus-devel pkgconf-pkg-config ;;
    suse/concord) printf '%s\n' alsa-devel libopus-devel pkg-config ;;
    arch/spotify-player) printf '%s\n' alsa-lib dbus openssl ;;
    debian/spotify-player) printf '%s\n' libasound2-dev libdbus-1-dev libssl-dev ;;
    fedora/spotify-player) printf '%s\n' alsa-lib-devel dbus-devel openssl-devel ;;
    suse/spotify-player) printf '%s\n' alsa-devel dbus-1-devel libopenssl-devel ;;
  esac
}

external_dependency_packages() {
  local id method cargo_package=rust go_package=go firefox_package=firefox
  [[ "$DISTRO_FAMILY" != arch ]] && cargo_package=cargo
  [[ "$DISTRO_FAMILY" == debian ]] && { go_package=golang-go; firefox_package=firefox-esr; }
  [[ "$DISTRO_FAMILY" == fedora ]] && go_package=golang
  [[ "$DISTRO_FAMILY" == suse ]] && firefox_package=MozillaFirefox
  for id in "$@"; do
    if [[ "$DISTRO_FAMILY" == arch && "$id" =~ ^(starship|superfile|fastfetch)$ ]]; then
      continue
    fi
    method="$(external_field "$id" 4)"
    case "$method" in
      cargo) printf '%s\n' "$cargo_package" ;;
      go) printf '%s\n' "$go_package" ;;
      git-make) printf '%s\n' git make ;;
      nimble) printf '%s\n' nim ;;
      release)
        printf '%s\n' curl jq tar
        [[ "$id" == browsh ]] && printf '%s\n' "$firefox_package"
        ;;
      nerdfont) printf '%s\n' curl unzip ;;
      git-copy) printf '%s\n' git ;;
      package) printf '%s\n' "$id" ;;
    esac
    external_native_dependency_packages "$id"
  done | sort -u
}

install_external_dependencies() {
  (($#)) || return 0
  local -a dependencies=()
  mapfile -t dependencies < <(external_dependency_packages "$@")
  ((${#dependencies[@]})) || return 0
  ui_success "Dependency plan: ${dependencies[*]}"
  install_packages "$DISTRO_FAMILY" "${dependencies[@]}"
}

ensure_user_bin() {
  run mkdir -p "$HOME/.local/bin"
}

ensure_external_tool() {
  local command_name="$1" package_name="$2"
  command -v "$command_name" >/dev/null 2>&1 && return
  install_named_package "$package_name"
  [[ "$DRY_RUN" == true ]] || command -v "$command_name" >/dev/null 2>&1 || die "The required command '$command_name' is still unavailable."
}

install_cargo_external() {
  local crate="$1" binary="$2"
  if command -v "$binary" >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/$binary" ]]; then
    ui_success "$binary is already installed."
    return
  fi
  ensure_user_bin
  if [[ -x "$HOME/.cargo/bin/$binary" ]]; then
    run install -m 0755 "$HOME/.cargo/bin/$binary" "$HOME/.local/bin/$binary"
    ui_success "$binary was linked into the standard user-local binary directory."
    return
  fi
  local cargo_package=cargo
  [[ "$DISTRO_FAMILY" == arch ]] && cargo_package=rust
  ensure_external_tool cargo "$cargo_package"
  run cargo install "$crate" --locked --root "$HOME/.local"
}

install_go_external() {
  local module="$1" binary="$2"
  command -v "$binary" >/dev/null 2>&1 && { ui_success "$binary is already installed."; return; }
  local go_package=go
  [[ "$DISTRO_FAMILY" == debian ]] && go_package=golang-go
  [[ "$DISTRO_FAMILY" == fedora ]] && go_package=golang
  ensure_external_tool go "$go_package"
  ensure_user_bin
  run env GOBIN="$HOME/.local/bin" go install "$module@latest"
}

external_release_arch() {
  case "${1:-$(uname -m)}" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

verified_release_asset() {
  local repository="$1" asset_name="$2" checksum_name="$3" inner_path="$4" binary_name="$5"
  local temp_dir api_file tag asset_url checksum_url expected actual extracted
  ensure_external_tool curl curl
  ensure_external_tool jq jq
  ensure_external_tool tar tar
  ensure_user_bin

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-bootstrap-release-asset.XXXXXX")"
  register_temp_artifact "$temp_dir"
  api_file="$temp_dir/release.json"

  if [[ "$DRY_RUN" == true ]]; then
    run curl --fail --location --retry 3 --output "$api_file" "https://api.github.com/repos/$repository/releases/latest"
    ui_success "Would download and verify $asset_name from $repository."
    run install -m 0755 "$temp_dir/$inner_path" "$HOME/.local/bin/$binary_name"
    return 0
  fi

  run curl --fail --location --retry 3 --output "$api_file" "https://api.github.com/repos/$repository/releases/latest"
  tag="$(jq -r '.tag_name // empty' "$api_file")"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([._-][0-9A-Za-z.-]+)?$ ]] || die "Could not identify a stable $repository release."
  asset_name="${asset_name//\{version\}/${tag#v}}"
  checksum_name="${checksum_name//\{version\}/${tag#v}}"
  inner_path="${inner_path//\{version\}/${tag#v}}"
  asset_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$api_file" | head -n 1)"
  checksum_url="$(jq -r --arg name "$checksum_name" '.assets[] | select(.name == $name) | .browser_download_url' "$api_file" | head -n 1)"
  [[ "$asset_url" == "https://github.com/$repository/releases/download/$tag/$asset_name" ]] || die "Could not identify the official $repository archive."
  [[ "$checksum_url" == "https://github.com/$repository/releases/download/$tag/$checksum_name" ]] || die "Could not identify the official $repository checksum."

  run curl --fail --location --retry 3 --output "$temp_dir/$asset_name" "$asset_url"
  run curl --fail --location --retry 3 --output "$temp_dir/$checksum_name" "$checksum_url"
  if [[ "$checksum_name" == *.sha256 ]]; then
    expected="$(tr -d '[:space:]' < "$temp_dir/$checksum_name")"
  else
    expected="$(awk -v name="$asset_name" '$2 == name {print $1; exit}' "$temp_dir/$checksum_name")"
  fi
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "The $repository release did not contain a usable checksum for $asset_name."
  actual="$(sha256sum "$temp_dir/$asset_name" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "Checksum verification failed for $asset_name."
  ui_success "Verified $asset_name."

  run mkdir -p "$temp_dir/extracted"
  run tar -xzf "$temp_dir/$asset_name" --no-same-owner --no-same-permissions -C "$temp_dir/extracted" "$inner_path"
  extracted="$temp_dir/extracted/$inner_path"
  [[ -f "$extracted" && ! -L "$extracted" ]] || die "The verified $repository archive did not contain the expected binary."
  run install -m 0755 "$extracted" "$HOME/.local/bin/$binary_name"
}

install_starship_release() {
  command -v starship >/dev/null 2>&1 && { ui_success "starship is already installed."; return; }
  local arch target
  arch="$(external_release_arch)" || die "Starship has no configured binary for architecture $(uname -m)."
  [[ "$arch" == amd64 ]] && target=x86_64 || target=aarch64
  verified_release_asset starship/starship \
    "starship-${target}-unknown-linux-musl.tar.gz" \
    "starship-${target}-unknown-linux-musl.tar.gz.sha256" \
    starship starship
}

install_superfile_release() {
  external_is_installed superfile && { ui_success "superfile is already installed."; return; }
  local arch
  arch="$(external_release_arch)" || die "Superfile has no configured binary for architecture $(uname -m)."
  verified_release_asset yorukot/superfile \
    "superfile-linux-v{version}-${arch}.tar.gz" \
    "superfile-v{version}-checksums.txt" \
    "./dist/superfile-linux-v{version}-${arch}/spf" spf
}

update_or_clone_external() {
  local url="$1" source_dir="$2" partial local_head remote_head
  ensure_external_tool git git
  if [[ -d "$source_dir/.git" ]]; then
    run git -C "$source_dir" fetch origin
    if [[ "$DRY_RUN" == true ]]; then
      run git -C "$source_dir" merge --ff-only '@{u}'
      return
    fi
    local_head="$(git -C "$source_dir" rev-parse HEAD)"
    remote_head="$(git -C "$source_dir" rev-parse '@{u}')"
    if [[ "$local_head" == "$remote_head" ]]; then
      ui_success "$(basename "$source_dir") source is already current."
    else
      run git -C "$source_dir" merge --ff-only "$remote_head"
    fi
  else
    run mkdir -p "$(dirname "$source_dir")"
    partial="${source_dir}.partial.$$"
    declare -F register_temp_artifact >/dev/null && register_temp_artifact "$partial"
    run git clone --depth 1 "$url" "$partial"
    run mv "$partial" "$source_dir"
    declare -F unregister_temp_artifact >/dev/null && unregister_temp_artifact "$partial"
  fi
}

install_browsh() {
  command -v browsh >/dev/null 2>&1 && { ui_success "browsh is already installed."; return; }
  local firefox_package=firefox arch temp_dir api_file asset_url download
  case "$DISTRO_FAMILY" in
    debian) firefox_package=firefox-esr ;;
    suse) firefox_package=MozillaFirefox ;;
  esac
  install_named_package "$firefox_package"
  ensure_external_tool curl curl
  ensure_external_tool jq jq
  ensure_user_bin
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l) arch=armv7 ;;
    i386|i486|i586|i686) arch=386 ;;
    *) die "Browsh has no configured binary for architecture $(uname -m)." ;;
  esac
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-bootstrap-browsh.XXXXXX")"
  declare -F register_temp_artifact >/dev/null && register_temp_artifact "$temp_dir"
  api_file="$temp_dir/release.json"
  download="$temp_dir/browsh"
  if [[ "$DRY_RUN" == true ]]; then
    run curl --fail --location --output "$api_file" https://api.github.com/repos/browsh-org/browsh/releases/latest
    run jq -r ".assets[] | select(.name | test(\"_linux_${arch}$\")) | .browser_download_url" "$api_file"
    run install -m 0755 "$download" "$HOME/.local/bin/browsh"
    rmdir "$temp_dir"
    declare -F unregister_temp_artifact >/dev/null && unregister_temp_artifact "$temp_dir"
    return
  fi
  run curl --fail --location --output "$api_file" https://api.github.com/repos/browsh-org/browsh/releases/latest
  asset_url="$(jq -r ".assets[] | select(.name | test(\"_linux_${arch}$\")) | .browser_download_url" "$api_file" | head -n 1)"
  [[ "$asset_url" == https://github.com/browsh-org/browsh/releases/download/* ]] || die "Could not identify the official Browsh release binary."
  run curl --fail --location --retry 3 --output "$download" "$asset_url"
  run install -m 0755 "$download" "$HOME/.local/bin/browsh"
  run rm -f "$api_file" "$download"
  rmdir "$temp_dir"
  declare -F unregister_temp_artifact >/dev/null && unregister_temp_artifact "$temp_dir"
}

install_nerd_font() {
  local family="$1" target archive
  target="$HOME/.local/share/fonts/NerdFonts/$family"
  find "$target" -type f \( -name '*.ttf' -o -name '*.otf' \) -print -quit 2>/dev/null | grep -q . && {
    ui_success "$family Nerd Font is already installed."
    return
  }
  ensure_external_tool curl curl
  ensure_external_tool unzip unzip
  archive="${TMPDIR:-/tmp}/linux-bootstrap-${family}.zip"
  declare -F register_temp_artifact >/dev/null && register_temp_artifact "$archive"
  run curl --fail --location --retry 3 --output "$archive" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${family}.zip"
  run mkdir -p "$target"
  run unzip -o "$archive" -d "$target"
  run rm -f "$archive"
  declare -F unregister_temp_artifact >/dev/null && unregister_temp_artifact "$archive"
  if command -v fc-cache >/dev/null 2>&1; then
    run fc-cache -f "$target"
  fi
  return 0
}

install_external() {
  local id="$1" method
  method="$(external_field "$id" 4)"
  case "$id" in
    starship)
      if [[ "$DISTRO_FAMILY" == arch ]]; then install_named_package starship
      else install_starship_release
      fi
      ;;
    lazygit) install_go_external github.com/jesseduffield/lazygit lazygit ;;
    superfile)
      if [[ "$DISTRO_FAMILY" == arch ]]; then install_named_package superfile
      else install_superfile_release
      fi
      ;;
    matcha) install_go_external github.com/floatpane/matcha matcha ;;
    concord) install_cargo_external concord concord ;;
    browsh) install_browsh ;;
    spotify-player) install_cargo_external spotify_player spotify_player ;;
    caligula) install_cargo_external caligula caligula ;;
    fnf)
      command -v fnf >/dev/null 2>&1 && { ui_success "fnf is already installed."; return; }
      ensure_external_tool git git
      ensure_external_tool make make
      ensure_user_bin
      local source_dir="${XDG_CACHE_HOME:-$HOME/.cache}/linux-bootstrap/fnf"
      update_or_clone_external https://github.com/leo-arch/fnf.git "$source_dir"
      run make -C "$source_dir" PREFIX="$HOME/.local" install
      ;;
    fetch)
      [[ -x "$HOME/.local/bin/fetch" ]] && { ui_success "fetch is already installed."; return; }
      ensure_external_tool make make
      ensure_user_bin
      local fetch_source="${XDG_CACHE_HOME:-$HOME/.cache}/linux-bootstrap/fetch"
      update_or_clone_external https://github.com/areofyl/fetch.git "$fetch_source"
      run make -C "$fetch_source" PREFIX="$HOME/.local" install
      ;;
    catnap)
      command -v catnap >/dev/null 2>&1 && { ui_success "catnap is already installed."; return; }
      ensure_external_tool nimble nim
      ensure_user_bin
      run nimble install https://github.com/iinsertNameHere/catnap.git -y
      run install -m 0755 "$HOME/.nimble/bin/catnap" "$HOME/.local/bin/catnap"
      ;;
    neofetch)
      command -v neofetch >/dev/null 2>&1 && { ui_success "neofetch is already installed."; return; }
      ensure_user_bin
      local neofetch_source="${XDG_CACHE_HOME:-$HOME/.cache}/linux-bootstrap/neofetch"
      update_or_clone_external https://github.com/dylanaraps/neofetch.git "$neofetch_source"
      run install -m 0755 "$neofetch_source/neofetch" "$HOME/.local/bin/neofetch"
      ;;
    fastfetch) install_named_package fastfetch ;;
    nerd-font-jetbrains-mono) install_nerd_font JetBrainsMono ;;
    nerd-font-fira-code) install_nerd_font FiraCode ;;
    nerd-font-hack) install_nerd_font Hack ;;
    nerd-font-meslo) install_nerd_font Meslo ;;
    nerd-font-caskaydia-cove) install_nerd_font CaskaydiaCove ;;
    *) die "External application '$id' does not have an automated, reviewed recipe yet." ;;
  esac
}

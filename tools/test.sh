#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/linux-bootstrap-tests.XXXXXX")"
trap 'find "$TEST_ROOT" -depth -delete 2>/dev/null || true' EXIT

find "$ROOT_DIR" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n

export GOCACHE="$TEST_ROOT/go-cache"
export GOMODCACHE="$TEST_ROOT/go-mod"
export GOPATH="$TEST_ROOT/go-path"
(cd "$ROOT_DIR/tui" && go test -buildvcs=false ./...)

[[ "$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")" == "1.1.3" ]]
grep -Fq 'readonly BOOTSTRAP_VERSION="1.1.3"' "$ROOT_DIR/bootstrap.sh"
grep -Fq 'sha256sum --check' "$ROOT_DIR/bootstrap.sh"
grep -Fq 'releases/latest/download/bootstrap.sh' "$ROOT_DIR/README.md"
grep -Fq 'linux-bootstrap-tui-${TUI_ARCH}' "$ROOT_DIR/setup.sh"
grep -Fq 'Use --no-fullscreen to continue without it.' "$ROOT_DIR/setup.sh"
grep -Fq 'The full TUI requires an interactive terminal.' "$ROOT_DIR/setup.sh"

TUI_BUILD_DIR="$TEST_ROOT/tui-build"
"$ROOT_DIR/tools/build-tui.sh" --all --output-dir "$TUI_BUILD_DIR" >/dev/null
for architecture in amd64 arm64; do
  [[ -x "$TUI_BUILD_DIR/linux-bootstrap-tui-$architecture" ]]
  CGO_ENABLED=0 GOOS=linux GOARCH="$architecture" go version -m "$TUI_BUILD_DIR/linux-bootstrap-tui-$architecture" >/dev/null
done

PLAN_TEST="$TEST_ROOT/server.plan"
TEST_FAMILY="$(ROOT_DIR="$ROOT_DIR" bash -c 'source "$ROOT_DIR/lib/detect.sh"; detect_platform; printf %s "$DISTRO_FAMILY"')"
PLAN_PACKAGE="$(ROOT_DIR="$ROOT_DIR" bash -c 'source "$ROOT_DIR/lib/installers.sh"; profile_packages "$1" server | sed -n "1p"' sh "$TEST_FAMILY")"
printf 'FORMAT=1\nFAMILY=%s\nPROFILE=server\nPACKAGE=%s\n' "$TEST_FAMILY" "$PLAN_PACKAGE" > "$PLAN_TEST"
plan_output="$(HOME="$TEST_ROOT/plan-home" "$ROOT_DIR/setup.sh" --plan "$PLAN_TEST" --dry-run)"
grep -q 'Bootstrap report' <<<"$plan_output"
grep -q "$PLAN_PACKAGE" <<<"$plan_output"
doctor_output="$(HOME="$TEST_ROOT/plan-home" "$ROOT_DIR/setup.sh" --doctor --plan "$PLAN_TEST")"
grep -q 'Linux Bootstrap doctor' <<<"$doctor_output"
grep -q "$PLAN_PACKAGE" <<<"$doctor_output"
WRONG_FAMILY=arch
[[ "$TEST_FAMILY" == arch ]] && WRONG_FAMILY=debian
printf 'FORMAT=1\nFAMILY=%s\nPROFILE=server\nPACKAGE=%s\n' "$WRONG_FAMILY" "$PLAN_PACKAGE" > "$PLAN_TEST"
if HOME="$TEST_ROOT/plan-home" "$ROOT_DIR/setup.sh" --plan "$PLAN_TEST" --dry-run >/dev/null 2>&1; then
  printf 'Wrong-family installation plan unexpectedly succeeded.\n' >&2
  exit 1
fi

RETRY_HOME="$TEST_ROOT/retry-home"
RETRY_PACKAGE="$(ROOT_DIR="$ROOT_DIR" bash -c 'source "$ROOT_DIR/lib/validate.sh"; installed_package_names "$1" | sed -n "1p"' sh "$TEST_FAMILY")"
mkdir -p "$RETRY_HOME/.local/state/linux-bootstrap"
printf 'FORMAT\t1\nFAMILY\t%s\nPROFILE\tserver\nFAILURE\tpackage:%s\n' "$TEST_FAMILY" "$RETRY_PACKAGE" > "$RETRY_HOME/.local/state/linux-bootstrap/last-failures.tsv"
HOME="$RETRY_HOME" "$ROOT_DIR/setup.sh" --retry-failed --dry-run >/dev/null
[[ -e "$RETRY_HOME/.local/state/linux-bootstrap/last-failures.tsv" ]]
HOME="$RETRY_HOME" "$ROOT_DIR/setup.sh" --retry-failed >/dev/null
[[ ! -e "$RETRY_HOME/.local/state/linux-bootstrap/last-failures.tsv" ]]

for catalog in "$ROOT_DIR/external/catalog.tsv" "$ROOT_DIR/configurations/catalog.tsv"; do
  expected_fields=6
  [[ "$catalog" == */external/catalog.tsv ]] && expected_fields=7
  awk -F '\t' -v expected="$expected_fields" '!/^#/ && NF != expected {exit 1}' "$catalog"
  duplicate_id="$(awk -F '\t' '!/^#/ {count[$1]++} END {for (id in count) if (count[id] > 1) print id}' "$catalog")"
  [[ -z "$duplicate_id" ]]
done
awk -F '\t' '!/^#/ && (NF != 7 || $4 !~ /^(symlink|watched-copy|per-host)$/ || $5 !~ /^(all|desktop|niri|kde)$/ || $6 !~ /^(portable|review|machine)$/) {exit 1}' "$ROOT_DIR/dotfiles/catalog.tsv"
awk -F '\t' '!/^#/ && $6 !~ /^(cmd|font):/ {exit 1}' "$ROOT_DIR/external/catalog.tsv"
awk -F '\t' '!/^#/ && $4 !~ /^(login-shell|contains|files|command):/ {exit 1}' "$ROOT_DIR/configurations/catalog.tsv"

dependencies="$({
  ROOT_DIR="$ROOT_DIR" DISTRO_FAMILY=arch bash -c '
    source "$ROOT_DIR/external/installers.sh"
    external_dependency_packages caligula fetch browsh nerd-font-hack
  '
} | sort -u)"
for expected in curl firefox git jq make rust unzip; do
  grep -qx "$expected" <<<"$dependencies"
done

for family_and_expected in \
  'arch alsa-lib dbus openssl opus pkgconf rust' \
  'debian cargo libasound2-dev libdbus-1-dev libopus-dev libssl-dev pkg-config' \
  'fedora alsa-lib-devel cargo dbus-devel openssl-devel opus-devel pkgconf-pkg-config' \
  'suse alsa-devel cargo dbus-1-devel libopenssl-devel libopus-devel pkg-config'; do
  read -r family expected_dependencies <<<"$family_and_expected"
  planned="$(ROOT_DIR="$ROOT_DIR" DISTRO_FAMILY="$family" bash -c 'source "$ROOT_DIR/external/installers.sh"; external_dependency_packages concord spotify-player')"
  for expected in $expected_dependencies; do grep -qx "$expected" <<<"$planned"; done
done

external_aliases="$(ROOT_DIR="$ROOT_DIR" bash -c 'source "$ROOT_DIR/external/installers.sh"; external_binary_names superfile')"
grep -qx spf <<<"$external_aliases"
grep -qx superfile <<<"$external_aliases"
external_source="$(ROOT_DIR="$ROOT_DIR" DISTRO_FAMILY=debian DISTRO_PRETTY=Debian bash -c 'source "$ROOT_DIR/external/installers.sh"; source "$ROOT_DIR/external/status.sh"; external_install_source matcha')"
[[ "$external_source" == https://github.com/floatpane/matcha ]]
official_external_source="$(ROOT_DIR="$ROOT_DIR" DISTRO_FAMILY=debian DISTRO_PRETTY=Debian bash -c 'source "$ROOT_DIR/external/installers.sh"; source "$ROOT_DIR/external/status.sh"; external_install_source fastfetch')"
[[ "$official_external_source" == 'Debian repository' ]]
release_dependencies="$(ROOT_DIR="$ROOT_DIR" DISTRO_FAMILY=debian bash -c 'source "$ROOT_DIR/external/installers.sh"; external_dependency_packages starship superfile')"
for expected in curl jq tar; do grep -qx "$expected" <<<"$release_dependencies"; done
if grep -Eq '^(cargo|golang-go)$' <<<"$release_dependencies"; then
  printf 'Release-installed tools unexpectedly requested a compiler.\n' >&2
  exit 1
fi
[[ "$(ROOT_DIR="$ROOT_DIR" bash -c 'source "$ROOT_DIR/external/installers.sh"; external_release_arch x86_64')" == amd64 ]]
[[ "$(ROOT_DIR="$ROOT_DIR" bash -c 'source "$ROOT_DIR/external/installers.sh"; external_release_arch aarch64')" == arm64 ]]

(
  export ROOT_DIR DISTRO_FAMILY=debian DISTRO_ID=debian DISTRO_PRETTY='Debian GNU/Linux 13 (trixie)' VERSION_CODENAME=trixie
  export HOME="$TEST_ROOT/tailscale-home" DRY_RUN=false LOG_FILE="$TEST_ROOT/tailscale.log"
  TEMP_ARTIFACTS=()
  installed_package=""
  root_targets=""
  source "$ROOT_DIR/lib/installers.sh"
  source "$ROOT_DIR/services/services.sh"
  ui_success() { :; }
  ui_warn() { :; }
  die() { printf '%s\n' "$*" >&2; exit 1; }
  register_temp_artifact() { TEMP_ARTIFACTS+=("$1"); }
  install_named_package() { installed_package="$1"; }
  as_root() { root_targets+=" ${*: -1}"; }
  run() {
    local output="" url="${*: -1}"
    if [[ "$1" == curl ]]; then
      while (($#)); do
        [[ "$1" == --output ]] && { output="$2"; break; }
        shift
      done
      mkdir -p "$(dirname "$output")"
      if [[ "$url" == *.gpg ]]; then printf 'test-key\n' > "$output"
      else printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main\n' > "$output"
      fi
    fi
  }
  install_tailscale_apt
  [[ "$installed_package" == tailscale ]]
  [[ "$root_targets" == *'/usr/share/keyrings/tailscale-archive-keyring.gpg'* ]]
  [[ "$root_targets" == *'/etc/apt/sources.list.d/tailscale.list'* ]]
)

configuration_ids="$(ROOT_DIR="$ROOT_DIR" bash -c 'source "$ROOT_DIR/configurations/configurations.sh"; configuration_catalog_ids')"
for expected in fish-login-shell fish-starship micro-developer-essentials starship-preset-nerd-font-symbols starship-preset-tokyo-night upstream-github-auth upstream-spotify-auth upstream-tailscale-up; do
  grep -qx "$expected" <<<"$configuration_ids"
done
[[ "$(ROOT_DIR="$ROOT_DIR" bash -c 'source "$ROOT_DIR/configurations/configurations.sh"; configuration_field fish-starship 1')" == fish-starship ]]

(
  export HOME="$TEST_ROOT/config-home"
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$TEST_ROOT/config-bin"
  printf '#!/usr/bin/env sh\nexit 0\n' > "$TEST_ROOT/config-bin/fish"
  printf '#!/usr/bin/env sh\nif [ "$1" = preset ]; then printf "format = \\\"test\\\"\\n"; fi\n' > "$TEST_ROOT/config-bin/starship"
  printf '#!/usr/bin/env sh\nplugin="${3:-}"\nmkdir -p "$MICRO_CONFIG_HOME/plug/$plugin"\nprintf "{}\\n" > "$MICRO_CONFIG_HOME/plug/$plugin/repo.json"\n' > "$TEST_ROOT/config-bin/micro"
  printf '#!/usr/bin/env sh\nexit 0\n' > "$TEST_ROOT/config-bin/fzf"
  printf '#!/usr/bin/env sh\nexit 0\n' > "$TEST_ROOT/config-bin/ctags"
  chmod +x "$TEST_ROOT/config-bin/fish" "$TEST_ROOT/config-bin/starship" "$TEST_ROOT/config-bin/micro" "$TEST_ROOT/config-bin/fzf" "$TEST_ROOT/config-bin/ctags"
  export PATH="$TEST_ROOT/config-bin:$PATH"
  DRY_RUN=false
  ASSUME_YES=false
  TEMP_ARTIFACTS=()
  run() { "$@"; }
  ui_success() { :; }
  ui_warn() { :; }
  register_temp_artifact() { TEMP_ARTIFACTS+=("$1"); }
  unregister_temp_artifact() { :; }
  die() { printf '%s\n' "$*" >&2; return 1; }
  source "$ROOT_DIR/configurations/configurations.sh"
  export MICRO_CONFIG_HOME="$XDG_CONFIG_HOME/micro"
  mkdir -p "$MICRO_CONFIG_HOME"
  printf '{"colorscheme":"existing","lsp.formatOnSave":false}\n' > "$MICRO_CONFIG_HOME/settings.json"
  printf '{"CtrlP":"ExistingAction"}\n' > "$MICRO_CONFIG_HOME/bindings.json"
  configure_micro_developer_essentials
  configuration_is_complete micro-developer-essentials
  configure_micro_developer_essentials
  [[ "$(find "$MICRO_CONFIG_HOME/plug" -mindepth 1 -maxdepth 1 -type d | wc -l)" == 11 ]]
  [[ "$(jq -r '.colorscheme' "$MICRO_CONFIG_HOME/settings.json")" == existing ]]
  [[ "$(jq -r '.["lsp.formatOnSave"]' "$MICRO_CONFIG_HOME/settings.json")" == false ]]
  [[ "$(jq -r '.CtrlP' "$MICRO_CONFIG_HOME/bindings.json")" == ExistingAction ]]
  [[ "$(jq -r '.F2' "$MICRO_CONFIG_HOME/bindings.json")" == command:tree ]]
  find "$MICRO_CONFIG_HOME" -maxdepth 1 -name 'settings.json.bootstrap-backup-*' -type f -print -quit | grep -q .
  find "$MICRO_CONFIG_HOME" -maxdepth 1 -name 'bindings.json.bootstrap-backup-*' -type f -print -quit | grep -q .
  configure_fish_starship
  configure_fish_starship
  [[ "$(grep -Fc '# >>> linux-bootstrap starship >>>' "$XDG_CONFIG_HOME/fish/config.fish")" == 1 ]]
  grep -Fq 'fish_add_path --global "$HOME/.local/bin"' "$XDG_CONFIG_HOME/fish/config.fish"
  mkdir -p "$XDG_CONFIG_HOME"
  printf 'existing = true\n' > "$XDG_CONFIG_HOME/starship.toml"
  configure_starship_preset nerd-font-symbols
  grep -Fq '# Generated by linux-bootstrap: nerd-font-symbols' "$XDG_CONFIG_HOME/starship.toml"
  find "$XDG_CONFIG_HOME" -maxdepth 1 -name 'starship.toml.bootstrap-backup-*' -type f -print -quit | grep -q .
  mkdir -p "$HOME/.cache/spotify-player"
  printf '{}\n' > "$HOME/.cache/spotify-player/user_client_token.json"
  printf '{}\n' > "$HOME/.cache/spotify-player/credentials.json"
  configuration_is_complete upstream-spotify-auth
)

DOTFILES_TEST_HOME="$TEST_ROOT/dotfiles-home"
DOTFILES_TEST_REPO="$TEST_ROOT/dotfiles-repository"
mkdir -p "$DOTFILES_TEST_HOME/.config/fish" "$DOTFILES_TEST_HOME/.config/lazygit" "$DOTFILES_TEST_HOME/.config/micro/colorschemes" "$DOTFILES_TEST_HOME/.config/micro/plug/lsp" "$DOTFILES_TEST_HOME/.config"
printf 'set -g fish_greeting\n' > "$DOTFILES_TEST_HOME/.config/fish/config.fish"
printf 'gui:\n  nerdFontsVersion: "3"\n' > "$DOTFILES_TEST_HOME/.config/lazygit/config.yml"
printf '{"colorscheme":"catppuccin-mocha"}\n' > "$DOTFILES_TEST_HOME/.config/micro/settings.json"
printf '{"CtrlP":"command:palettero"}\n' > "$DOTFILES_TEST_HOME/.config/micro/bindings.json"
printf 'color-link default "#cdd6f4,#1e1e2e"\n' > "$DOTFILES_TEST_HOME/.config/micro/colorschemes/catppuccin-mocha.micro"
printf '{}\n' > "$DOTFILES_TEST_HOME/.config/micro/plug/lsp/repo.json"
printf '{}\n' > "$DOTFILES_TEST_HOME/.config/micro/settings.json.bootstrap-backup-test"
printf 'password = "must-not-import"\n' > "$DOTFILES_TEST_HOME/.config/starship.toml"
mkdir -p "$DOTFILES_TEST_HOME/.config/superfile"
for n in $(seq 1 200); do printf 'password=x\n' > "$DOTFILES_TEST_HOME/.config/superfile/secret-$n"; done
preview="$(HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles import)"
grep -q 'WOULD.*fish-config' <<<"$preview"
grep -q 'WOULD.*micro-settings' <<<"$preview"
grep -q 'WOULD.*micro-bindings' <<<"$preview"
grep -q 'WOULD.*micro-colorschemes' <<<"$preview"
grep -q 'BLOCKED.*starship' <<<"$preview"
grep -q 'BLOCKED.*superfile' <<<"$preview"
[[ ! -e "$DOTFILES_TEST_REPO" ]]
HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles import --apply >/dev/null
[[ -L "$DOTFILES_TEST_HOME/.config/fish/config.fish" ]]
[[ -f "$DOTFILES_TEST_REPO/config/fish/config.fish" ]]
[[ -f "$DOTFILES_TEST_REPO/config/lazygit/config.yml" ]]
[[ -L "$DOTFILES_TEST_HOME/.config/micro/settings.json" ]]
[[ -L "$DOTFILES_TEST_HOME/.config/micro/bindings.json" ]]
[[ -L "$DOTFILES_TEST_HOME/.config/micro/colorschemes" ]]
[[ -f "$DOTFILES_TEST_REPO/config/micro/settings.json" ]]
[[ -f "$DOTFILES_TEST_REPO/config/micro/bindings.json" ]]
[[ -f "$DOTFILES_TEST_REPO/config/micro/colorschemes/catppuccin-mocha.micro" ]]
[[ ! -e "$DOTFILES_TEST_REPO/config/micro/plug" ]]
[[ ! -e "$DOTFILES_TEST_REPO/config/micro/settings.json.bootstrap-backup-test" ]]
[[ ! -e "$DOTFILES_TEST_REPO/config/starship.toml" ]]
[[ ! -e "$DOTFILES_TEST_REPO/config/superfile" ]]
git -C "$DOTFILES_TEST_REPO" config user.name 'Linux Bootstrap Test'
git -C "$DOTFILES_TEST_REPO" config user.email 'bootstrap-test@example.invalid'
git -C "$DOTFILES_TEST_REPO" add --all
git -C "$DOTFILES_TEST_REPO" commit -m initial >/dev/null
DOTFILES_TEST_REMOTE="$TEST_ROOT/dotfiles-remote.git"
git init --bare --initial-branch=main "$DOTFILES_TEST_REMOTE" >/dev/null
git -C "$DOTFILES_TEST_REPO" remote add origin "$DOTFILES_TEST_REMOTE"
printf 'password=already-present\n' > "$DOTFILES_TEST_REPO/manual-secret.txt"
printf 'gui:\n  nerdFontsVersion: "2"\n' > "$DOTFILES_TEST_HOME/.config/lazygit/config.yml"
if HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles sync >/dev/null 2>&1; then
  printf 'Sensitive repository unexpectedly synchronized.\n' >&2
  exit 1
fi
grep -Fq 'nerdFontsVersion: "3"' "$DOTFILES_TEST_REPO/config/lazygit/config.yml"
rm "$DOTFILES_TEST_REPO/manual-secret.txt"
printf 'gui:\n  nerdFontsVersion: "3"\n' > "$DOTFILES_TEST_HOME/.config/lazygit/config.yml"
HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles sync >/dev/null
printf 'set -g fish_greeting hello\n' > "$DOTFILES_TEST_HOME/.config/fish/config.fish"
grep -Fq 'hello' "$DOTFILES_TEST_REPO/config/fish/config.fish"
HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles sync >/dev/null
git --git-dir="$DOTFILES_TEST_REMOTE" show HEAD:config/fish/config.fish | grep -Fq hello
status_output="$(HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles status)"
grep -q 'linked.*fish-config' <<<"$status_output"
rm "$DOTFILES_TEST_HOME/.config/fish/config.fish"
ln -s "$TEST_ROOT/missing-fish-config" "$DOTFILES_TEST_HOME/.config/fish/config.fish"
status_output="$(HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles status)"
grep -q 'untracked.*fish-config' <<<"$status_output"
rm "$DOTFILES_TEST_HOME/.config/fish/config.fish"
ln -s "$DOTFILES_TEST_REPO/config/fish/config.fish" "$DOTFILES_TEST_HOME/.config/fish/config.fish"
HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles restore --apply >/dev/null
[[ ! -L "$DOTFILES_TEST_HOME/.config/fish/config.fish" ]]
grep -Fq 'set -g fish_greeting' "$DOTFILES_TEST_HOME/.config/fish/config.fish"

BROKEN_RESTORE="$DOTFILES_TEST_HOME/.local/state/linux-bootstrap/dotfiles/backups/99999999-999999-restore-test"
mkdir -p "$BROKEN_RESTORE/files"
printf 'apply\n' > "$BROKEN_RESTORE/operation"
printf 'original backup\n' > "$BROKEN_RESTORE/files/available"
printf 'current target\n' > "$TEST_ROOT/restore-target-one"
printf 'second target\n' > "$TEST_ROOT/restore-target-two"
printf '%s\t%s\n%s\t%s\n' \
  "$TEST_ROOT/restore-target-one" "$BROKEN_RESTORE/files/available" \
  "$TEST_ROOT/restore-target-two" "$BROKEN_RESTORE/files/missing" > "$BROKEN_RESTORE/manifest.tsv"
if HOME="$DOTFILES_TEST_HOME" LINUX_BOOTSTRAP_DOTFILES_DIR="$DOTFILES_TEST_REPO" "$ROOT_DIR/setup.sh" --dotfiles restore --apply >/dev/null 2>&1; then
  printf 'Incomplete backup unexpectedly restored.\n' >&2
  exit 1
fi
grep -Fxq 'current target' "$TEST_ROOT/restore-target-one"
grep -Fxq 'original backup' "$BROKEN_RESTORE/files/available"
[[ ! -e "$BROKEN_RESTORE/.restored" ]]

UNIT_HOME="$TEST_ROOT/unit-home"
UNIT_REPO="$TEST_ROOT/dotfiles repository with spaces"
UNIT_CONFIG="$TEST_ROOT/config directory with spaces"
UNIT_BIN="$TEST_ROOT/unit-bin"
mkdir -p "$UNIT_HOME" "$UNIT_CONFIG/systemd/user" "$UNIT_BIN"
git init -b main "$UNIT_REPO" >/dev/null
git -C "$UNIT_REPO" remote add origin "$DOTFILES_TEST_REMOTE"
printf 'original service\n' > "$UNIT_CONFIG/systemd/user/linux-bootstrap-dotfiles-sync.service"
printf 'original timer\n' > "$UNIT_CONFIG/systemd/user/linux-bootstrap-dotfiles-sync.timer"
printf '#!/usr/bin/env sh\nexit 0\n' > "$UNIT_BIN/systemctl"
chmod +x "$UNIT_BIN/systemctl"
HOME="$UNIT_HOME" XDG_CONFIG_HOME="$UNIT_CONFIG" PATH="$UNIT_BIN:$PATH" LINUX_BOOTSTRAP_DOTFILES_DIR="$UNIT_REPO" "$ROOT_DIR/setup.sh" --dotfiles enable-auto --apply >/dev/null
grep -Fq "Environment=\"LINUX_BOOTSTRAP_DOTFILES_DIR=$UNIT_REPO\"" "$UNIT_CONFIG/systemd/user/linux-bootstrap-dotfiles-sync.service"
grep -Fq 'original service' "$UNIT_HOME/.local/state/linux-bootstrap/dotfiles/backups/"*/files/systemd/service
grep -Fq 'original timer' "$UNIT_HOME/.local/state/linux-bootstrap/dotfiles/backups/"*/files/systemd/timer

printf 'All Linux Bootstrap tests passed.\n'

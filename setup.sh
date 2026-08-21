#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
ASSUME_YES=false
FULLSCREEN=true
CLASSIC_UI=false
CONFIGURE_ONLY=false
DOTFILES_ACTION=""
DOTFILES_APPLY=false
PLAN_FILE=""
SAVE_PLAN=""
VALIDATE_ONLY=false
DOCTOR_ONLY=false
RETRY_FAILED=false

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --yes) ASSUME_YES=true ;;
    --no-fullscreen) FULLSCREEN=false ;;
    --classic) CLASSIC_UI=true ;;
    --configure) CONFIGURE_ONLY=true ;;
    --plan)
      (($# >= 2)) || { printf '%s\n' 'Missing file after --plan.' >&2; exit 2; }
      PLAN_FILE="$2"
      shift
      ;;
    --save-plan)
      (($# >= 2)) || { printf '%s\n' 'Missing file after --save-plan.' >&2; exit 2; }
      SAVE_PLAN="$2"
      shift
      ;;
    --validate) VALIDATE_ONLY=true ;;
    --doctor) DOCTOR_ONLY=true ;;
    --retry-failed) RETRY_FAILED=true ;;
    --dotfiles)
      (($# >= 2)) || { printf '%s\n' 'Missing action after --dotfiles.' >&2; exit 2; }
      DOTFILES_ACTION="$2"
      shift
      ;;
    --apply) DOTFILES_APPLY=true ;;
    -h|--help)
      printf 'Usage: %s [--dry-run] [--yes] [--no-fullscreen] [--classic] [--configure] [--plan FILE] [--save-plan FILE] [--validate] [--doctor] [--retry-failed]\n' "$0"
      printf '       %s --dotfiles {import|apply|status|restore|sync|enable-auto|disable-auto} [--apply] [--dry-run]\n' "$0"
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DOCTOR_ONLY" == true && "$RETRY_FAILED" == true ]]; then
  printf '%s\n' '--doctor and --retry-failed cannot be combined.' >&2
  exit 2
fi
if [[ -n "$DOTFILES_ACTION" && ( "$VALIDATE_ONLY" == true || "$DOCTOR_ONLY" == true || "$RETRY_FAILED" == true || -n "$PLAN_FILE" ) ]]; then
  printf '%s\n' '--dotfiles cannot be combined with validation, doctor, retry, or plan modes.' >&2
  exit 2
fi
if [[ "$VALIDATE_ONLY" == true && ( "$DOCTOR_ONLY" == true || "$RETRY_FAILED" == true || -n "$PLAN_FILE" ) ]]; then
  printf '%s\n' '--validate must run as a standalone maintenance mode.' >&2
  exit 2
fi

# shellcheck source=lib/detect.sh
source "$ROOT_DIR/lib/detect.sh"
# shellcheck source=lib/ui.sh
source "$ROOT_DIR/lib/ui.sh"
# shellcheck source=lib/installers.sh
source "$ROOT_DIR/lib/installers.sh"
# shellcheck source=services/services.sh
source "$ROOT_DIR/services/services.sh"
# shellcheck source=external/installers.sh
source "$ROOT_DIR/external/installers.sh"
# shellcheck source=external/status.sh
source "$ROOT_DIR/external/status.sh"
# shellcheck source=configurations/configurations.sh
source "$ROOT_DIR/configurations/configurations.sh"
# shellcheck source=dotfiles/dotfiles.sh
source "$ROOT_DIR/dotfiles/dotfiles.sh"
# shellcheck source=lib/validate.sh
source "$ROOT_DIR/lib/validate.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT_DIR/lib/doctor.sh"

BOOTSTRAP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || printf unknown)"
REPORT_FILE="${LOG_FILE%.log}.report.txt"
BOOTSTRAP_FINISHED=false
CURRENT_STEP="startup"
declare -a TEMP_ARTIFACTS=() REPORT_INSTALLED=() REPORT_PRESENT=() REPORT_SKIPPED=() REPORT_FAILED=() REPORT_DETAILS=()
LAST_FAILURES_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/linux-bootstrap/last-failures.tsv"

report_add() {
  local bucket="$1" value="$2" existing
  local -n destination="$bucket"
  for existing in "${destination[@]}"; do [[ "$existing" == "$value" ]] && return 0; done
  destination+=("$value")
}
report_section() {
  local title="$1" bucket="$2" item
  local -n values="$bucket"
  printf '%s (%d)\n' "$title" "${#values[@]}"
  if ((${#values[@]} == 0)); then printf '  - none\n'; return; fi
  for item in "${values[@]}"; do printf '  - %s\n' "$item"; done
}

save_failure_state() {
  local preserve_empty="${1:-false}" failure temporary retryable=0
  [[ "$DRY_RUN" != true ]] || return 0
  mkdir -p "$(dirname "$LAST_FAILURES_FILE")"
  temporary="${LAST_FAILURES_FILE}.partial.$$"
  {
    printf 'FORMAT\t1\nFAMILY\t%s\nPROFILE\t%s\n' "$DISTRO_FAMILY" "${profile:-$PROFILE_HINT}"
    for failure in "${REPORT_FAILED[@]}"; do
      case "$failure" in
        package:*|external:*|service:*|config:*) printf 'FAILURE\t%s\n' "$failure"; ((retryable+=1)) ;;
      esac
    done
  } > "$temporary"
  if ((retryable)); then chmod 0600 "$temporary"; mv "$temporary" "$LAST_FAILURES_FILE"
  elif [[ "$preserve_empty" == true ]]; then rm -f "$temporary"
  else rm -f "$temporary" "$LAST_FAILURES_FILE"
  fi
}

record_external_detail() {
  local app="$1" version
  version="$(external_installed_version "$app")"
  report_add REPORT_DETAILS "external:$app · $(external_install_method "$app") · $(external_install_source "$app") · ${version:-version unknown}"
}

register_temp_artifact() { TEMP_ARTIFACTS+=("$1"); }
unregister_temp_artifact() {
  local target="$1" item
  local -a kept=()
  for item in "${TEMP_ARTIFACTS[@]}"; do [[ "$item" == "$target" ]] || kept+=("$item"); done
  TEMP_ARTIFACTS=("${kept[@]}")
}
cleanup_temp_artifacts() {
  local item
  for item in "${TEMP_ARTIFACTS[@]}"; do
    case "$item" in
      "${TMPDIR:-/tmp}"/linux-bootstrap-*|"$HOME"/.cache/linux-bootstrap/*.partial.*)
        if [[ -d "$item" ]]; then find "$item" -depth -delete 2>/dev/null || true
        else rm -f -- "$item" 2>/dev/null || true
        fi
        ;;
    esac
  done
}
print_final_report() {
  local heading="Installed/configured"
  [[ "$DRY_RUN" == true ]] && heading="Planned"
  {
    printf '\n=== Bootstrap report · v%s ===\n' "$BOOTSTRAP_VERSION"
    report_section "$heading" REPORT_INSTALLED
    report_section "Already present" REPORT_PRESENT
    report_section "Skipped" REPORT_SKIPPED
    report_section "Failed" REPORT_FAILED
    report_section "Details" REPORT_DETAILS
    printf 'Log: %s\n' "$LOG_FILE"
    printf 'Saved report: %s\n' "$REPORT_FILE"
  } | tee "$REPORT_FILE"
}
finish_bootstrap() {
  BOOTSTRAP_FINISHED=true
  cleanup_temp_artifacts
  save_failure_state
  print_final_report
  if ((${#REPORT_FAILED[@]})); then
    ui_warn "Bootstrap completed with failures. See the report and log above."
    return 1
  else ui_success "Bootstrap complete."
  fi
}
bootstrap_exit() {
  local status=$?
  ui_screen_stop 2>/dev/null || true
  cleanup_temp_artifacts
  if ((status != 0)) && [[ "$BOOTSTRAP_FINISHED" != true ]]; then
    report_add REPORT_FAILED "$CURRENT_STEP"
    save_failure_state true
    printf '\nBootstrap incomplete during: %s\n' "$CURRENT_STEP" >&2
    print_final_report >&2
  fi
}
trap bootstrap_exit EXIT

attempt_step() {
  local status
  set +e
  (trap 'exit $?' ERR; set -Eeuo pipefail; "$@")
  status=$?
  set -e
  return "$status"
}

run_execution_preflight() {
  local manager available_kib
  manager="$(case "$DISTRO_FAMILY" in arch) printf pacman;; debian) printf apt-get;; fedora) printf dnf;; suse) printf zypper;; esac)"
  command -v "$manager" >/dev/null 2>&1 || die "Preflight failed: package manager '$manager' is unavailable."
  if ((EUID != 0)) && ! command -v sudo >/dev/null 2>&1; then
    die "Preflight failed: root access is required, but sudo is unavailable."
  fi
  case "$(uname -m)" in x86_64|amd64|aarch64|arm64) ;; *) ui_warn "Architecture $(uname -m) has limited external-app coverage.";; esac
  available_kib="$(df -Pk "$ROOT_DIR" | awk 'NR==2 {print $4}')"
  [[ "$available_kib" =~ ^[0-9]+$ ]] || die "Preflight failed: free disk space could not be determined."
  ((available_kib >= 524288)) || die "Preflight failed: less than 512 MiB of free disk space remains."
  if command -v getent >/dev/null 2>&1 && ! getent hosts github.com >/dev/null 2>&1; then
    ui_warn "Preflight could not resolve github.com; repository packages may work, but external downloads will likely fail."
  fi
}

install_and_record_packages() {
  local family="$1" pkg
  shift
  local -a missing=()
  for pkg in "$@"; do
    if is_package_installed "$family" "$pkg"; then report_add REPORT_PRESENT "$pkg"
    else missing+=("$pkg")
    fi
  done
  ((${#missing[@]})) || return 0
  if [[ "$DRY_RUN" == true ]]; then
    install_packages "$family" "${missing[@]}"
    for pkg in "${missing[@]}"; do report_add REPORT_INSTALLED "$pkg"; done
    return 0
  fi
  attempt_step install_packages "$family" "${missing[@]}" || true
  for pkg in "${missing[@]}"; do
    if is_package_installed "$family" "$pkg"; then report_add REPORT_INSTALLED "$pkg"
    else report_add REPORT_FAILED "package:$pkg"
    fi
  done
}

install_and_record_external() {
  local app="$1"
  if external_is_installed "$app"; then report_add REPORT_PRESENT "$app"; record_external_detail "$app"; return 0; fi
  if [[ "$DRY_RUN" == true ]]; then
    install_external "$app"
    report_add REPORT_INSTALLED "$app"
    report_add REPORT_DETAILS "external:$app · $(external_install_method "$app") · $(external_install_source "$app") · planned"
  elif attempt_step install_external "$app" && external_is_installed "$app"; then
    report_add REPORT_INSTALLED "$app"
    record_external_detail "$app"
  else
    report_add REPORT_FAILED "external:$app"
  fi
}

install_external_dependencies_and_record() {
  (($#)) || return 0
  local -a dependencies=()
  mapfile -t dependencies < <(external_dependency_packages "$@")
  ((${#dependencies[@]})) || return 0
  ui_success "Dependency plan: ${dependencies[*]}"
  install_and_record_packages "$DISTRO_FAMILY" "${dependencies[@]}"
}

service_is_active() {
  local service="$1" unit="$1"
  [[ "$service" == tailscale ]] && unit=tailscaled
  [[ "$service" == ssh && "$DISTRO_FAMILY" == debian ]] && unit=ssh
  [[ "$service" == ssh && "$DISTRO_FAMILY" != debian ]] && unit=sshd
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$unit"
}

install_and_record_service() {
  local service="$1"
  if service_is_active "$service"; then report_add REPORT_PRESENT "service:$service"; return 0; fi
  if [[ "$DRY_RUN" == true ]]; then
    "setup_${service}"
    report_add REPORT_INSTALLED "service:$service"
  elif attempt_step "setup_${service}" && service_is_active "$service"; then
    report_add REPORT_INSTALLED "service:$service"
  else
    report_add REPORT_FAILED "service:$service"
  fi
}

apply_and_record_configuration() {
  local configuration="$1" status
  if configuration_is_complete "$configuration"; then
    report_add REPORT_PRESENT "config:$configuration"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    apply_configuration "$configuration"
    report_add REPORT_INSTALLED "config:$configuration"
    return 0
  fi
  if attempt_step apply_configuration "$configuration"; then status=0; else status=$?; fi
  if ((status == 10)); then
    report_add REPORT_SKIPPED "config:$configuration (confirmation declined)"
  elif ((status == 0)) && configuration_is_complete "$configuration"; then
    report_add REPORT_INSTALLED "config:$configuration"
  else
    report_add REPORT_FAILED "config:$configuration"
  fi
}

load_selection_file() {
  local selection_path="$1" kind value pkg app configuration declared_family=""
  [[ -r "$selection_path" ]] || die "Cannot read installation plan: $selection_path"
  profile=""
  selected_packages=()
  external_apps=()
  services=()
  configurations=()
  present_packages=()
  present_external=()
  while IFS='=' read -r kind value; do
    [[ -n "$kind" && "$kind" != \#* ]] || continue
    case "$kind" in
      FORMAT) [[ "$value" == 1 ]] || die "Unsupported plan format '$value'." ;;
      FAMILY) declared_family="$value" ;;
      PROFILE)
        [[ "$value" =~ ^(desktop|server)$ ]] || die "Invalid profile in installation plan."
        profile="$value"
        ;;
      PACKAGE)
        [[ "$value" =~ ^[a-zA-Z0-9@._+:-]+$ ]] || die "Invalid package in installation plan."
        selected_packages+=("$value")
        ;;
      PRESENT_PACKAGE) present_packages+=("$value") ;;
      EXTERNAL)
        [[ "$value" =~ ^[a-z0-9-]+$ ]] || die "Invalid external application in installation plan."
        external_apps+=("$value")
        ;;
      PRESENT_EXTERNAL) present_external+=("$value") ;;
      SERVICE)
        [[ "$value" =~ ^(tailscale|docker|ssh)$ ]] || die "Invalid service in installation plan."
        services+=("$value")
        ;;
      CONFIG)
        [[ "$value" =~ ^[a-z0-9-]+$ ]] || die "Invalid configuration task in installation plan."
        configurations+=("$value")
        ;;
      *) die "Unknown installation plan field '$kind'." ;;
    esac
  done < "$selection_path"
  [[ -n "$profile" ]] || die "The installation plan does not declare a profile."
  [[ -z "$declared_family" || "$declared_family" == "$DISTRO_FAMILY" ]] || die "This plan targets $declared_family, but this machine is $DISTRO_FAMILY."

  declare -A allowed_packages=()
  while IFS= read -r pkg; do allowed_packages["$pkg"]=1; done < <(profile_packages "$DISTRO_FAMILY" "$profile")
  for pkg in "${selected_packages[@]}"; do
    [[ -n "${allowed_packages[$pkg]:-}" ]] || die "Package '$pkg' is not part of $DISTRO_FAMILY/$profile."
    if [[ -n "${AVAILABILITY_FILE:-}" ]] && grep -q $'^PACKAGE\t'"$pkg"$'\t' "$AVAILABILITY_FILE"; then
      die "Package '$pkg' is unavailable in the enabled repositories."
    fi
  done
  declare -A allowed_external=()
  while IFS= read -r app; do allowed_external["$app"]=1; done < <(external_automated_ids_for_profile "$profile")
  for app in "${external_apps[@]}"; do
    [[ -n "${allowed_external[$app]:-}" ]] || die "External application '$app' is unknown, manual-only, or unavailable for the $profile profile."
    if [[ -n "${AVAILABILITY_FILE:-}" ]] && grep -q $'^EXTERNAL\t'"$app"$'\t' "$AVAILABILITY_FILE"; then
      die "External application '$app' has unavailable repository dependencies."
    fi
  done
  declare -A allowed_configurations=()
  while IFS= read -r configuration; do allowed_configurations["$configuration"]=1; done < <(configuration_catalog_ids)
  for configuration in "${configurations[@]}"; do
    [[ -n "${allowed_configurations[$configuration]:-}" ]] || die "Unknown configuration task '$configuration'."
  done
  validate_configuration_selection "${configurations[@]}"
}

save_selection_plan() {
  local source="$1" plan_destination="$2" temporary
  [[ "$plan_destination" != *$'\n'* ]] || die "Plan paths cannot contain newlines."
  mkdir -p "$(dirname "$plan_destination")"
  temporary="${plan_destination}.partial.$$"
  {
    printf 'FORMAT=1\nFAMILY=%s\n' "$DISTRO_FAMILY"
    awk -F= '!/^(FORMAT|FAMILY)=/ {print $1 "=" $2}' "$source"
  } > "$temporary"
  chmod 0600 "$temporary"
  mv "$temporary" "$plan_destination"
}

execute_loaded_selection() {
  local item app service configuration
  [[ "$CONFIGURE_ONLY" == true ]] || run_execution_preflight
  for item in "${present_packages[@]}" "${present_external[@]}"; do [[ -n "$item" ]] && report_add REPORT_PRESENT "$item"; done
  if [[ "$CONFIGURE_ONLY" != true ]]; then
    if ((${#selected_packages[@]})); then
      CURRENT_STEP="official repository packages"
      install_and_record_packages "$DISTRO_FAMILY" "${selected_packages[@]}"
    else
      ui_warn "No packages selected."
      report_add REPORT_SKIPPED "official repository packages (none selected)"
    fi
    CURRENT_STEP="external dependency plan"
    install_external_dependencies_and_record "${external_apps[@]}"
    for app in "${external_apps[@]}"; do
      CURRENT_STEP="external application: $app"
      install_and_record_external "$app"
    done
    for service in "${services[@]}"; do
      CURRENT_STEP="service: $service"
      install_and_record_service "$service"
    done
  fi
  for configuration in "${configurations[@]}"; do
    CURRENT_STEP="configuration: $configuration"
    apply_and_record_configuration "$configuration"
  done
  ((${#configurations[@]})) || report_add REPORT_SKIPPED "application configuration (none selected)"
  finish_bootstrap
}

detect_platform
PROFILE_HINT="$(detect_profile_hint)"

case "$DISTRO_FAMILY" in
  nixos) die "NixOS needs the planned declarative module-generator backend; no imperative changes were made." ;;
  immutable) die "Immutable/OSTree systems need a dedicated backend; no changes were made." ;;
  unsupported) die "Unsupported distribution: $DISTRO_PRETTY" ;;
esac

if [[ -n "$DOTFILES_ACTION" ]]; then
  run_dotfiles_action "$DOTFILES_ACTION"
  exit 0
fi

validate_catalog_structure || die "Installer catalog validation failed: ${VALIDATION_ERRORS[*]}"
AVAILABILITY_FILE="$(mktemp "${TMPDIR:-/tmp}/linux-bootstrap-availability.XXXXXX")"
register_temp_artifact "$AVAILABILITY_FILE"
build_availability_report "$AVAILABILITY_FILE" "$DISTRO_FAMILY"
if [[ "$VALIDATE_ONLY" == true ]]; then
  validation_status=0
  print_validation_report "$AVAILABILITY_FILE" || validation_status=$?
  BOOTSTRAP_FINISHED=true
  cleanup_temp_artifacts
  exit "$validation_status"
fi

if [[ "$RETRY_FAILED" == true ]]; then
  [[ -z "$PLAN_FILE" ]] || die "--retry-failed and --plan cannot be combined."
  retry_last_failures
  exit 0
fi

if [[ "$DOCTOR_ONLY" == true ]]; then
  doctor_plan="$PLAN_FILE"
  [[ -n "$doctor_plan" ]] || doctor_plan="${XDG_STATE_HOME:-$HOME/.local/state}/linux-bootstrap/last-plan.conf"
  load_selection_file "$doctor_plan"
  run_doctor
  BOOTSTRAP_FINISHED=true
  cleanup_temp_artifacts
  exit 0
fi

if [[ -n "$PLAN_FILE" ]]; then
  [[ "$CONFIGURE_ONLY" != true ]] || die "--plan and --configure cannot be combined."
  load_selection_file "$PLAN_FILE"
  [[ -z "$SAVE_PLAN" ]] || save_selection_plan "$PLAN_FILE" "$SAVE_PLAN"
  execute_loaded_selection
  exit 0
fi

TUI_BIN="${LINUX_BOOTSTRAP_TUI:-$ROOT_DIR/bin/linux-bootstrap-tui}"
if [[ "$CLASSIC_UI" == false && "$ASSUME_YES" == false && "$FULLSCREEN" == true && -t 0 && -t 1 && -x "$TUI_BIN" ]]; then
  selection_file="$(mktemp "${TMPDIR:-/tmp}/linux-bootstrap-selection.XXXXXX")"
  tui_args=(--root "$ROOT_DIR" --family "$DISTRO_FAMILY" --pretty "$DISTRO_PRETTY" --default-profile "$PROFILE_HINT" --output "$selection_file")
  tui_args+=(--availability "$AVAILABILITY_FILE")
  LAST_PLAN_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/linux-bootstrap/last-plan.conf"
  [[ -r "$LAST_PLAN_FILE" ]] && tui_args+=(--last-plan "$LAST_PLAN_FILE")
  [[ "$CONFIGURE_ONLY" == true ]] && tui_args+=(--configure-only)
  if "$TUI_BIN" "${tui_args[@]}"; then
    save_selection_plan "$selection_file" "$LAST_PLAN_FILE"
    [[ -z "$SAVE_PLAN" ]] || save_selection_plan "$selection_file" "$SAVE_PLAN"
    load_selection_file "$selection_file"
    rm -f "$selection_file"
    execute_loaded_selection
    exit 0
  else
    tui_status=$?
    rm -f "$selection_file"
    if ((tui_status == 130)); then printf 'Installation cancelled.\n'; exit 0; fi
    ui_warn "The full TUI could not start; falling back to the classic interface."
  fi
fi

if [[ "$CONFIGURE_ONLY" == true ]]; then
  ui_screen_start
  trap bootstrap_exit EXIT
  ui_banner
  printf 'Version: %s\nDetected: %s (%s)\nMode: configuration only\n\n' "$BOOTSTRAP_VERSION" "$DISTRO_PRETTY" "$DISTRO_FAMILY"
  mapfile -t available_configurations < <(available_configuration_ids)
  if ((${#available_configurations[@]})); then
    if [[ "$ASSUME_YES" == true ]]; then
      configurations=()
      command -v fish >/dev/null 2>&1 && command -v starship >/dev/null 2>&1 && configurations+=(fish-starship)
      report_add REPORT_SKIPPED "sensitive and replacement configuration (requires interactive selection)"
    else
      mapfile -t configurations < <(ui_choose_many "Select application configuration tasks" "${available_configurations[@]}")
      validate_configuration_selection "${configurations[@]}"
    fi
    for configuration in "${configurations[@]}"; do
      CURRENT_STEP="configuration: $configuration"
      apply_and_record_configuration "$configuration"
    done
    ((${#configurations[@]})) || report_add REPORT_SKIPPED "application configuration (none selected)"
  else
    report_add REPORT_SKIPPED "application configuration (no supported installed applications)"
  fi
  ui_screen_stop
  finish_bootstrap
  exit 0
fi

ui_screen_start
trap bootstrap_exit EXIT
ui_banner
printf 'Version: %s\nDetected: %s (%s)\n\n' "$BOOTSTRAP_VERSION" "$DISTRO_PRETTY" "$DISTRO_FAMILY"

case "$DISTRO_FAMILY" in
  arch) profile="$(ui_choose_one "Choose an Arch profile (detected: $PROFILE_HINT)" "$PROFILE_HINT" desktop server)" ;;
  debian|fedora|suse) profile="$(ui_choose_one "Choose a $DISTRO_FAMILY profile (detected: $PROFILE_HINT)" "$PROFILE_HINT" desktop server)" ;;
  *) die "Supported families: Arch, Debian/Ubuntu, Fedora/RHEL, and openSUSE." ;;
esac
printf 'Active profile: %s\n\n' "$profile"
run_execution_preflight

mapfile -t available_packages < <(profile_packages "$DISTRO_FAMILY" "$profile")
missing_packages=()
for pkg in "${available_packages[@]}"; do
  if is_package_installed "$DISTRO_FAMILY" "$pkg"; then REPORT_PRESENT+=("$pkg")
  else missing_packages+=("$pkg")
  fi
done
available_packages=("${missing_packages[@]}")
selection_mode="$(ui_choose_one "Install all packages or choose individual packages?" all all individual)"

if [[ "$selection_mode" == individual ]]; then
  mapfile -t selected_packages < <(ui_choose_many "Select individual packages" "${available_packages[@]}")
  if ((${#selected_packages[@]} == 0)); then
    ui_warn "No packages selected."
  else
    CURRENT_STEP="official repository packages"
    install_and_record_packages "$DISTRO_FAMILY" "${selected_packages[@]}"
  fi
else
  selected_packages=("${available_packages[@]}")
  CURRENT_STEP="official repository packages"
  install_and_record_packages "$DISTRO_FAMILY" "${selected_packages[@]}"
fi

if [[ "$ASSUME_YES" != true ]] && ui_confirm "Install external applications or Nerd Fonts?" "no"; then
  mapfile -t available_external < <(external_automated_ids_for_profile "$profile")
  declare -A selected_official=()
  for pkg in "${selected_packages[@]}"; do selected_official["$pkg"]=1; done
  filtered_external=()
  for app in "${available_external[@]}"; do
    if external_is_installed "$app"; then REPORT_PRESENT+=("$app")
    elif [[ -n "${selected_official[$app]:-}" ]]; then REPORT_SKIPPED+=("$app (official selection)")
    else filtered_external+=("$app")
    fi
  done
  mapfile -t selected_external < <(ui_choose_many "Select external applications" "${filtered_external[@]}")
  CURRENT_STEP="external dependency plan"
  install_external_dependencies_and_record "${selected_external[@]}"
  for app in "${selected_external[@]}"; do
    CURRENT_STEP="external application: $app"
    install_and_record_external "$app"
  done
else
  report_add REPORT_SKIPPED "external applications (not requested)"
fi

if [[ "$ASSUME_YES" != true ]] && ui_confirm "Configure optional services?" "no"; then
  mapfile -t services < <(ui_choose_many "Select services" tailscale docker ssh)
  for service in "${services[@]}"; do
    CURRENT_STEP="service: $service"
    install_and_record_service "$service"
  done
else
  report_add REPORT_SKIPPED "optional services (not requested)"
fi

if [[ "$ASSUME_YES" != true ]] && ui_confirm "Configure installed applications?" "no"; then
  mapfile -t available_configurations < <(available_configuration_ids)
  if ((${#available_configurations[@]})); then
    mapfile -t configurations < <(ui_choose_many "Select application configuration tasks" "${available_configurations[@]}")
    validate_configuration_selection "${configurations[@]}"
    for configuration in "${configurations[@]}"; do
      CURRENT_STEP="configuration: $configuration"
      apply_and_record_configuration "$configuration"
    done
  else
    report_add REPORT_SKIPPED "application configuration (no supported installed applications)"
  fi
else
  report_add REPORT_SKIPPED "application configuration (not requested)"
fi

ui_screen_stop
finish_bootstrap

#!/usr/bin/env bash

run_doctor() {
  local package app service configuration state missing=0
  printf '\n=== Linux Bootstrap doctor · v%s ===\n' "$BOOTSTRAP_VERSION"
  printf 'Plan: %s / %s\n\n' "$DISTRO_FAMILY" "$profile"
  for package in "${selected_packages[@]}"; do
    if is_package_installed "$DISTRO_FAMILY" "$package"; then state=installed; else state=missing; ((missing+=1)); fi
    printf '%-9s package   %s\n' "$state" "$package"
  done
  for app in "${external_apps[@]}"; do
    if external_is_installed "$app"; then state=installed; else state=missing; ((missing+=1)); fi
    printf '%-9s external  %s\n' "$state" "$app"
    printf '          method: %s\n          source: %s\n' "$(external_install_method "$app")" "$(external_install_source "$app")"
    if [[ "$state" == installed ]]; then
      printf '          version: %s\n' "$(external_installed_version "$app")"
      printf '          update: %s\n' "$(external_status_line "$app" | awk -F '\t' '{print $5}')"
    fi
  done
  for service in "${services[@]}"; do
    if service_is_active "$service"; then state=active; else state=inactive; ((missing+=1)); fi
    printf '%-9s service   %s\n' "$state" "$service"
  done
  for configuration in "${configurations[@]}"; do
    if configuration_is_complete "$configuration"; then state=complete; else state=missing; ((missing+=1)); fi
    printf '%-9s config    %s\n' "$state" "$configuration"
  done
  printf '\nSummary: %d item(s) need attention.\n' "$missing"
}

retry_last_failures() {
  local kind value family="" stored_profile="" failure package app service configuration external_profile external_method
  local -a failures=()
  [[ -r "$LAST_FAILURES_FILE" ]] || die "No retryable failures were saved from the previous run."
  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      FORMAT) [[ "$value" == 1 ]] || die "Unsupported failure-state format '$value'." ;;
      FAMILY) family="$value" ;;
      PROFILE) stored_profile="$value" ;;
      FAILURE) failures+=("$value") ;;
      *) die "Invalid failure-state field '$kind'." ;;
    esac
  done < "$LAST_FAILURES_FILE"
  [[ "$family" == "$DISTRO_FAMILY" ]] || die "The saved failures belong to $family, not $DISTRO_FAMILY."
  [[ "$stored_profile" =~ ^(desktop|server)$ ]] || die "The saved failure state has an invalid profile."
  ((${#failures[@]})) || die "No retryable failures were saved from the previous run."
  profile="$stored_profile"
  run_execution_preflight
  for failure in "${failures[@]}"; do
    kind="${failure%%:*}"
    value="${failure#*:}"
    case "$kind" in
      package)
        [[ "$value" =~ ^[a-zA-Z0-9@._+:-]+$ ]] || die "Invalid saved package failure."
        if grep -q $'^PACKAGE\t'"$value"$'\t' "$AVAILABILITY_FILE"; then
          report_add REPORT_FAILED "$failure"
          report_add REPORT_DETAILS "$failure · still unavailable in enabled repositories"
        else install_and_record_packages "$DISTRO_FAMILY" "$value"
        fi
        ;;
      external)
        [[ "$value" =~ ^[a-z0-9-]+$ ]] || die "Invalid saved external failure."
        external_profile="$(external_field "$value" 3)"
        external_method="$(external_field "$value" 4)"
        [[ "$external_profile" == all || "$external_profile" == "$stored_profile" ]] || die "Saved external failure '$value' is unavailable for $stored_profile."
        [[ -n "$external_method" && "$external_method" != manual ]] || die "Unknown or manual-only saved external failure '$value'."
        if grep -q $'^EXTERNAL\t'"$value"$'\t' "$AVAILABILITY_FILE"; then
          report_add REPORT_FAILED "$failure"
          report_add REPORT_DETAILS "$failure · dependencies still unavailable"
        else
          install_external_dependencies_and_record "$value"
          install_and_record_external "$value"
        fi
        ;;
      service)
        [[ "$value" =~ ^(tailscale|docker|ssh)$ ]] || die "Unknown saved service failure '$value'."
        install_and_record_service "$value"
        ;;
      config)
        [[ -n "$(configuration_field "$value" 1)" ]] || die "Unknown saved configuration failure '$value'."
        apply_and_record_configuration "$value"
        ;;
      *) die "Unknown retryable failure type '$kind'." ;;
    esac
  done
  finish_bootstrap
}

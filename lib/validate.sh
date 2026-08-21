#!/usr/bin/env bash

VALIDATION_WARNINGS=()
VALIDATION_ERRORS=()

validation_add_unique() {
  local bucket="$1" value="$2" existing
  local -n values="$bucket"
  for existing in "${values[@]}"; do [[ "$existing" == "$value" ]] && return 0; done
  values+=("$value")
}

validate_catalog_structure() {
  local file duplicate invalid id
  local -A described=()
  VALIDATION_WARNINGS=()
  VALIDATION_ERRORS=()
  for file in "$ROOT_DIR/external/catalog.tsv" "$ROOT_DIR/configurations/catalog.tsv"; do
    expected_fields=6
    [[ "$file" == */external/catalog.tsv ]] && expected_fields=7
    invalid="$(awk -F '\t' -v expected="$expected_fields" '!/^#/ && NF != expected {print NR}' "$file")"
    [[ -z "$invalid" ]] || validation_add_unique VALIDATION_ERRORS "$(basename "$file"): invalid row(s) $invalid"
    duplicate="$(awk -F '\t' '!/^#/ {count[$1]++} END {for (id in count) if (count[id] > 1) print id}' "$file")"
    [[ -z "$duplicate" ]] || validation_add_unique VALIDATION_ERRORS "$(basename "$file"): duplicate ID(s) ${duplicate//$'\n'/, }"
  done
  invalid="$(awk -F '\t' '!/^#/ && (NF != 7 || $4 !~ /^(symlink|watched-copy|per-host)$/ || $5 !~ /^(all|desktop|niri|kde)$/ || $6 !~ /^(portable|review|machine)$/) {print NR}' "$ROOT_DIR/dotfiles/catalog.tsv")"
  [[ -z "$invalid" ]] || validation_add_unique VALIDATION_ERRORS "dotfiles catalog: invalid row(s) $invalid"

  while IFS= read -r id; do
    [[ -n "$(external_field "$id" 5)" ]] || validation_add_unique VALIDATION_ERRORS "external application '$id' has no description"
    case "$(external_field "$id" 6)" in cmd:*|font:*) ;; *) validation_add_unique VALIDATION_ERRORS "external application '$id' has an invalid detector" ;; esac
    [[ "$(external_field "$id" 7)" == https://github.com/*/* ]] || validation_add_unique VALIDATION_ERRORS "external application '$id' has an invalid source URL"
  done < <(external_catalog_ids)

  while IFS=$'\t' read -r id _; do [[ -n "$id" ]] && described["$id"]=1; done < "$ROOT_DIR/packages/descriptions.tsv"
  local family profile package
  for family in arch debian fedora suse; do
    for profile in desktop server; do
      while IFS= read -r package; do
        [[ -n "${described[$package]:-}" ]] || validation_add_unique VALIDATION_ERRORS "$family/$profile package '$package' has no description"
      done < <(profile_packages "$family" "$profile")
    done
  done
  ((${#VALIDATION_ERRORS[@]} == 0))
}

repository_package_names() {
  case "$1" in
    arch) pacman -Slq 2>/dev/null ;;
    debian) apt-cache pkgnames 2>/dev/null ;;
    fedora) dnf -q --cacheonly repoquery --available --qf '%{name}' 2>/dev/null ;;
    suse) zypper --no-refresh search -s -t package 2>/dev/null | awk -F '|' 'NF >= 3 {gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($2 != "Name") print $2}' ;;
    *) return 1 ;;
  esac
}

installed_package_names() {
  case "$1" in
    arch) pacman -Qq 2>/dev/null ;;
    debian) dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sed 's/:.*//' ;;
    fedora|suse) rpm -qa --qf '%{NAME}\n' 2>/dev/null ;;
    *) return 1 ;;
  esac
}

external_repository_dependencies() {
  local family="$1" app="$2"
  if [[ "$family" == arch && "$app" =~ ^(starship|superfile|fastfetch)$ ]]; then
    printf '%s\n' "$app"
  else
    DISTRO_FAMILY="$family" external_dependency_packages "$app"
  fi
}

build_availability_report() {
  local output="$1" family="$2" available_file package profile app dependency missing id
  local -A repository_available=() installed=()
  : > "$output"
  available_file="${output}.available"
  if ! repository_package_names "$family" | sort -u > "$available_file" || [[ ! -s "$available_file" ]]; then
    printf 'WARNING\trepository\tPackage metadata could not be queried; availability gating was skipped.\n' >> "$output"
    rm -f "$available_file"
    return 0
  fi
  while IFS= read -r package; do [[ -n "$package" ]] && repository_available["$package"]=1; done < "$available_file"
  while IFS= read -r package; do [[ -n "$package" ]] && installed["$package"]=1; done < <(installed_package_names "$family")
  for profile in desktop server; do
    while IFS= read -r package; do
      if [[ -z "${installed[$package]:-}" && -z "${repository_available[$package]:-}" ]]; then
        printf 'PACKAGE\t%s\tUnavailable in enabled %s repositories\n' "$package" "$family" >> "$output"
      fi
    done < <(profile_packages "$family" "$profile")
  done
  while IFS= read -r app; do
    missing=()
    while IFS= read -r dependency; do
      [[ -n "$dependency" ]] || continue
      if [[ -z "${installed[$dependency]:-}" && -z "${repository_available[$dependency]:-}" ]]; then
        missing+=("$dependency")
      fi
    done < <(external_repository_dependencies "$family" "$app")
    if ((${#missing[@]})); then
      printf 'EXTERNAL\t%s\tMissing repository dependencies: %s\n' "$app" "${missing[*]}" >> "$output"
    fi
  done < <(external_catalog_ids)
  rm -f "$available_file"
  sort -u -o "$output" "$output"
}

print_validation_report() {
  local availability="$1" entry blocked=0
  printf '\n=== Linux Bootstrap validation ===\n'
  if validate_catalog_structure; then printf 'PASS  Catalog structure and descriptions\n'
  else
    for entry in "${VALIDATION_ERRORS[@]}"; do printf 'FAIL  %s\n' "$entry"; done
  fi
  if grep -q '^WARNING' "$availability" 2>/dev/null; then
    while IFS=$'\t' read -r _ _ entry; do printf 'WARN  %s\n' "$entry"; done < <(grep '^WARNING' "$availability")
  else
    printf 'PASS  Enabled repository metadata queried\n'
  fi
  while IFS=$'\t' read -r kind id entry; do
    [[ "$kind" == PACKAGE || "$kind" == EXTERNAL ]] || continue
    printf 'BLOCK %-8s %-24s %s\n' "$kind" "$id" "$entry"
    ((blocked+=1))
  done < "$availability"
  ((${#VALIDATION_ERRORS[@]} == 0 && blocked == 0))
}

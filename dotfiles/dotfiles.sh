#!/usr/bin/env bash

DOTFILES_DIR="${LINUX_BOOTSTRAP_DOTFILES_DIR:-$HOME/.local/share/linux-bootstrap/dotfiles}"
DOTFILES_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/linux-bootstrap/dotfiles"
DOTFILES_CATALOG="$ROOT_DIR/dotfiles/catalog.tsv"
DOTFILES_APPLY="${DOTFILES_APPLY:-false}"

dotfiles_host_name() {
  local name
  if command -v hostname >/dev/null 2>&1; then name="$(hostname -s 2>/dev/null || hostname)"
  else name="$(uname -n)"
  fi
  printf '%s\n' "${name%%.*}"
}

dotfiles_expand_path() {
  local value="$1" config_root="${XDG_CONFIG_HOME:-$HOME/.config}" host_name
  host_name="$(dotfiles_host_name)"
  value="${value//\$CONFIG/$config_root}"
  value="${value//\$HOST/$host_name}"
  value="${value//\$HOME/$HOME}"
  printf '%s\n' "$value"
}

dotfiles_scope_active() {
  case "$1" in
    all) return 0 ;;
    desktop) [[ "$(detect_profile_hint)" == desktop ]] ;;
    niri) command -v niri >/dev/null 2>&1 || [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/niri" ]] ;;
    kde) command -v startplasma-wayland >/dev/null 2>&1 || command -v plasmashell >/dev/null 2>&1 || [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/kdeglobals" ]] ;;
    *) return 1 ;;
  esac
}

dotfiles_validate_catalog() {
  local duplicate invalid
  invalid="$(awk -F '\t' '!/^#/ && (NF != 7 || $2 ~ /^\// || $2 ~ /(^|\/)\.\.(\/|$)/ || $4 !~ /^(symlink|watched-copy|per-host)$/ || $5 !~ /^(all|desktop|niri|kde)$/ || $6 !~ /^(portable|review|machine)$/) {print NR}' "$DOTFILES_CATALOG")"
  [[ -z "$invalid" ]] || die "Invalid dotfiles catalog row(s): $invalid"
  duplicate="$(awk -F '\t' '!/^#/ {count[$1]++} END {for (id in count) if (count[id] > 1) print id}' "$DOTFILES_CATALOG")"
  [[ -z "$duplicate" ]] || die "Duplicate dotfiles catalog ID(s): $duplicate"
}

dotfiles_contains_sensitive_data() {
  local target="$1" suspicious content_match
  suspicious="$(find "$target" -path '*/.git' -prune -o -type f \( -name '.env' -o -iname '*credentials*' -o -iname '*token*' -o -name 'id_rsa' -o -name 'id_ed25519' -o -iname '*.kdbx' \) -print -quit 2>/dev/null || true)"
  [[ -z "$suspicious" ]] || { ui_warn "Sensitive-looking filename blocked: $suspicious"; return 0; }
  if [[ -f "$target" ]]; then
    grep -IiqE 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|github_pat_|gh[opsu]_[A-Za-z0-9]|(^|[^a-z])(api[_-]?key|client_secret|oauth_token|access_token|refresh_token|password)[[:space:]]*[:=]' "$target" 2>/dev/null
  elif [[ -d "$target" ]]; then
    content_match="$(grep -IRIlE --exclude-dir=.git 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|github_pat_|gh[opsu]_[A-Za-z0-9]|(^|[^a-z])(api[_-]?key|client_secret|oauth_token|access_token|refresh_token|password)[[:space:]]*[:=]' "$target" 2>/dev/null | sed -n '1p' || true)"
    [[ -n "$content_match" ]]
  else
    return 1
  fi
}

dotfiles_start_backup() {
  local kind="$1"
  [[ -z "${DOTFILES_MANIFEST:-}" ]] || return 0
  DOTFILES_BACKUP_DIR="$DOTFILES_STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)-$$"
  DOTFILES_MANIFEST="$DOTFILES_BACKUP_DIR/manifest.tsv"
  run mkdir -p "$DOTFILES_BACKUP_DIR/files"
  if [[ "$DRY_RUN" != true ]]; then
    : > "$DOTFILES_MANIFEST"
    printf '%s\n' "$kind" > "$DOTFILES_BACKUP_DIR/operation"
  fi
}

dotfiles_backup_existing() {
  local target="$1" id="$2" backup kind="${3:-${DOTFILES_BACKUP_KIND:-change}}"
  dotfiles_start_backup "$kind"
  backup="$DOTFILES_BACKUP_DIR/files/$id"
  if [[ -e "$target" || -L "$target" ]]; then
    run mkdir -p "$(dirname "$backup")"
    run mv "$target" "$backup"
  else
    backup=-
  fi
  [[ "$DRY_RUN" == true ]] || printf '%s\t%s\n' "$target" "$backup" >> "$DOTFILES_MANIFEST"
}

dotfiles_paths_match() {
  local left="$1" right="$2" left_resolved right_resolved
  [[ -L "$left" && ( -e "$right" || -L "$right" ) ]] || return 1
  left_resolved="$(readlink -f "$left" 2>/dev/null || true)"
  right_resolved="$(readlink -f "$right" 2>/dev/null || true)"
  [[ -n "$left_resolved" && -n "$right_resolved" && "$left_resolved" == "$right_resolved" ]]
}

dotfiles_copy_path() {
  local source="$1" destination="$2"
  run mkdir -p "$(dirname "$destination")"
  run cp -a "$source" "$destination"
}

dotfiles_ensure_repository() {
  if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
    if [[ -n "${LINUX_BOOTSTRAP_DOTFILES_REPO:-}" ]]; then
      run mkdir -p "$(dirname "$DOTFILES_DIR")"
      run git clone "$LINUX_BOOTSTRAP_DOTFILES_REPO" "$DOTFILES_DIR"
    else
      run mkdir -p "$DOTFILES_DIR"
      run git -C "$DOTFILES_DIR" init -b main
    fi
  fi
}

dotfiles_import() {
  local id relative target_spec mode scope risk description target repository_target
  dotfiles_validate_catalog
  [[ "$DOTFILES_APPLY" == true && "$DRY_RUN" != true ]] && dotfiles_ensure_repository
  DOTFILES_BACKUP_KIND=import
  DOTFILES_MANIFEST=
  printf '\nDotfiles import %s\nRepository: %s\n\n' "$([[ "$DOTFILES_APPLY" == true ]] && printf apply || printf preview)" "$DOTFILES_DIR"
  while IFS=$'\t' read -r id relative target_spec mode scope risk description; do
    [[ -n "$id" && "$id" != \#* ]] || continue
    dotfiles_scope_active "$scope" || continue
    target="$(dotfiles_expand_path "$target_spec")"
    repository_target="$DOTFILES_DIR/$(dotfiles_expand_path "$relative")"
    if [[ ! -e "$target" && ! -L "$target" ]]; then
      printf 'SKIP     %-22s target missing: %s\n' "$id" "$target"
      continue
    fi
    if dotfiles_paths_match "$target" "$repository_target"; then
      printf 'CURRENT  %-22s %s\n' "$id" "$target"
      continue
    fi
    if [[ -L "$target" ]]; then
      printf 'BLOCKED  %-22s existing unmanaged symlink requires review: %s\n' "$id" "$target"
      continue
    fi
    if dotfiles_contains_sensitive_data "$target"; then
      printf 'BLOCKED  %-22s review sensitive content\n' "$id"
      continue
    fi
    printf '%-8s %-22s %s -> %s [%s/%s]\n' "$([[ "$DOTFILES_APPLY" == true ]] && printf IMPORT || printf WOULD)" "$id" "$target" "$repository_target" "$mode" "$risk"
    [[ "$DOTFILES_APPLY" == true ]] || continue
    dotfiles_backup_existing "$repository_target" "repository/$id"
    dotfiles_copy_path "$target" "$repository_target"
    if [[ "$mode" == symlink ]]; then
      dotfiles_backup_existing "$target" "home/$id"
      run mkdir -p "$(dirname "$target")"
      run ln -s "$repository_target" "$target"
    fi
  done < "$DOTFILES_CATALOG"
  if [[ "$DOTFILES_APPLY" != true ]]; then
    printf '\nPreview only. Re-run with --apply after reviewing every entry.\n'
  else
    ui_success "Import complete. Review 'git -C $DOTFILES_DIR status' before the first commit."
  fi
}

dotfiles_apply_repository() {
  local id relative target_spec mode scope risk _description target repository_source
  dotfiles_validate_catalog
  [[ -d "$DOTFILES_DIR" ]] || die "Dotfiles repository does not exist: $DOTFILES_DIR"
  DOTFILES_BACKUP_KIND=apply
  DOTFILES_MANIFEST=
  printf '\nDotfiles apply %s\nRepository: %s\n\n' "$([[ "$DOTFILES_APPLY" == true ]] && printf apply || printf preview)" "$DOTFILES_DIR"
  while IFS=$'\t' read -r id relative target_spec mode scope risk _description; do
    [[ -n "$id" && "$id" != \#* ]] || continue
    dotfiles_scope_active "$scope" || continue
    target="$(dotfiles_expand_path "$target_spec")"
    repository_source="$DOTFILES_DIR/$(dotfiles_expand_path "$relative")"
    [[ -e "$repository_source" || -L "$repository_source" ]] || { printf 'SKIP     %-22s repository entry missing\n' "$id"; continue; }
    if [[ "$mode" == symlink ]] && dotfiles_paths_match "$target" "$repository_source"; then
      printf 'CURRENT  %-22s %s\n' "$id" "$target"
      continue
    fi
    printf '%-8s %-22s %s -> %s [%s/%s]\n' "$([[ "$DOTFILES_APPLY" == true ]] && printf APPLY || printf WOULD)" "$id" "$repository_source" "$target" "$mode" "$risk"
    [[ "$DOTFILES_APPLY" == true ]] || continue
    dotfiles_backup_existing "$target" "home/$id"
    run mkdir -p "$(dirname "$target")"
    if [[ "$mode" == symlink ]]; then run ln -s "$repository_source" "$target"
    else dotfiles_copy_path "$repository_source" "$target"
    fi
  done < "$DOTFILES_CATALOG"
  [[ "$DOTFILES_APPLY" == true ]] || printf '\nPreview only. Re-run with --apply after reviewing every entry.\n'
}

dotfiles_status() {
  local id relative target_spec mode scope _ target repository_source state
  dotfiles_validate_catalog
  printf '\nDotfiles status\nRepository: %s\n\n' "$DOTFILES_DIR"
  while IFS=$'\t' read -r id relative target_spec mode scope _; do
    [[ -n "$id" && "$id" != \#* ]] || continue
    dotfiles_scope_active "$scope" || continue
    target="$(dotfiles_expand_path "$target_spec")"
    repository_source="$DOTFILES_DIR/$(dotfiles_expand_path "$relative")"
    state=missing
    if [[ "$mode" == symlink ]] && dotfiles_paths_match "$target" "$repository_source"; then state=linked
    elif [[ -e "$target" && -e "$repository_source" ]] && diff -qr "$target" "$repository_source" >/dev/null 2>&1; then state=matched
    elif [[ -e "$target" && -e "$repository_source" ]]; then state=changed
    elif [[ -e "$target" || -L "$target" ]]; then state=untracked
    fi
    printf '%-9s %-22s %s\n' "$state" "$id" "$target"
  done < "$DOTFILES_CATALOG"
  if [[ -d "$DOTFILES_DIR/.git" ]]; then
    printf '\nGit status:\n'
    git -C "$DOTFILES_DIR" status --short
  fi
}

dotfiles_restore_latest() {
  local manifest candidate operation target backup displaced i restored=0
  while IFS= read -r candidate; do
    [[ -s "$candidate" && ! -e "$(dirname "$candidate")/.restored" ]] || continue
    operation="$(cat "$(dirname "$candidate")/operation" 2>/dev/null || true)"
    [[ "$operation" == import || "$operation" == apply ]] || continue
    manifest="$candidate"
    break
  done < <(find "$DOTFILES_STATE_DIR/backups" -mindepth 2 -maxdepth 2 -name manifest.tsv -type f -print 2>/dev/null | sort -r)
  [[ -n "$manifest" ]] || die "No dotfiles import/apply backup is available to restore."
  mapfile -t restore_entries < "$manifest"
  ((${#restore_entries[@]} > 0)) || die "The selected backup manifest is empty."
  for i in "${!restore_entries[@]}"; do
    IFS=$'\t' read -r target backup <<<"${restore_entries[i]}"
    [[ -n "$target" && -n "$backup" && "$target" == /* ]] || die "The selected backup manifest contains an invalid entry on line $((i + 1))."
    if [[ "$backup" != - && ! -e "$backup" && ! -L "$backup" ]]; then
      die "Restore preflight failed because the backup for $target is missing. No files were changed."
    fi
  done
  printf 'Restoring backup recorded in %s\n' "$manifest"
  for ((i=${#restore_entries[@]}-1; i>=0; i--)); do
    IFS=$'\t' read -r target backup <<<"${restore_entries[i]}"
    if [[ -e "$target" || -L "$target" ]]; then
      displaced="$(dirname "$manifest")/restore-displaced/${target#/}"
      run mkdir -p "$(dirname "$displaced")"
      run mv "$target" "$displaced"
    fi
    if [[ "$backup" != - ]]; then
      run mkdir -p "$(dirname "$target")"
      run mv "$backup" "$target"
    fi
    ((restored+=1))
  done
  ((restored > 0)) || die "The selected backup contained no restorable entries."
  [[ "$DRY_RUN" == true ]] || : > "$(dirname "$manifest")/.restored"
  ui_success "Restored $restored dotfiles path(s) from the latest import/apply backup."
}

dotfiles_refresh_portable_copies() {
  local id relative target_spec mode scope risk _ target repository_target
  DOTFILES_BACKUP_KIND=sync
  DOTFILES_MANIFEST=
  while IFS=$'\t' read -r id relative target_spec mode scope risk _; do
    [[ -n "$id" && "$id" != \#* && "$mode" == watched-copy && "$risk" == portable ]] || continue
    dotfiles_scope_active "$scope" || continue
    target="$(dotfiles_expand_path "$target_spec")"
    repository_target="$DOTFILES_DIR/$(dotfiles_expand_path "$relative")"
    [[ -e "$target" ]] || continue
    diff -qr "$target" "$repository_target" >/dev/null 2>&1 && continue
    if dotfiles_contains_sensitive_data "$target"; then
      ui_warn "Automatic sync blocked sensitive-looking content in $id."
      return 1
    fi
    dotfiles_backup_existing "$repository_target" "repository-sync/$id"
    dotfiles_copy_path "$target" "$repository_target"
  done < "$DOTFILES_CATALOG"
}

dotfiles_stage_portable() {
  local id relative _mode _scope risk _ repository_relative
  git -C "$DOTFILES_DIR" diff --cached --quiet || die "Automatic sync found pre-staged changes and stopped so it cannot commit them accidentally."
  while IFS=$'\t' read -r id relative _ _mode _scope risk _; do
    [[ -n "$id" && "$id" != \#* && "$risk" == portable ]] || continue
    repository_relative="$(dotfiles_expand_path "$relative")"
    if [[ ! -e "$DOTFILES_DIR/$repository_relative" ]] && ! git -C "$DOTFILES_DIR" ls-files --error-unmatch -- "$repository_relative" >/dev/null 2>&1; then
      continue
    fi
    run git -C "$DOTFILES_DIR" add -A -- "$repository_relative"
  done < "$DOTFILES_CATALOG"
}

dotfiles_sync() {
  local upstream lock_file
  dotfiles_validate_catalog
  [[ -d "$DOTFILES_DIR/.git" ]] || die "Dotfiles Git repository does not exist: $DOTFILES_DIR"
  git -C "$DOTFILES_DIR" remote get-url origin >/dev/null 2>&1 || die "Automatic sync requires an 'origin' remote. Set LINUX_BOOTSTRAP_DOTFILES_REPO during import or add it with Git."
  command -v flock >/dev/null 2>&1 || die "Automatic sync requires flock."
  run mkdir -p "$DOTFILES_STATE_DIR"
  lock_file="$DOTFILES_STATE_DIR/sync.lock"
  exec 9>"$lock_file"
  flock -n 9 || { ui_warn "Another dotfiles synchronization is already running."; return 0; }
  if dotfiles_contains_sensitive_data "$DOTFILES_DIR"; then
    die "Automatic sync stopped before changing files because the repository contains sensitive-looking data."
  fi
  dotfiles_refresh_portable_copies
  if dotfiles_contains_sensitive_data "$DOTFILES_DIR"; then
    die "Automatic sync stopped because refreshed content contains sensitive-looking data."
  fi
  dotfiles_stage_portable
  if ! git -C "$DOTFILES_DIR" diff --cached --quiet; then
    run git -C "$DOTFILES_DIR" commit -m "dotfiles: automatic sync $(dotfiles_host_name) $(date -Iseconds)"
  fi
  run git -C "$DOTFILES_DIR" fetch origin
  upstream="$(git -C "$DOTFILES_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    run git -C "$DOTFILES_DIR" rebase "$upstream"
    run git -C "$DOTFILES_DIR" push
  else
    run git -C "$DOTFILES_DIR" push --set-upstream origin HEAD
  fi
  ui_success "Dotfiles synchronized. Watched-copy remote changes remain pending until an explicit apply."
}

dotfiles_enable_auto_sync() {
  local unit_dir service timer setup_path quoted_dotfiles quoted_setup
  [[ -d "$DOTFILES_DIR/.git" ]] || die "Initialize/import the dotfiles repository first."
  git -C "$DOTFILES_DIR" remote get-url origin >/dev/null 2>&1 || die "Add an origin remote before enabling automatic synchronization."
  command -v systemctl >/dev/null 2>&1 || die "systemd user services are unavailable."
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  service="$unit_dir/linux-bootstrap-dotfiles-sync.service"
  timer="$unit_dir/linux-bootstrap-dotfiles-sync.timer"
  setup_path="$ROOT_DIR/setup.sh"
  [[ "$DOTFILES_DIR" != *$'\n'* && "$setup_path" != *$'\n'* ]] || die "Automatic sync paths cannot contain newlines."
  quoted_dotfiles="${DOTFILES_DIR//\\/\\\\}"
  quoted_dotfiles="${quoted_dotfiles//\"/\\\"}"
  quoted_dotfiles="${quoted_dotfiles//\%/%%}"
  quoted_setup="${setup_path//\\/\\\\}"
  quoted_setup="${quoted_setup//\"/\\\"}"
  quoted_setup="${quoted_setup//\%/%%}"
  run mkdir -p "$unit_dir"
  if [[ "$DRY_RUN" == true ]]; then
    printf '+ write %s\n+ write %s\n' "$service" "$timer"
  else
    DOTFILES_BACKUP_KIND=units
    DOTFILES_MANIFEST=
    dotfiles_backup_existing "$service" systemd/service
    dotfiles_backup_existing "$timer" systemd/timer
    printf '[Unit]\nDescription=Synchronize portable Linux Bootstrap dotfiles\n\n[Service]\nType=oneshot\nEnvironment="LINUX_BOOTSTRAP_DOTFILES_DIR=%s"\nExecStart="%s" --dotfiles sync\n' "$quoted_dotfiles" "$quoted_setup" > "$service"
    printf '[Unit]\nDescription=Periodically synchronize portable Linux Bootstrap dotfiles\n\n[Timer]\nOnBootSec=2m\nOnUnitActiveSec=2m\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' > "$timer"
  fi
  run systemctl --user daemon-reload
  run systemctl --user enable --now linux-bootstrap-dotfiles-sync.timer
  ui_success "Automatic portable-dotfiles synchronization enabled every two minutes."
}

dotfiles_disable_auto_sync() {
  local unit_dir
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  run mkdir -p "$DOTFILES_STATE_DIR"
  run systemctl --user disable --now linux-bootstrap-dotfiles-sync.timer
  run mv "$unit_dir/linux-bootstrap-dotfiles-sync.service" "$DOTFILES_STATE_DIR/disabled-sync.service"
  run mv "$unit_dir/linux-bootstrap-dotfiles-sync.timer" "$DOTFILES_STATE_DIR/disabled-sync.timer"
  run systemctl --user daemon-reload
}

run_dotfiles_action() {
  local action="$1"
  case "$action" in
    import) dotfiles_import ;;
    apply) dotfiles_apply_repository ;;
    status) dotfiles_status ;;
    restore) [[ "$DOTFILES_APPLY" == true ]] || die "Restore requires --apply."; dotfiles_restore_latest ;;
    sync) dotfiles_sync ;;
    enable-auto) [[ "$DOTFILES_APPLY" == true ]] || die "Enabling automatic sync requires --apply."; dotfiles_enable_auto_sync ;;
    disable-auto) [[ "$DOTFILES_APPLY" == true ]] || die "Disabling automatic sync requires --apply."; dotfiles_disable_auto_sync ;;
    *) die "Unknown dotfiles action '$action'. Use import, apply, status, restore, sync, enable-auto, or disable-auto." ;;
  esac
}

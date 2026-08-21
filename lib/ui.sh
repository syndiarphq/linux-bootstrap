#!/usr/bin/env bash

has_gum() { command -v gum >/dev/null 2>&1 && [[ -t 0 ]]; }

UI_SCREEN_ACTIVE=false
ui_screen_start() {
  [[ "${FULLSCREEN:-true}" == true && -t 0 && -t 1 ]] || return 0
  command -v tput >/dev/null 2>&1 || return 0
  tput smcup 2>/dev/null || return 0
  tput civis 2>/dev/null || true
  UI_SCREEN_ACTIVE=true
  trap 'ui_screen_stop' EXIT
  trap 'ui_screen_stop; exit 130' INT
  trap 'ui_screen_stop; exit 143' TERM
  ui_screen_clear
}

ui_screen_clear() {
  [[ "$UI_SCREEN_ACTIVE" == true ]] || return 0
  tput clear >&2 2>/dev/null || printf '\033[2J\033[H' >&2
}

ui_screen_stop() {
  [[ "$UI_SCREEN_ACTIVE" == true ]] || return 0
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  UI_SCREEN_ACTIVE=false
  trap - EXIT INT TERM
}

ui_banner() {
  if has_gum; then gum style --border rounded --padding '0 2' --foreground 212 'Linux Bootstrap'
  else printf '\n=== Linux Bootstrap ===\n'
  fi
}
ui_warn() { if has_gum; then gum style --foreground 214 "$*" >&2; else printf 'Warning: %s\n' "$*" >&2; fi; }
ui_success() { if has_gum; then gum style --foreground 42 "$*"; else printf '%s\n' "$*"; fi; }

ui_choose_one() {
  local prompt="$1" default="$2"; shift 2
  if [[ "$ASSUME_YES" == true || ! -t 0 ]]; then printf '%s\n' "$default"; return; fi
  ui_screen_clear
  ui_banner >&2
  printf '\n' >&2
  if has_gum; then gum choose --header "$prompt" "$@"; return; fi
  local items=("$@") i answer
  printf '%s\n' "$prompt" >&2
  for i in "${!items[@]}"; do printf '  %d) %s\n' "$((i+1))" "${items[$i]}" >&2; done
  read -r -p "Choice [${default}]: " answer
  [[ -z "$answer" ]] && { printf '%s\n' "$default"; return; }
  if [[ ! "$answer" =~ ^[0-9]+$ ]] || ((answer < 1 || answer > ${#items[@]})); then
    die "Invalid choice."
  fi
  printf '%s\n' "${items[$((answer-1))]}"
}

ui_choose_many() {
  local prompt="$1"; shift
  if [[ "$ASSUME_YES" == true || ! -t 0 ]]; then printf '%s\n' "$@"; return; fi
  ui_screen_clear
  ui_banner >&2
  printf '\n' >&2
  if has_gum; then gum choose --no-limit --header "$prompt (space to toggle)" "$@"; return; fi
  local items=("$@") raw n
  printf '%s\n' "$prompt" >&2
  for n in "${!items[@]}"; do printf '  %d) %s\n' "$((n+1))" "${items[$n]}" >&2; done
  read -r -p 'Numbers separated by spaces (Enter for all): ' raw
  [[ -z "$raw" ]] && { printf '%s\n' "${items[@]}"; return; }
  for n in $raw; do
    if [[ ! "$n" =~ ^[0-9]+$ ]] || ((n < 1 || n > ${#items[@]})); then
      die "Invalid selection: $n"
    fi
    printf '%s\n' "${items[$((n-1))]}"
  done
}

ui_confirm() {
  local prompt="$1" default="${2:-no}"
  [[ "$ASSUME_YES" == true ]] && return 0
  [[ ! -t 0 ]] && [[ "$default" == yes ]] && return 0
  [[ ! -t 0 ]] && return 1
  ui_screen_clear
  ui_banner >&2
  printf '\n' >&2
  if has_gum; then gum confirm "$prompt"; return; fi
  local suffix='[y/N]' reply
  [[ "$default" == yes ]] && suffix='[Y/n]'
  read -r -p "$prompt $suffix " reply
  [[ -z "$reply" ]] && [[ "$default" == yes ]] && return 0
  [[ "$reply" =~ ^[Yy]$ ]]
}

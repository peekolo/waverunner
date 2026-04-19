#!/usr/bin/env bash

ui_init() {
  if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then
    UI_ENABLE_COLOR=0
  elif [[ -t 1 || -t 2 ]]; then
    UI_ENABLE_COLOR=1
  else
    UI_ENABLE_COLOR=0
  fi

  if [[ "$UI_ENABLE_COLOR" == "1" ]]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_BLUE=$'\033[34m'
    UI_CYAN=$'\033[36m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_RED=$'\033[31m'
    UI_MAGENTA=$'\033[35m'
  else
    UI_RESET=''
    UI_BOLD=''
    UI_DIM=''
    UI_BLUE=''
    UI_CYAN=''
    UI_GREEN=''
    UI_YELLOW=''
    UI_RED=''
    UI_MAGENTA=''
  fi
}

ui_badge() {
  local color="$1"
  local label="$2"
  printf '%s[%s]%s' "${UI_BOLD}${color}" "$label" "$UI_RESET"
}

ui_heading() {
  printf '%s%s%s\n' "${UI_BOLD}${UI_CYAN}" "$1" "$UI_RESET"
}

ui_subheading() {
  printf '%s%s%s\n' "${UI_BOLD}${UI_BLUE}" "$1" "$UI_RESET"
}

ui_info() {
  printf '%s %s\n' "$(ui_badge "$UI_BLUE" INFO)" "$*"
}

ui_note() {
  printf '%s %s\n' "$(ui_badge "$UI_MAGENTA" NOTE)" "$*"
}

ui_success() {
  printf '%s %s\n' "$(ui_badge "$UI_GREEN" DONE)" "$*"
}

ui_warn() {
  printf '%s %s\n' "$(ui_badge "$UI_YELLOW" WARN)" "$*" >&2
}

ui_error() {
  printf '%s %s\n' "$(ui_badge "$UI_RED" FAIL)" "$*" >&2
}

ui_kv() {
  local label="$1"
  local value="$2"
  printf '  %s%-18s%s %s\n' "${UI_DIM}" "$label" "$UI_RESET" "$value"
}

ui_prompt_line() {
  local step="$1"
  local text="$2"
  if [[ -n "$step" ]]; then
    printf '%s%s%s %s\n' "${UI_BOLD}${UI_BLUE}" "$step" "$UI_RESET" "$text" >&2
  else
    printf '%s%s%s\n' "${UI_BOLD}${UI_BLUE}" "$text" "$UI_RESET" >&2
  fi
}

ui_prompt_marker() {
  printf '      %s>%s ' "${UI_BOLD}${UI_CYAN}" "$UI_RESET" >&2
}

ui_status_line() {
  local status="$1"
  local subject="$2"
  local detail="${3:-}"
  local color="$UI_BLUE"

  case "$status" in
    DONE) color="$UI_GREEN" ;;
    FAILED) color="$UI_RED" ;;
    SKIPPED) color="$UI_YELLOW" ;;
    START) color="$UI_BLUE" ;;
    BATCH) color="$UI_CYAN" ;;
    RESUME) color="$UI_MAGENTA" ;;
  esac

  if [[ -n "$detail" ]]; then
    printf '%s %s %s%s%s\n' "$(ui_badge "$color" "$status")" "$subject" "$UI_DIM" "$detail" "$UI_RESET"
  else
    printf '%s %s\n' "$(ui_badge "$color" "$status")" "$subject"
  fi
}

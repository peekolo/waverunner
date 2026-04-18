#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

usage() {
  cat <<'EOF'
Usage:
  ./install.sh
  ./install.sh --upgrade <target>
EOF
}

install_hint() {
  case "$1" in
    jq)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        printf '%s\n' 'missing prerequisite: jq (install with: brew install jq)' >&2
      else
        printf '%s\n' 'missing prerequisite: jq (install with: apt install jq)' >&2
      fi
      ;;
    git)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        printf '%s\n' 'missing prerequisite: git (install with: brew install git)' >&2
      else
        printf '%s\n' 'missing prerequisite: git (install with: apt install git)' >&2
      fi
      ;;
    *)
      printf 'missing prerequisite: %s\n' "$1" >&2
      ;;
  esac
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    install_hint "$1"
    exit 2
  fi
}

check_prereqs() {
  require_cmd jq
  require_cmd git
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

render_config() {
  local cli="$1"
  local project_root="$2"
  local git_dir="$3"
  local target="$4"
  local template_path="$SCRIPT_DIR/templates/config.json.tpl"

  sed \
    -e "s/{{CLI}}/$(escape_sed_replacement "$cli")/g" \
    -e "s/{{PROJECT_ROOT}}/$(escape_sed_replacement "$project_root")/g" \
    -e "s/{{GIT_DIR}}/$(escape_sed_replacement "$git_dir")/g" \
    "$template_path" > "$target/config.json"
}

run_upgrade() {
  local target="$1"

  if [[ -z "$target" ]]; then
    usage
    exit 2
  fi

  mkdir -p "$target"
  cp "$SCRIPT_DIR/src/run.sh" "$target/run.sh"
  chmod +x "$target/run.sh"

  printf 'Upgraded wave runner at: %s\n' "$target"
  printf '%s\n' 'Updated: run.sh'
}

prompt_value() {
  local prompt_text="$1"
  local value

  printf '%s\n' "$prompt_text" >&2
  printf '      > ' >&2
  IFS= read -r value
  printf '%s' "$value"
}

main() {
  local project_root
  local target
  local cli_choice
  local cli
  local git_dir

  check_prereqs

  if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--upgrade" && $# -eq 2 ]]; then
      run_upgrade "$2"
      exit 0
    fi

    usage
    exit 2
  fi

  project_root=$(prompt_value '[1/4] Project root path?')
  target=$(prompt_value '[2/4] Install wave runner at?')
  cli_choice=$(prompt_value '[3/4] Which CLI? (1) claude  (2) codex')
  git_dir=$(prompt_value '[4/4] Git dir? (blank = same as project root)')

  case "$cli_choice" in
    1) cli="claude" ;;
    2) cli="codex" ;;
    *)
      printf '%s\n' 'invalid CLI choice; expected 1 or 2' >&2
      exit 2
      ;;
  esac

  if [[ -z "$project_root" || -z "$target" ]]; then
    printf '%s\n' 'project root and target path are required' >&2
    exit 2
  fi

  if [[ -z "$git_dir" ]]; then
    git_dir="$project_root"
  fi

  mkdir -p "$target/specs" "$target/prompts"
  cp "$SCRIPT_DIR/src/run.sh" "$target/run.sh"
  chmod +x "$target/run.sh"
  render_config "$cli" "$project_root" "$git_dir" "$target"
  cp "$SCRIPT_DIR/templates/master_prompt.md.tpl" "$target/master_prompt.md"
  cp "$SCRIPT_DIR/templates/execution_example.json" "$target/execution_example.json"

  cat <<EOF
Done. Wave runner installed at: $target

Next steps:
  1. Edit config.json         — verify paths, fill executions[]
  2. Fill in master_prompt.md — project-wide context for every executor
  3. Drop techspec MDs in specs/  and prompt MDs in prompts/
  4. Run:
       $target/run.sh --dry-run
       $target/run.sh
EOF
}

main "$@"

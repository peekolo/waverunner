#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/src/ui.sh"
ui_init

usage() {
  cat <<'EOF'
Usage:
  ./install.sh
  ./install.sh --upgrade <target>
EOF
}

say_err() {
  ui_error "$*"
}

say_warn() {
  ui_warn "$*"
}

say_info() {
  ui_info "$*"
}

install_hint() {
  case "$1" in
    jq)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        say_err 'missing prerequisite: jq (install with: brew install jq)'
      else
        say_err 'missing prerequisite: jq (install with: apt install jq)'
      fi
      ;;
    git)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        say_err 'missing prerequisite: git (install with: brew install git)'
      else
        say_err 'missing prerequisite: git (install with: apt install git)'
      fi
      ;;
    *)
      say_err "missing prerequisite: $1"
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

normalize_path() {
  local input="$1"
  local base="$2"
  local combined
  local old_ifs
  local part
  local joined
  local i
  local -a pieces
  local -a out

  if [[ "$input" == /* ]]; then
    combined="$input"
  else
    combined="$base/$input"
  fi

  old_ifs=$IFS
  IFS='/'
  set -f
  pieces=($combined)
  set +f
  IFS=$old_ifs

  out=()
  for part in "${pieces[@]}"; do
    if [[ -z "$part" || "$part" == "." ]]; then
      continue
    fi
    if [[ "$part" == ".." ]]; then
      if [[ ${#out[@]} -gt 0 ]]; then
        unset 'out[${#out[@]}-1]'
      fi
      continue
    fi
    out+=("$part")
  done

  joined=""
  for ((i=0; i<${#out[@]}; i++)); do
    if [[ $i -eq 0 ]]; then
      joined="${out[$i]}"
    else
      joined="$joined/${out[$i]}"
    fi
  done

  if [[ -n "$joined" ]]; then
    printf '/%s\n' "$joined"
  else
    printf '%s\n' '/'
  fi
}

escape_awk_replacement() {
  printf '%s' "$1" | sed -e 's/[\\&]/\\&/g'
}

render_config() {
  local cli="$1"
  local project_root="$2"
  local git_dir="$3"
  local target="$4"
  local template_path="$SCRIPT_DIR/templates/config.json.tpl"
  local example_model_block
  local cli_top_level_block

  if [[ "$cli" == "claude" ]]; then
    cli_top_level_block='  "claude_max_turns": 300,'
    example_model_block='      "model": "claude-sonnet-4-6",
      "effort": "high"'
  else
    cli_top_level_block=''
    example_model_block='      "model": "codex-mini-latest"'
  fi

  awk \
    -v cli="$(escape_awk_replacement "$cli")" \
    -v project_root="$(escape_awk_replacement "$project_root")" \
    -v git_dir="$(escape_awk_replacement "$git_dir")" \
    -v cli_top_level_block="$(escape_awk_replacement "$cli_top_level_block")" \
    -v example_model_block="$(escape_awk_replacement "$example_model_block")" \
    '{
      gsub(/\{\{CLI\}\}/, cli)
      gsub(/\{\{PROJECT_ROOT\}\}/, project_root)
      gsub(/\{\{GIT_DIR\}\}/, git_dir)
      gsub(/\{\{CLI_TOP_LEVEL_BLOCK\}\}/, cli_top_level_block)
      gsub(/\{\{EXAMPLE_MODEL_BLOCK\}\}/, example_model_block)
      print
    }' "$template_path" > "$target/config.json"
}

copy_howtouse() {
  local target="$1"
  cp "$SCRIPT_DIR/templates/howtouse.md.tpl" "$target/howtouse.md"
}

copy_ui() {
  local target="$1"
  cp "$SCRIPT_DIR/src/ui.sh" "$target/ui.sh"
}

copy_adapter() {
  local cli="$1"
  local target="$2"

  mkdir -p "$target/adapters"
  cp "$SCRIPT_DIR/src/adapters/$cli.sh" "$target/adapters/$cli.sh"
}

relative_path_under_root() {
  local root="$1"
  local path="$2"
  local root_abs
  local path_abs

  root_abs=$(normalize_path "$root" "$SCRIPT_DIR")
  path_abs=$(normalize_path "$path" "$SCRIPT_DIR")

  case "$path_abs/" in
    "$root_abs/"*)
      printf '%s\n' "${path_abs#"$root_abs"/}"
      return 0
      ;;
  esac

  printf '%s\n' ''
}

run_upgrade() {
  local target="$1"
  local config_path
  local cli

  if [[ -z "$target" ]]; then
    usage
    exit 2
  fi

  config_path="$target/config.json"
  if [[ ! -f "$config_path" ]]; then
    say_err "upgrade target is missing config.json: $config_path"
    exit 2
  fi

  cli=$(jq -r '.cli // empty' "$config_path")
  if [[ "$cli" != "claude" && "$cli" != "codex" ]]; then
    say_err "upgrade target config.json has unsupported or missing cli: $cli"
    exit 2
  fi

  mkdir -p "$target"
  cp "$SCRIPT_DIR/src/run.sh" "$target/run.sh"
  copy_ui "$target"
  copy_howtouse "$target"
  copy_adapter "$cli" "$target"
  chmod +x "$target/run.sh"

  ui_heading 'Upgrade Complete'
  ui_kv 'Target' "$target"
  ui_kv 'Updated' "run.sh, ui.sh, howtouse.md, adapters/$cli.sh"
}

prompt_value() {
  local prompt_text="$1"
  local value

  ui_prompt_line '' "$prompt_text"
  ui_prompt_marker
  IFS= read -r value
  printf '%s' "$value"
}

prompt_existing_project_root() {
  local value

  while :; do
    value=$(prompt_value '[1/5] Project root path?')
    if [[ -d "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    say_err "project root does not exist: $value"
  done
}

prompt_install_target() {
  local default_target="$1"
  local value
  local remove_choice

  while :; do
    value=$(prompt_value "[2/5] Install wave runner at? (blank = $default_target)")
    if [[ -z "$value" ]]; then
      value="$default_target"
    fi

    if [[ ! -e "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi

    say_warn "install target already exists: $value"
    remove_choice=$(prompt_value "      Remove it with rm -rf and continue? (y/n)")
    case "$remove_choice" in
      y|Y|yes|YES|Yes)
        rm -rf "$value"
        printf '%s' "$value"
        return 0
        ;;
      n|N|no|NO|No|'')
        say_warn 'choose another installation directory'
        ;;
      *)
        say_warn "unrecognized choice \"$remove_choice\"; choose another installation directory"
        ;;
    esac
  done
}

append_gitignore_entry() {
  local project_root="$1"
  local target="$2"
  local gitignore_path="$project_root/.gitignore"
  local project_root_abs
  local target_abs
  local relative_target
  local entry

  project_root_abs=$(normalize_path "$project_root" "$SCRIPT_DIR")
  target_abs=$(normalize_path "$target" "$SCRIPT_DIR")

  case "$target_abs/" in
    "$project_root_abs/"*)
      relative_target=${target_abs#"$project_root_abs"/}
      ;;
    *)
      say_warn "install target is outside project root; skipping .gitignore update: $target_abs"
      return 0
      ;;
  esac

  if [[ -z "$relative_target" || "$relative_target" == "$target_abs" ]]; then
    say_warn "could not derive a relative .gitignore path for: $target_abs"
    return 0
  fi

  entry="/$relative_target/"

  if [[ -f "$gitignore_path" ]] && grep -F -x "$entry" "$gitignore_path" >/dev/null 2>&1; then
    return 0
  fi

  {
    if [[ -f "$gitignore_path" ]]; then
      printf '\n'
    fi
    printf '%s\n' '# ai-wave-runner install'
    printf '%s\n' "$entry"
  } >> "$gitignore_path"
}

main() {
  local project_root
  local target
  local default_target
  local gitignore_choice
  local cli_choice
  local cli
  local git_dir
  local howtouse_rel
  local howtouse_ref
  local target_rel

  check_prereqs

  if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--upgrade" && $# -eq 2 ]]; then
      run_upgrade "$2"
      exit 0
    fi

    usage
    exit 2
  fi

  project_root=$(prompt_existing_project_root)
  default_target="$project_root/waverunner"
  target=$(prompt_install_target "$default_target")
  gitignore_choice=$(prompt_value '[3/5] Add the wave runner directory to the project .gitignore? (y/n)')
  cli_choice=$(prompt_value '[4/5] Which CLI? (1) claude  (2) codex')
  git_dir=$(prompt_value '[5/5] Git dir? (blank = same as project root)')

  case "$cli_choice" in
    1) cli="claude" ;;
    2) cli="codex" ;;
    *)
      say_err 'invalid CLI choice; expected 1 or 2'
      exit 2
      ;;
  esac

  if [[ -z "$git_dir" ]]; then
    git_dir="$project_root"
  fi

  mkdir -p "$target"
  cp "$SCRIPT_DIR/src/run.sh" "$target/run.sh"
  chmod +x "$target/run.sh"
  render_config "$cli" "$project_root" "$git_dir" "$target"
  copy_ui "$target"
  copy_howtouse "$target"
  copy_adapter "$cli" "$target"

  case "$gitignore_choice" in
    y|Y|yes|YES|Yes)
      append_gitignore_entry "$project_root" "$target"
      ;;
    n|N|no|NO|No|'')
      ;;
    *)
      say_warn "unrecognized .gitignore choice \"$gitignore_choice\"; skipping .gitignore update"
      ;;
  esac

  ui_heading 'Install Complete'
  ui_kv 'Target' "$target"
  ui_kv 'CLI' "$cli"
  ui_kv 'Git dir' "$git_dir"
  printf '\n'
  ui_subheading 'Next Steps'
  ui_kv '1' 'Edit config.json and replace the example execution'
  ui_kv '2' 'Point master_prompt_path at your project-wide prompt file'
  ui_kv '3' 'Point executions[] at your techspec and prompt files'
  ui_kv '4' "$target/run.sh --dry-run"
  ui_kv '5' "$target/run.sh"

  howtouse_rel=$(relative_path_under_root "$project_root" "$target/howtouse.md")
  if [[ -n "$howtouse_rel" ]]; then
    howtouse_ref="$howtouse_rel"
  else
    howtouse_ref="$target/howtouse.md"
  fi

  target_rel=$(relative_path_under_root "$project_root" "$target")
  if [[ -z "$target_rel" ]]; then
    target_rel="$target"
  fi

  printf '\n'
  ui_subheading 'Suggested Prompt For Your AI Agent'
  printf '  %s\n' "Refer to $howtouse_ref and set up Waverunner for this project. Update $target_rel/config.json to match the tasks I give you, create any missing prompt/spec/master-prompt artifacts that config needs, keep the orchestration inside Waverunner instead of adding custom runner scripts to the core repo, and then show me the resulting wave plan."
}

main "$@"

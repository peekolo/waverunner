#!/usr/bin/env bash

adapter_require_cli() {
  require_cmd codex
}

adapter_validate_execution() {
  local idx="$1"

  if [[ -n "${EXEC_EFFORT[$idx]}" ]] && [[ -z "${CODEX_EFFORT_WARNED:-}" ]]; then
    say_err 'warning: executions[].effort is ignored when cli=codex'
    CODEX_EFFORT_WARNED=1
  fi
}

adapter_print_execution_plan() {
  printf '%s\n' '    mode: safe_unattended (approval=never sandbox=workspace-write)'
}

adapter_run_cli() {
  local prompt_file="$1"
  local log_file="$2"
  local worktree_path="$3"
  local model="$4"
  local effort="$5"
  local output_dir="$6"

  (
    cd "$worktree_path" || exit 1
    codex exec \
      -a never \
      -s workspace-write \
      -C "$worktree_path" \
      --add-dir "$output_dir" \
      -m "$model" \
      < "$prompt_file" > "$log_file" 2>&1
  )
}

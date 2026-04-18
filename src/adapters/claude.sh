#!/usr/bin/env bash

adapter_require_cli() {
  require_cmd claude
}

adapter_validate_execution() {
  local idx="$1"
  local effort="${EXEC_EFFORT[$idx]}"

  if [[ -z "$effort" ]]; then
    die "executions[$idx] missing required field: effort for cli=claude" 2
  fi
}

adapter_print_execution_plan() {
  local idx="$1"
  printf '    effort: %s\n' "${EXEC_EFFORT[$idx]}"
  printf '%s\n' '    mode: safe_unattended (permission-mode=dontAsk)'
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
    claude -p \
      --model "$model" \
      --effort "$effort" \
      --permission-mode dontAsk \
      --add-dir "$output_dir" \
      --no-session-persistence \
      < "$prompt_file" > "$log_file" 2>&1
  )
}

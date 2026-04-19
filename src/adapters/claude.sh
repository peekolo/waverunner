#!/usr/bin/env bash

CLAUDE_ALLOWED_TOOLS='Read,Grep,Glob,Write,Edit,MultiEdit,Bash'
CLAUDE_MAX_TURNS=100

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
  plan_field 'effort' "${EXEC_EFFORT[$idx]}"
  plan_field 'tools' "$CLAUDE_ALLOWED_TOOLS"
  plan_field 'max_turns' "$CLAUDE_MAX_TURNS"
  plan_field 'mode' 'dangerous_unattended (dangerously-skip-permissions)'
}

adapter_run_cli() {
  local prompt_file="$1"
  local log_file="$2"
  local worktree_path="$3"
  local model="$4"
  local effort="$5"
  local output_dir="$6"
  local tmp_file
  local is_error
  local prompt_text
  local rc=0

  prompt_text=$(cat "$prompt_file") || exit 1
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/waverunner-claude.XXXXXX") || exit 1

  (
    cd "$worktree_path" || exit 1
    claude -p \
      "$prompt_text" \
      --model "$model" \
      --effort "$effort" \
      --allowedTools "$CLAUDE_ALLOWED_TOOLS" \
      --max-turns "$CLAUDE_MAX_TURNS" \
      --output-format json \
      --dangerously-skip-permissions \
      --add-dir "$output_dir" \
      --no-session-persistence \
      > "$tmp_file" 2>&1
  ) || rc=$?

  mv "$tmp_file" "$log_file" || exit 1

  if [[ $rc -ne 0 ]]; then
    exit "$rc"
  fi

  is_error=$(jq -r '.is_error // false' "$log_file" 2>/dev/null || printf '%s\n' 'false')
  if [[ "$is_error" == "true" ]]; then
    exit 1
  fi
}

#!/usr/bin/env bash

CLAUDE_ALLOWED_TOOLS='Read,Grep,Glob,Write,Edit,MultiEdit,Bash'
CLAUDE_MAX_TURNS=100
CLAUDE_TIMEOUT_SECONDS=14400  # 4 hours; emergency backstop only — tune per project

adapter_require_cli() {
  require_cmd claude
  require_cmd perl
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
  plan_field 'timeout_seconds' "$CLAUDE_TIMEOUT_SECONDS"
  plan_field 'mode' 'dangerous_unattended (dangerously-skip-permissions)'
}

claude_spawn_in_new_session() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@"
    return $?
  fi

  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX=setsid -e '
      POSIX::setsid() or die "setsid failed: $!\n";
      exec @ARGV or die "exec failed: $!\n";
    ' "$@"
    return $?
  fi

  "$@"
}

claude_kill_process_tree() {
  local leader_pid="$1"
  local signal="$2"

  kill "-$signal" -- "-$leader_pid" 2>/dev/null || kill "-$signal" "$leader_pid" 2>/dev/null || true
}

claude_start_timeout_watchdog() {
  local leader_pid="$1"
  local timeout_seconds="$2"
  local marker_path="$3"

  CLAUDE_TIMEOUT_WATCHDOG_PID=0

  if ! command -v perl >/dev/null 2>&1; then
    return 0
  fi

  perl -e '
    use strict;
    use warnings;

    my ($pid, $timeout, $marker) = @ARGV;

    sleep $timeout;
    exit 0 unless kill 0, $pid;

    if (open my $fh, ">", $marker) {
      print {$fh} "timeout\n";
      close $fh;
    }

    kill "TERM", -$pid;
    kill "TERM", $pid;
    sleep 60;
    exit 0 unless kill 0, $pid;
    kill "KILL", -$pid;
    kill "KILL", $pid;
  ' "$leader_pid" "$timeout_seconds" "$marker_path" >/dev/null 2>&1 &
  CLAUDE_TIMEOUT_WATCHDOG_PID=$!
}

adapter_run_cli() {
  local prompt_file="$1"
  local log_file="$2"
  local worktree_path="$3"
  local model="$4"
  local effort="$5"
  local output_dir="$6"
  local tmp_file
  local timeout_marker
  local is_error
  local prompt_text
  local rc=0

  prompt_text=$(cat "$prompt_file") || exit 1
  tmp_file=$(mktemp "${TMPDIR:-/tmp}/waverunner-claude.XXXXXX") || exit 1
  timeout_marker=$(mktemp "${TMPDIR:-/tmp}/waverunner-claude-timeout.XXXXXX") || exit 1
  rm -f "$timeout_marker"

  (
    local _group_pid
    local _timer_pid=0
    local _rc

    cd "$worktree_path" || exit 1
    # Stock macOS does not ship GNU setsid/timeout. Prefer setsid when it
    # exists, fall back to perl's POSIX::setsid, and enforce the timeout
    # from bash so descendant cleanup still works on macOS and Linux.
    claude_spawn_in_new_session \
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
      > "$tmp_file" 2>&1 &
    _group_pid=$!

    if [[ "$CLAUDE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
      claude_start_timeout_watchdog "$_group_pid" "$CLAUDE_TIMEOUT_SECONDS" "$timeout_marker"
      _timer_pid=${CLAUDE_TIMEOUT_WATCHDOG_PID:-0}
    fi

    trap '
      if [[ $_timer_pid -ne 0 ]]; then
        kill "$_timer_pid" 2>/dev/null || true
        wait "$_timer_pid" 2>/dev/null || true
      fi
      claude_kill_process_tree "$_group_pid" TERM
    ' EXIT

    wait "$_group_pid"
    _rc=$?

    # A clean claude exit can still leave descendants behind briefly.
    # Sweep the isolated process group once more before returning so
    # straggler tool-call children do not linger after the batch ends.
    claude_kill_process_tree "$_group_pid" TERM

    if [[ $_timer_pid -ne 0 ]]; then
      kill "$_timer_pid" 2>/dev/null || true
      wait "$_timer_pid" 2>/dev/null || true
    fi

    exit "$_rc"
  ) || rc=$?

  if [[ -f "$timeout_marker" ]]; then
    rc=124
  fi
  rm -f "$timeout_marker"

  mv "$tmp_file" "$log_file" || exit 1

  # If the log JSON shows a clean success, trust it even if the subshell
  # exited non-zero. Claude can be signaled or otherwise interrupted
  # during post-result cleanup AFTER having already written its success
  # JSON; in that case the work is done and the signal is incidental.
  # This must be checked BEFORE the rc-non-zero exit below.
  # NOTE: jq's `//` operator fires on null AND false, so we use
  # has() + tostring to disambiguate "field missing" from "field is false".
  local term_reason
  is_error=$(jq -r 'if has("is_error") then (.is_error|tostring) else "missing" end' "$log_file" 2>/dev/null || printf '%s\n' 'missing')
  term_reason=$(jq -r 'if has("terminal_reason") then (.terminal_reason|tostring) else "missing" end' "$log_file" 2>/dev/null || printf '%s\n' 'missing')
  if [[ "$is_error" == "false" && "$term_reason" == "completed" ]]; then
    exit 0
  fi

  if [[ $rc -ne 0 ]]; then
    exit "$rc"
  fi

  if [[ "$is_error" == "true" ]]; then
    exit 1
  fi
}

#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/ui.sh"
ui_init

CONFIG_PATH="$SCRIPT_DIR/config.json"
STATE_PATH="$SCRIPT_DIR/state.json"
LOGS_BASE="$SCRIPT_DIR/logs"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"
LOCK_DIR="$SCRIPT_DIR/.run.lock"
LOCK_INFO_PATH="$LOCK_DIR/info"

DRY_RUN=0
CHECK_ONLY=0
RESUME_ONLY=0
CLI=""
PROJECT_ROOT=""
GIT_DIR=""
MASTER_PROMPT_PATH=""
OUTPUT_BASE=""
MAX_PARALLEL=3
OUTPUT_WAVE_DIR=""
WAVE_TS=""
LOG_DIR=""
ANY_FAILED=0
DONE_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
LOCK_HELD=0

CHILDREN=()

EXEC_COUNT=0
EXEC_IS_BARRIER=()
EXEC_PARALLEL=()
EXEC_TECHSPEC_PATH=()
EXEC_PROMPT_INLINE=()
EXEC_PROMPT_PATH=()
EXEC_MODEL=()
EXEC_EFFORT=()
EXEC_ID=()
EXEC_OUTPUT_DIR=()
EXEC_WORKTREE_PATH=()
EXEC_WORKTREE_BRANCH=()
EXEC_LOG_PATH=()
EXEC_PROMPT_FILE=()
EXEC_FAILURE_CLASS=()
EXEC_EXIT_CODE=()
EXEC_RESUME_KEY=()

usage() {
  cat <<'EOF'
Usage:
  ./run.sh
  ./run.sh --dry-run
  ./run.sh --check
  ./run.sh --resume
EOF
}

say_err() {
  ui_error "$*"
}

say() {
  ui_info "$*"
}

die() {
  say_err "$1"
  exit "${2:-2}"
}

plan_header() {
  printf '  - %s%s%s %s\n' "${UI_BOLD}" 'exec_id:' "${UI_RESET}" "$1"
}

plan_field() {
  printf '    %s%-15s%s %s\n' "${UI_DIM}" "$1" "${UI_RESET}" "$2"
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

load_adapter() {
  local adapter_path="$ADAPTERS_DIR/$CLI.sh"

  if [[ ! -f "$adapter_path" ]]; then
    die "adapter not found for cli=$CLI: $adapter_path" 2
  fi

  # shellcheck disable=SC1090
  . "$adapter_path"

  command -v adapter_require_cli >/dev/null 2>&1 || die "adapter missing required function: adapter_require_cli" 2
  command -v adapter_validate_execution >/dev/null 2>&1 || die "adapter missing required function: adapter_validate_execution" 2
  command -v adapter_print_execution_plan >/dev/null 2>&1 || die "adapter missing required function: adapter_print_execution_plan" 2
  command -v adapter_run_cli >/dev/null 2>&1 || die "adapter missing required function: adapter_run_cli" 2
}

check_prereqs() {
  require_cmd jq
  require_cmd git
}

cleanup_interrupt() {
  local pid
  say_err 'interrupted; killing children...'
  for pid in "${CHILDREN[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit 130
}

release_lock() {
  if [[ "$LOCK_HELD" == "1" && -d "$LOCK_DIR" ]]; then
    rm -rf "$LOCK_DIR"
    LOCK_HELD=0
  fi
}

trap cleanup_interrupt INT TERM
trap release_lock EXIT

acquire_run_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    {
      printf 'pid=%s\n' "$$"
      printf 'started_at=%s\n' "$(date +%Y%m%d_%H%M%S)"
    } > "$LOCK_INFO_PATH"
    return 0
  fi

  if [[ -f "$LOCK_INFO_PATH" ]]; then
    die "another wave runner process appears to be active for this install dir; inspect $LOCK_INFO_PATH or remove the stale lock if that process is dead" 2
  fi

  die "another wave runner process appears to be active for this install dir: $LOCK_DIR" 2
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

sanitize_name() {
  local value="$1"
  local sanitized

  sanitized=$(printf '%s' "$value" | sed 's/[^A-Za-z0-9_-]/_/g')
  if [[ -z "$sanitized" ]]; then
    sanitized="execution"
  fi
  printf '%s\n' "$sanitized"
}

json_string() {
  local json="$1"
  local filter="$2"
  printf '%s' "$json" | jq -r "$filter"
}

state_exists() {
  [[ -f "$STATE_PATH" ]]
}

init_state() {
  if ! state_exists; then
    printf '%s\n' '{"executions":{}}' > "$STATE_PATH"
  fi
}

state_get_field() {
  local exec_id="$1"
  local field="$2"

  if ! state_exists; then
    printf '%s' ''
    return 0
  fi

  jq -r --arg id "$exec_id" --arg field "$field" '.executions[$id][$field] // empty' "$STATE_PATH"
}

state_set_execution() {
  local exec_id="$1"
  local worktree_path="$2"
  local branch="$3"
  local ts="$4"
  local status="$5"
  local failure_class="$6"
  local exit_code="$7"
  local resume_key="$8"
  local tmp_file

  tmp_file=$(mktemp "$SCRIPT_DIR/state.json.tmp.XXXXXX") || die 'failed to create temporary state file' 2
  jq \
    --arg id "$exec_id" \
    --arg worktree_path "$worktree_path" \
    --arg branch "$branch" \
    --arg ts "$ts" \
    --arg status "$status" \
    --arg failure_class "$failure_class" \
    --arg exit_code "$exit_code" \
    --arg resume_key "$resume_key" \
    '.executions[$id] = {
      "worktree_path": $worktree_path,
      "branch": $branch,
      "last_run_ts": $ts,
      "last_status": $status,
      "last_failure_class": (if $failure_class == "" then null else $failure_class end),
      "last_exit_code": (if $exit_code == "" then null else $exit_code end),
      "resume_key": (if $resume_key == "" then null else $resume_key end)
    }' \
    "$STATE_PATH" > "$tmp_file" || {
      rm -f "$tmp_file"
      die 'failed to update state.json' 2
    }
  mv "$tmp_file" "$STATE_PATH"
}

git_worktree_list_has_path() {
  local path="$1"
  git -C "$GIT_DIR" worktree list --porcelain 2>/dev/null | grep -F -x "worktree $path" >/dev/null 2>&1
}

git_branch_exists() {
  local branch="$1"
  git -C "$GIT_DIR" show-ref --verify --quiet "refs/heads/$branch"
}

worktree_is_clean() {
  local path="$1"
  [[ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ]]
}

unique_exec_id() {
  local candidate="$1"
  local unique="$candidate"
  local suffix=2
  local found
  local existing

  while :; do
    found=0
    for existing in "${EXEC_ID[@]}"; do
      if [[ "$existing" == "$unique" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      printf '%s\n' "$unique"
      return 0
    fi
    unique="${candidate}_$suffix"
    suffix=$((suffix + 1))
  done
}

hash_file() {
  local path="$1"
  git hash-object "$path" 2>/dev/null || return 1
}

hash_string() {
  local value="$1"
  printf '%s' "$value" | git hash-object --stdin 2>/dev/null || return 1
}

build_resume_key() {
  local idx="$1"
  local techspec_hash
  local prompt_file_hash=""
  local prompt_inline_hash=""
  local master_hash

  techspec_hash=$(hash_file "${EXEC_TECHSPEC_PATH[$idx]}") || die "failed to hash techspec for executions[$idx]" 2
  master_hash=$(hash_file "$MASTER_PROMPT_PATH") || die 'failed to hash master prompt' 2

  if [[ -n "${EXEC_PROMPT_PATH[$idx]}" ]]; then
    prompt_file_hash=$(hash_file "${EXEC_PROMPT_PATH[$idx]}") || die "failed to hash prompt_path for executions[$idx]" 2
  fi

  if [[ -n "${EXEC_PROMPT_INLINE[$idx]}" ]]; then
    prompt_inline_hash=$(hash_string "${EXEC_PROMPT_INLINE[$idx]}") || die "failed to hash inline prompt for executions[$idx]" 2
  fi

  printf '%s\n' "cli=$CLI
model=${EXEC_MODEL[$idx]}
effort=${EXEC_EFFORT[$idx]}
master_hash=$master_hash
techspec_hash=$techspec_hash
prompt_path_hash=$prompt_file_hash
prompt_inline_hash=$prompt_inline_hash" | git hash-object --stdin
}

execution_resume_status() {
  local idx="$1"
  local status
  local state_key

  status=$(state_get_field "${EXEC_ID[$idx]}" 'last_status')
  state_key=$(state_get_field "${EXEC_ID[$idx]}" 'resume_key')

  if [[ "$status" == "done" && -n "$state_key" && "$state_key" == "${EXEC_RESUME_KEY[$idx]}" ]]; then
    printf '%s\n' 'done'
    return 0
  fi

  if [[ "$status" == "running" && -n "$state_key" && "$state_key" == "${EXEC_RESUME_KEY[$idx]}" ]]; then
    printf '%s\n' 'stale_running'
    return 0
  fi

  if [[ -n "$status" ]]; then
    printf '%s\n' "$status"
    return 0
  fi

  printf '%s\n' 'never_run'
}

execution_should_run() {
  local idx="$1"
  local resume_status

  if [[ "$RESUME_ONLY" != "1" ]]; then
    return 0
  fi

  resume_status=$(execution_resume_status "$idx")
  [[ "$resume_status" != "done" ]]
}

validate_top_level_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    die "$label not found: $path" 2
  fi
}

validate_directory_path() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" ]]; then
    die "$label does not exist: $path" 2
  fi
}

validate_or_create_output_base() {
  local parent

  if [[ -e "$OUTPUT_BASE" && ! -d "$OUTPUT_BASE" ]]; then
    die "output_base exists but is not a directory: $OUTPUT_BASE" 2
  fi

  if [[ "$DRY_RUN" == "1" || "$CHECK_ONLY" == "1" ]]; then
    if [[ -d "$OUTPUT_BASE" ]]; then
      [[ -w "$OUTPUT_BASE" ]] || die "output_base is not writable: $OUTPUT_BASE" 2
      return 0
    fi

    parent=$(dirname "$OUTPUT_BASE")
    while [[ ! -d "$parent" && "$parent" != "/" ]]; do
      parent=$(dirname "$parent")
    done
    [[ -d "$parent" && -w "$parent" ]] || die "output_base parent is not writable: $parent" 2
    return 0
  fi

  if mkdir -p "$OUTPUT_BASE" >/dev/null 2>&1 && [[ -w "$OUTPUT_BASE" ]]; then
    return 0
  fi
  die "output_base is not writable or could not be created: $OUTPUT_BASE" 2
}

load_config() {
  local parallel_streak=0
  local i
  local entry_json
  local key_count
  local parallel
  local techspec_raw
  local prompt_inline
  local prompt_path_raw
  local model
  local effort
  local techspec_abs
  local prompt_path_abs
  local base_name
  local bare_name
  local base_exec_id

  validate_top_level_file "$CONFIG_PATH" 'config.json'
  jq empty "$CONFIG_PATH" >/dev/null 2>&1 || die "invalid JSON in $CONFIG_PATH" 2

  CLI=$(jq -r '.cli // empty' "$CONFIG_PATH")
  PROJECT_ROOT=$(jq -r '.project_root // empty' "$CONFIG_PATH")
  GIT_DIR=$(jq -r '.git_dir // empty' "$CONFIG_PATH")
  MASTER_PROMPT_PATH=$(jq -r '.master_prompt_path // empty' "$CONFIG_PATH")
  OUTPUT_BASE=$(jq -r '.output_base // empty' "$CONFIG_PATH")
  MAX_PARALLEL=$(jq -r '.max_parallel // 3' "$CONFIG_PATH")

  [[ -n "$CLI" ]] || die 'config.json missing required field: cli' 2
  [[ -n "$PROJECT_ROOT" ]] || die 'config.json missing required field: project_root' 2
  [[ -n "$GIT_DIR" ]] || die 'config.json missing required field: git_dir' 2
  [[ -n "$MASTER_PROMPT_PATH" ]] || die 'config.json missing required field: master_prompt_path' 2
  [[ -n "$OUTPUT_BASE" ]] || die 'config.json missing required field: output_base' 2

  if [[ "$CLI" != "claude" && "$CLI" != "codex" ]]; then
    die "config.json field cli must be \"claude\" or \"codex\"; got: $CLI" 2
  fi
  if ! [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
    die "config.json field max_parallel must be a positive integer; got: $MAX_PARALLEL" 2
  fi
  load_adapter
  adapter_require_cli

  PROJECT_ROOT=$(normalize_path "$PROJECT_ROOT" "$SCRIPT_DIR")
  GIT_DIR=$(normalize_path "$GIT_DIR" "$SCRIPT_DIR")
  MASTER_PROMPT_PATH=$(normalize_path "$MASTER_PROMPT_PATH" "$SCRIPT_DIR")
  OUTPUT_BASE=$(normalize_path "$OUTPUT_BASE" "$SCRIPT_DIR")

  validate_directory_path "$PROJECT_ROOT" 'project_root'
  validate_directory_path "$GIT_DIR" 'git_dir'
  git -C "$GIT_DIR" rev-parse --show-toplevel >/dev/null 2>&1 || die "git_dir is not a git repository: $GIT_DIR" 2
  validate_top_level_file "$MASTER_PROMPT_PATH" 'master prompt'
  validate_or_create_output_base

  jq -e '.executions | type == "array"' "$CONFIG_PATH" >/dev/null 2>&1 || die 'config.json field executions must be an array' 2
  EXEC_COUNT=$(jq '.executions | length' "$CONFIG_PATH") || die 'config.json field executions must be an array' 2
  for ((i=0; i<EXEC_COUNT; i++)); do
    entry_json=$(jq -c ".executions[$i]" "$CONFIG_PATH") || die "failed to read executions[$i]" 2
    key_count=$(json_string "$entry_json" 'keys_unsorted | length')
    parallel=$(json_string "$entry_json" '.parallel // empty')
    techspec_raw=$(json_string "$entry_json" '.techspec_path // empty')
    prompt_inline=$(json_string "$entry_json" '.prompt // empty')
    prompt_path_raw=$(json_string "$entry_json" '.prompt_path // empty')
    model=$(json_string "$entry_json" '.model // empty')
    effort=$(json_string "$entry_json" '.effort // empty')

    [[ -n "$parallel" ]] || die "executions[$i] missing required field: parallel" 2
    if [[ "$parallel" != "yes" && "$parallel" != "no" ]]; then
      die "executions[$i].parallel must be \"yes\" or \"no\"; got: $parallel" 2
    fi

    if [[ -z "$techspec_raw" ]]; then
      if [[ "$parallel" == "no" && "$key_count" -eq 1 ]]; then
        EXEC_IS_BARRIER[$i]="1"
        EXEC_PARALLEL[$i]="$parallel"
        EXEC_TECHSPEC_PATH[$i]=""
        EXEC_PROMPT_INLINE[$i]=""
        EXEC_PROMPT_PATH[$i]=""
        EXEC_MODEL[$i]=""
        EXEC_EFFORT[$i]=""
        EXEC_ID[$i]=""
        parallel_streak=0
        continue
      fi
      die "executions[$i] is invalid; non-empty entries require techspec_path and barrier entries must be exactly {\"parallel\":\"no\"}" 2
    fi

    [[ -n "$model" ]] || die "executions[$i] missing required field: model" 2
    if [[ -z "$prompt_inline" && -z "$prompt_path_raw" ]]; then
      die "executions[$i] requires at least one of prompt or prompt_path" 2
    fi

    techspec_abs=$(normalize_path "$techspec_raw" "$SCRIPT_DIR")
    [[ -f "$techspec_abs" ]] || die "techspec not found for executions[$i]: $techspec_abs" 2

    prompt_path_abs=""
    if [[ -n "$prompt_path_raw" ]]; then
      prompt_path_abs=$(normalize_path "$prompt_path_raw" "$SCRIPT_DIR")
      [[ -f "$prompt_path_abs" ]] || die "prompt_path not found for executions[$i]: $prompt_path_abs" 2
    fi

    base_name=$(basename "$techspec_raw")
    bare_name="${base_name%.*}"
    base_exec_id=$(printf '%02d_%s' $((i + 1)) "$(sanitize_name "$bare_name")")

    EXEC_IS_BARRIER[$i]="0"
    EXEC_PARALLEL[$i]="$parallel"
    EXEC_TECHSPEC_PATH[$i]="$techspec_abs"
    EXEC_PROMPT_INLINE[$i]="$prompt_inline"
    EXEC_PROMPT_PATH[$i]="$prompt_path_abs"
    EXEC_MODEL[$i]="$model"
    EXEC_EFFORT[$i]="$effort"
    EXEC_ID[$i]="$(unique_exec_id "$base_exec_id")"
    adapter_validate_execution "$i"
    EXEC_RESUME_KEY[$i]="$(build_resume_key "$i")"

    if [[ "$parallel" == "yes" ]]; then
      parallel_streak=$((parallel_streak + 1))
      if [[ $parallel_streak -gt $MAX_PARALLEL ]]; then
        die "config.json has more than $MAX_PARALLEL consecutive parallel executions ending at executions[$i]; insert {\"parallel\":\"no\"} batch breaks manually or raise max_parallel" 2
      fi
    else
      parallel_streak=0
    fi
  done
}

resolve_worktree_plan() {
  local idx="$1"
  local exec_id="${EXEC_ID[$idx]}"
  local state_path
  local state_branch
  local candidate_exec_id
  local candidate_path
  local candidate_branch
  local suffix_ts
  local suffix=1

  state_path=$(state_get_field "$exec_id" 'worktree_path')
  state_branch=$(state_get_field "$exec_id" 'branch')

  if [[ -n "$state_path" ]] && git_worktree_list_has_path "$state_path"; then
    EXEC_WORKTREE_PATH[$idx]="$state_path"
    if [[ -n "$state_branch" ]]; then
      EXEC_WORKTREE_BRANCH[$idx]="$state_branch"
    else
      EXEC_WORKTREE_BRANCH[$idx]="$exec_id"
    fi
    return 0
  fi

  candidate_exec_id="$exec_id"
  suffix_ts=$(date +%Y%m%d_%H%M%S)

  while :; do
    candidate_path="$GIT_DIR/.worktrees/$candidate_exec_id"
    candidate_branch="$candidate_exec_id"
    if [[ ! -e "$candidate_path" ]] && ! git_worktree_list_has_path "$candidate_path"; then
      EXEC_ID[$idx]="$candidate_exec_id"
      EXEC_WORKTREE_PATH[$idx]="$candidate_path"
      EXEC_WORKTREE_BRANCH[$idx]="$candidate_branch"
      return 0
    fi

    if [[ $suffix -eq 1 ]]; then
      candidate_exec_id="${exec_id}_$suffix_ts"
    else
      candidate_exec_id="${exec_id}_$suffix_ts_$suffix"
    fi
    suffix=$((suffix + 1))
  done
}

ensure_worktree() {
  local idx="$1"
  local path="${EXEC_WORKTREE_PATH[$idx]}"
  local branch="${EXEC_WORKTREE_BRANCH[$idx]}"
  local log_file="${EXEC_LOG_PATH[$idx]}"

  if git_worktree_list_has_path "$path"; then
    if ! worktree_is_clean "$path"; then
      printf '%s\n' "tracked worktree is not clean: $path" > "$log_file"
      printf '%s\n' 'clean or remove the worktree manually before rerunning this execution' >> "$log_file"
      return 10
    fi
    return 0
  fi

  mkdir -p "$GIT_DIR/.worktrees"

  if git_branch_exists "$branch"; then
    git -C "$GIT_DIR" worktree add "$path" "$branch" > "$log_file" 2>&1 || return 11
  else
    git -C "$GIT_DIR" worktree add -b "$branch" "$path" > "$log_file" 2>&1 || return 11
  fi
}

prepare_execution() {
  local idx="$1"
  local exec_id
  local output_dir
  local prompt_file
  local log_file
  local prompt_inline
  local prompt_path

  resolve_worktree_plan "$idx"
  exec_id="${EXEC_ID[$idx]}"
  output_dir="$OUTPUT_WAVE_DIR/$exec_id"
  prompt_file="$LOG_DIR/$exec_id.prompt.md"
  log_file="$LOG_DIR/$exec_id.log"
  prompt_inline="${EXEC_PROMPT_INLINE[$idx]}"
  prompt_path="${EXEC_PROMPT_PATH[$idx]}"

  EXEC_OUTPUT_DIR[$idx]="$output_dir"
  EXEC_PROMPT_FILE[$idx]="$prompt_file"
  EXEC_LOG_PATH[$idx]="$log_file"

  if ! mkdir -p "$output_dir" >/dev/null 2>&1; then
    return 20
  fi

  if ! {
    cat "$MASTER_PROMPT_PATH"
    printf '\n\n---\n\n'
    if [[ -n "$prompt_inline" ]]; then
      printf '%s\n\n' "$prompt_inline"
    fi
    if [[ -n "$prompt_path" ]]; then
      cat "$prompt_path"
      printf '\n\n'
    fi
    printf '%s\n' '---'
    printf '\n## Techspec\n'
    printf 'Read your techspec at: %s\n' "${EXEC_TECHSPEC_PATH[$idx]}"
    printf '\n## Output directory\n'
    printf 'Write all deliverables to: %s/\n' "$output_dir"
  } > "$prompt_file"; then
    return 21
  fi

  return 0
}

print_execution_plan() {
  local idx="$1"

  resolve_worktree_plan "$idx"

  plan_header "${EXEC_ID[$idx]}"
  plan_field 'model' "${EXEC_MODEL[$idx]}"
  adapter_print_execution_plan "$idx"
  if [[ -n "${EXEC_PROMPT_INLINE[$idx]}" ]]; then
    plan_field 'prompt' 'inline'
  fi
  if [[ -n "${EXEC_PROMPT_PATH[$idx]}" ]]; then
    plan_field 'prompt_path' "${EXEC_PROMPT_PATH[$idx]}"
  fi
  plan_field 'techspec' "${EXEC_TECHSPEC_PATH[$idx]}"
  plan_field 'worktree' "${EXEC_WORKTREE_PATH[$idx]}"
  plan_field 'output_dir' "$OUTPUT_WAVE_DIR/${EXEC_ID[$idx]}/"
}

classify_task_failure() {
  local log_file="$1"
  local exit_code="$2"

  if [[ "$exit_code" == "127" ]]; then
    printf '%s\n' 'cli_not_found'
    return 0
  fi

  if [[ ! -f "$log_file" ]]; then
    printf '%s\n' 'unknown'
    return 0
  fi

  if grep -E -i 'rate limit|rate-limit|too many requests|429|quota|usage limit|capacity|try again later' "$log_file" >/dev/null 2>&1; then
    printf '%s\n' 'rate_limit'
    return 0
  fi

  if grep -E -i 'authentication|unauthorized|forbidden|api key|not logged in|login required|invalid credential|invalid token|permission denied|auth' "$log_file" >/dev/null 2>&1; then
    printf '%s\n' 'auth_error'
    return 0
  fi

  if grep -E -i 'approval|requires approval|ask for approval|permission prompt|cannot ask|dontask|sandbox denied|denied by sandbox|blocked by sandbox|blocked by permission|disallowed tool|tool denied|cannot use tool|operation not permitted' "$log_file" >/dev/null 2>&1; then
    printf '%s\n' 'permission_denied'
    return 0
  fi

  if grep -E -i 'network|timed out|timeout|connection reset|connection refused|temporary failure|dns|enotfound|econn|tls|ssl' "$log_file" >/dev/null 2>&1; then
    printf '%s\n' 'network_error'
    return 0
  fi

  if grep -E -i 'interrupted|cancelled|canceled|terminated by signal|sigint|sigterm' "$log_file" >/dev/null 2>&1; then
    printf '%s\n' 'interrupted'
    return 0
  fi

  printf '%s\n' 'unknown'
}

run_task_async() {
  local idx="$1"
  adapter_run_cli \
    "${EXEC_PROMPT_FILE[$idx]}" \
    "${EXEC_LOG_PATH[$idx]}" \
    "${EXEC_WORKTREE_PATH[$idx]}" \
    "${EXEC_MODEL[$idx]}" \
    "${EXEC_EFFORT[$idx]}" \
    "${EXEC_OUTPUT_DIR[$idx]}"
}

mark_running() {
  local idx="$1"
  state_set_execution \
    "${EXEC_ID[$idx]}" \
    "${EXEC_WORKTREE_PATH[$idx]}" \
    "${EXEC_WORKTREE_BRANCH[$idx]}" \
    "$WAVE_TS" \
    'running' \
    '' \
    '' \
    "${EXEC_RESUME_KEY[$idx]}"
}

mark_finished() {
  local idx="$1"
  local status="$2"
  local failure_class="$3"
  local exit_code="$4"
  state_set_execution \
    "${EXEC_ID[$idx]}" \
    "${EXEC_WORKTREE_PATH[$idx]}" \
    "${EXEC_WORKTREE_BRANCH[$idx]}" \
    "$WAVE_TS" \
    "$status" \
    "$failure_class" \
    "$exit_code" \
    "${EXEC_RESUME_KEY[$idx]}"
}

mark_skipped() {
  local idx="$1"
  local existing_path
  local existing_branch

  existing_path=$(state_get_field "${EXEC_ID[$idx]}" 'worktree_path')
  existing_branch=$(state_get_field "${EXEC_ID[$idx]}" 'branch')

  state_set_execution \
    "${EXEC_ID[$idx]}" \
    "$existing_path" \
    "$existing_branch" \
    "$WAVE_TS" \
    'skipped' \
    'fail_fast' \
    '' \
    "${EXEC_RESUME_KEY[$idx]}"
}

mark_stale_running_resumed() {
  local idx="$1"
  state_set_execution \
    "${EXEC_ID[$idx]}" \
    "${EXEC_WORKTREE_PATH[$idx]}" \
    "${EXEC_WORKTREE_BRANCH[$idx]}" \
    "$WAVE_TS" \
    'failed' \
    'interrupted' \
    '' \
    "${EXEC_RESUME_KEY[$idx]}"
}

run_batch() {
  local -a batch_indices
  local -a batch_pids
  local -a launched_indices
  local idx
  local pid
  local i
  local rc
  local status
  local failure_class
  local batch_failed=0
  local resume_status

  batch_indices=("$@")
  batch_pids=()
  launched_indices=()
  CHILDREN=()

  for idx in "${batch_indices[@]}"; do
    if ! execution_should_run "$idx"; then
      DONE_COUNT=$((DONE_COUNT + 1))
      ui_status_line 'SKIPPED' "${EXEC_ID[$idx]}" 'already done in matching prior run'
      continue
    fi

    prepare_execution "$idx"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      failure_class='prompt_build_error'
      case "$rc" in
        20)
          printf '%s\n' "output directory could not be created: ${EXEC_OUTPUT_DIR[$idx]}" > "${EXEC_LOG_PATH[$idx]}"
          ;;
        21)
          printf '%s\n' "failed to write assembled prompt file: ${EXEC_PROMPT_FILE[$idx]}" > "${EXEC_LOG_PATH[$idx]}"
          ;;
        *)
          printf '%s\n' "failed to prepare execution artifacts for: ${EXEC_ID[$idx]}" > "${EXEC_LOG_PATH[$idx]}"
          ;;
      esac
      EXEC_FAILURE_CLASS[$idx]="$failure_class"
      EXEC_EXIT_CODE[$idx]=''
      mark_finished "$idx" 'failed' "$failure_class" ''
      ui_status_line 'FAILED' "${EXEC_ID[$idx]}" "$failure_class | log=${EXEC_LOG_PATH[$idx]}"
      batch_failed=1
      ANY_FAILED=1
      FAILED_COUNT=$((FAILED_COUNT + 1))
      continue
    fi

    ensure_worktree "$idx"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      case "$rc" in
        10) failure_class='dirty_worktree' ;;
        *) failure_class='worktree_error' ;;
      esac
      EXEC_FAILURE_CLASS[$idx]="$failure_class"
      EXEC_EXIT_CODE[$idx]=''
      mark_finished "$idx" 'failed' "$failure_class" ''
      ui_status_line 'FAILED' "${EXEC_ID[$idx]}" "$failure_class | log=${EXEC_LOG_PATH[$idx]}"
      batch_failed=1
      ANY_FAILED=1
      FAILED_COUNT=$((FAILED_COUNT + 1))
      continue
    fi

    if [[ "$RESUME_ONLY" == "1" ]]; then
      resume_status=$(execution_resume_status "$idx")
      if [[ "$resume_status" == "stale_running" ]]; then
        mark_stale_running_resumed "$idx"
        ui_status_line 'RESUME' "${EXEC_ID[$idx]}" 'stale running state detected'
      fi
    fi

    ui_status_line 'START' "${EXEC_ID[$idx]}" "model=${EXEC_MODEL[$idx]} | worktree=${EXEC_WORKTREE_PATH[$idx]}"
    mark_running "$idx"
    run_task_async "$idx" &
    pid=$!
    CHILDREN+=("$pid")
    batch_pids+=("$pid")
    launched_indices+=("$idx")
  done

  for ((i=0; i<${#batch_pids[@]}; i++)); do
    pid="${batch_pids[$i]}"
    idx="${launched_indices[$i]}"
    if wait "$pid"; then
      rc=0
      status='done'
      failure_class=''
      DONE_COUNT=$((DONE_COUNT + 1))
    else
      rc=$?
      status='failed'
      failure_class=$(classify_task_failure "${EXEC_LOG_PATH[$idx]}" "$rc")
      batch_failed=1
      ANY_FAILED=1
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    EXEC_FAILURE_CLASS[$idx]="$failure_class"
    EXEC_EXIT_CODE[$idx]="$rc"
    if [[ $rc -eq 0 ]]; then
      mark_finished "$idx" "$status" '' '0'
    else
      mark_finished "$idx" "$status" "$failure_class" "$rc"
    fi
    if [[ $rc -eq 0 ]]; then
      ui_status_line 'DONE' "${EXEC_ID[$idx]}" "log=${EXEC_LOG_PATH[$idx]}"
    else
      ui_status_line 'FAILED' "${EXEC_ID[$idx]}" "$failure_class | log=${EXEC_LOG_PATH[$idx]}"
    fi
  done

  CHILDREN=()

  if [[ $batch_failed -ne 0 ]]; then
    return 1
  fi

  return 0
}

run_dry_run() {
  local -a batch
  local batch_num=1
  local i

  batch=()

  if [[ $EXEC_COUNT -eq 0 ]]; then
    printf '%s\n' 'No executions configured.'
    return 0
  fi

  for ((i=0; i<EXEC_COUNT; i++)); do
    if [[ "${EXEC_IS_BARRIER[$i]}" == "1" ]]; then
      if [[ ${#batch[@]} -gt 0 ]]; then
        ui_subheading "Batch $batch_num"
        print_batch "${batch[@]}"
        batch_num=$((batch_num + 1))
        batch=()
      fi
      continue
    fi

    if [[ "${EXEC_PARALLEL[$i]}" == "yes" ]]; then
      batch+=("$i")
    else
      if [[ ${#batch[@]} -gt 0 ]]; then
        ui_subheading "Batch $batch_num"
        print_batch "${batch[@]}"
        batch_num=$((batch_num + 1))
        batch=()
      fi
      ui_subheading "Batch $batch_num"
      print_batch "$i"
      batch_num=$((batch_num + 1))
    fi
  done

  if [[ ${#batch[@]} -gt 0 ]]; then
    ui_subheading "Batch $batch_num"
    print_batch "${batch[@]}"
  fi
}

print_batch() {
  local idx
  for idx in "$@"; do
    print_execution_plan "$idx"
  done
}

count_non_barrier_from() {
  local start_idx="$1"
  local i
  local count=0

  for ((i=start_idx; i<EXEC_COUNT; i++)); do
    if [[ "${EXEC_IS_BARRIER[$i]}" != "1" ]]; then
      count=$((count + 1))
    fi
  done

  printf '%s\n' "$count"
}

mark_remaining_skipped_from() {
  local start_idx="$1"
  local i
  local skipped=0

  for ((i=start_idx; i<EXEC_COUNT; i++)); do
    if [[ "${EXEC_IS_BARRIER[$i]}" == "1" ]]; then
      continue
    fi
    if [[ "$RESUME_ONLY" == "1" ]] && ! execution_should_run "$i"; then
      continue
    fi
    mark_skipped "$i"
    skipped=$((skipped + 1))
  done

  printf '%s\n' "$skipped"
}

describe_state_worktree() {
  local path="$1"

  if [[ -z "$path" ]]; then
    printf '%s\n' 'none'
    return 0
  fi

  if git_worktree_list_has_path "$path"; then
    if worktree_is_clean "$path"; then
      printf '%s\n' 'tracked-clean'
    else
      printf '%s\n' 'tracked-dirty'
    fi
    return 0
  fi

  if [[ -e "$path" ]]; then
    printf '%s\n' 'path-exists-untracked'
  else
    printf '%s\n' 'missing'
  fi
}

run_check() {
  local i
  local status
  local failure_class
  local exit_code
  local worktree_path
  local branch
  local worktree_state
  local resume_key
  local resume_status

  ui_heading 'Config Check'
  ui_success 'Config check passed'
  ui_kv 'CLI' "$CLI"
  ui_kv 'Project root' "$PROJECT_ROOT"
  ui_kv 'Git dir' "$GIT_DIR"
  ui_kv 'Master prompt' "$MASTER_PROMPT_PATH"
  ui_kv 'Output base' "$OUTPUT_BASE"
  ui_kv 'Max parallel' "$MAX_PARALLEL"
  printf '\n'
  ui_heading 'Planned Batches'
  run_dry_run
  printf '\n'
  ui_heading 'Tracked Execution State'

  if [[ $EXEC_COUNT -eq 0 ]]; then
    ui_note 'No executions configured.'
    return 0
  fi

  for ((i=0; i<EXEC_COUNT; i++)); do
    if [[ "${EXEC_IS_BARRIER[$i]}" == "1" ]]; then
      continue
    fi

    status=$(state_get_field "${EXEC_ID[$i]}" 'last_status')
    failure_class=$(state_get_field "${EXEC_ID[$i]}" 'last_failure_class')
    exit_code=$(state_get_field "${EXEC_ID[$i]}" 'last_exit_code')
    worktree_path=$(state_get_field "${EXEC_ID[$i]}" 'worktree_path')
    branch=$(state_get_field "${EXEC_ID[$i]}" 'branch')
    resume_key=$(state_get_field "${EXEC_ID[$i]}" 'resume_key')
    worktree_state=$(describe_state_worktree "$worktree_path")
    resume_status=$(execution_resume_status "$i")

    if [[ -z "$status" ]]; then
      status='never_run'
    fi
    if [[ -z "$failure_class" ]]; then
      failure_class='-'
    fi
    if [[ -z "$exit_code" ]]; then
      exit_code='-'
    fi
    if [[ -z "$branch" ]]; then
      branch='-'
    fi
    if [[ -z "$worktree_path" ]]; then
      worktree_path='-'
    fi

    plan_header "${EXEC_ID[$i]}"
    plan_field 'status' "$status"
    plan_field 'failure_class' "$failure_class"
    plan_field 'exit_code' "$exit_code"
    plan_field 'branch' "$branch"
    plan_field 'worktree' "$worktree_path"
    plan_field 'worktree_state' "$worktree_state"
    plan_field 'resume_status' "$resume_status"
    if [[ -n "$resume_key" && "$resume_key" == "${EXEC_RESUME_KEY[$i]}" ]]; then
      plan_field 'resume_match' 'yes'
    else
      plan_field 'resume_match' 'no'
    fi
  done
}

run_execute() {
  local -a batch
  local i
  local batch_num=1
  local batch_rc=0
  local stop_after_failure=0
  local remaining_count=0

  acquire_run_lock
  init_state
  mkdir -p "$LOG_DIR" "$OUTPUT_WAVE_DIR" >/dev/null 2>&1 || die "failed to create log or output directories for wave: $WAVE_TS" 2
  batch=()

  ui_heading 'Wave Run'
  ui_kv 'Wave started' "$WAVE_TS"
  ui_kv 'CLI' "$CLI"
  ui_kv 'Max parallel' "$MAX_PARALLEL"
  if [[ "$RESUME_ONLY" == "1" ]]; then
    ui_kv 'Mode' 'resume'
  fi
  ui_kv 'Logs' "$LOG_DIR"
  ui_kv 'Output' "$OUTPUT_WAVE_DIR"
  printf '\n'

  for ((i=0; i<EXEC_COUNT; i++)); do
    if [[ "${EXEC_IS_BARRIER[$i]}" == "1" ]]; then
      if [[ ${#batch[@]} -gt 0 ]]; then
        ui_status_line 'BATCH' "Batch $batch_num" "${#batch[@]} execution(s) in parallel"
        run_batch "${batch[@]}"
        batch_rc=$?
        batch_num=$((batch_num + 1))
        batch=()
        if [[ $batch_rc -ne 0 ]]; then
          stop_after_failure=1
          remaining_count=$(mark_remaining_skipped_from $((i + 1)))
          break
        fi
      fi
      continue
    fi

    if [[ "${EXEC_PARALLEL[$i]}" == "yes" ]]; then
      batch+=("$i")
    else
      if [[ ${#batch[@]} -gt 0 ]]; then
        ui_status_line 'BATCH' "Batch $batch_num" "${#batch[@]} execution(s) in parallel"
        run_batch "${batch[@]}"
        batch_rc=$?
        batch_num=$((batch_num + 1))
        batch=()
        if [[ $batch_rc -ne 0 ]]; then
          stop_after_failure=1
          remaining_count=$(mark_remaining_skipped_from "$i")
          break
        fi
      fi
      ui_status_line 'BATCH' "Batch $batch_num" '1 execution in sequence'
      run_batch "$i"
      batch_rc=$?
      batch_num=$((batch_num + 1))
      if [[ $batch_rc -ne 0 ]]; then
        stop_after_failure=1
        remaining_count=$(mark_remaining_skipped_from $((i + 1)))
        break
      fi
    fi
  done

  if [[ $stop_after_failure -eq 0 && ${#batch[@]} -gt 0 ]]; then
    ui_status_line 'BATCH' "Batch $batch_num" "${#batch[@]} execution(s) in parallel"
    run_batch "${batch[@]}"
    batch_rc=$?
    batch_num=$((batch_num + 1))
    if [[ $batch_rc -ne 0 ]]; then
      stop_after_failure=1
    fi
  fi

  if [[ $stop_after_failure -ne 0 ]]; then
    SKIPPED_COUNT=$remaining_count
    if [[ $remaining_count -gt 0 ]]; then
      ui_warn 'Fail-fast: stopping before later batches because the previous batch failed'
      ui_kv 'Skipped executions' "$remaining_count"
    else
      ui_warn 'Fail-fast: no later batches were launched because the previous batch failed'
    fi
  fi

  printf '\n'
  ui_heading 'Summary'
  ui_kv 'Done' "$DONE_COUNT"
  ui_kv 'Failed' "$FAILED_COUNT"
  ui_kv 'Skipped' "$SKIPPED_COUNT"
  if [[ $ANY_FAILED -ne 0 ]]; then
    exit 1
  fi
}

main() {
  if [[ $# -gt 1 ]]; then
    usage
    exit 2
  fi

  if [[ $# -eq 1 ]]; then
    if [[ "$1" == "--dry-run" ]]; then
      DRY_RUN=1
    elif [[ "$1" == "--check" ]]; then
      CHECK_ONLY=1
    elif [[ "$1" == "--resume" ]]; then
      RESUME_ONLY=1
    else
      usage
      exit 2
    fi
  fi

  check_prereqs
  load_config
  WAVE_TS=$(date +%Y%m%d_%H%M%S)
  LOG_DIR="$LOGS_BASE/$WAVE_TS"
  OUTPUT_WAVE_DIR="$OUTPUT_BASE/$WAVE_TS"

  if [[ $CHECK_ONLY -eq 1 ]]; then
    run_check
  elif [[ $DRY_RUN -eq 1 ]]; then
    run_dry_run
  else
    run_execute
  fi
}

main "$@"

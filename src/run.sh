#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
CONFIG_PATH="$SCRIPT_DIR/config.json"
STATE_PATH="$SCRIPT_DIR/state.json"
LOGS_BASE="$SCRIPT_DIR/logs"

DRY_RUN=0
CLI=""
PROJECT_ROOT=""
GIT_DIR=""
MASTER_PROMPT_PATH=""
OUTPUT_BASE=""
WAVE_TS=""
LOG_DIR=""
ANY_FAILED=0
DONE_COUNT=0
FAILED_COUNT=0

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

usage() {
  cat <<'EOF'
Usage:
  ./run.sh
  ./run.sh --dry-run
EOF
}

say_err() {
  printf '%s\n' "$*" >&2
}

die() {
  say_err "$1"
  exit "${2:-2}"
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

cleanup() {
  local pid
  say_err 'interrupted; killing children...'
  for pid in "${CHILDREN[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit 130
}

trap cleanup INT TERM

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
  local tmp_file

  tmp_file=$(mktemp "$SCRIPT_DIR/state.json.tmp.XXXXXX") || die 'failed to create temporary state file' 2
  jq \
    --arg id "$exec_id" \
    --arg worktree_path "$worktree_path" \
    --arg branch "$branch" \
    --arg ts "$ts" \
    --arg status "$status" \
    '.executions[$id] = {
      "worktree_path": $worktree_path,
      "branch": $branch,
      "last_run_ts": $ts,
      "last_status": $status
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

unique_exec_id() {
  local candidate="$1"
  local ts="$2"
  local unique="$candidate"
  local suffix=1
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
    if [[ $suffix -eq 1 ]]; then
      unique="${candidate}_$ts"
    else
      unique="${candidate}_$ts_$suffix"
    fi
    suffix=$((suffix + 1))
  done
}

validate_top_level_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    die "$label not found: $path" 2
  fi
}

load_config() {
  local parse_ts
  local codex_effort_warned=0
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

  [[ -n "$CLI" ]] || die 'config.json missing required field: cli' 2
  [[ -n "$PROJECT_ROOT" ]] || die 'config.json missing required field: project_root' 2
  [[ -n "$GIT_DIR" ]] || die 'config.json missing required field: git_dir' 2
  [[ -n "$MASTER_PROMPT_PATH" ]] || die 'config.json missing required field: master_prompt_path' 2
  [[ -n "$OUTPUT_BASE" ]] || die 'config.json missing required field: output_base' 2

  if [[ "$CLI" != "claude" && "$CLI" != "codex" ]]; then
    die "config.json field cli must be \"claude\" or \"codex\"; got: $CLI" 2
  fi

  PROJECT_ROOT=$(normalize_path "$PROJECT_ROOT" "$SCRIPT_DIR")
  GIT_DIR=$(normalize_path "$GIT_DIR" "$SCRIPT_DIR")
  MASTER_PROMPT_PATH=$(normalize_path "$MASTER_PROMPT_PATH" "$SCRIPT_DIR")
  OUTPUT_BASE=$(normalize_path "$OUTPUT_BASE" "$SCRIPT_DIR")

  [[ -d "$PROJECT_ROOT" ]] || die "project_root does not exist: $PROJECT_ROOT" 2
  [[ -d "$GIT_DIR" ]] || die "git_dir does not exist: $GIT_DIR" 2
  git -C "$GIT_DIR" rev-parse --show-toplevel >/dev/null 2>&1 || die "git_dir is not a git repository: $GIT_DIR" 2
  validate_top_level_file "$MASTER_PROMPT_PATH" 'master prompt'

  jq -e '.executions | type == "array"' "$CONFIG_PATH" >/dev/null 2>&1 || die 'config.json field executions must be an array' 2
  EXEC_COUNT=$(jq '.executions | length' "$CONFIG_PATH") || die 'config.json field executions must be an array' 2
  parse_ts=$(date +%Y%m%d_%H%M%S)

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
        continue
      fi
      die "executions[$i] is invalid; non-empty entries require techspec_path and barrier entries must be exactly {\"parallel\":\"no\"}" 2
    fi

    [[ -n "$model" ]] || die "executions[$i] missing required field: model" 2
    if [[ -z "$prompt_inline" && -z "$prompt_path_raw" ]]; then
      die "executions[$i] requires at least one of prompt or prompt_path" 2
    fi
    if [[ "$CLI" == "claude" && -z "$effort" ]]; then
      die "executions[$i] missing required field: effort for cli=claude" 2
    fi
    if [[ "$CLI" == "codex" && -n "$effort" && $codex_effort_warned -eq 0 ]]; then
      say_err 'warning: executions[].effort is ignored when cli=codex'
      codex_effort_warned=1
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
    EXEC_ID[$i]="$(unique_exec_id "$base_exec_id" "$parse_ts")"
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

  if git_worktree_list_has_path "$path"; then
    return 0
  fi

  mkdir -p "$GIT_DIR/.worktrees"

  if git_branch_exists "$branch"; then
    git -C "$GIT_DIR" worktree add "$path" "$branch" >/dev/null 2>&1 || return 1
  else
    git -C "$GIT_DIR" worktree add -b "$branch" "$path" >/dev/null 2>&1 || return 1
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
  output_dir="$OUTPUT_BASE/$exec_id"
  prompt_file="$LOG_DIR/$exec_id.prompt.md"
  log_file="$LOG_DIR/$exec_id.log"
  prompt_inline="${EXEC_PROMPT_INLINE[$idx]}"
  prompt_path="${EXEC_PROMPT_PATH[$idx]}"

  mkdir -p "$output_dir"

  {
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
  } > "$prompt_file"

  EXEC_OUTPUT_DIR[$idx]="$output_dir"
  EXEC_PROMPT_FILE[$idx]="$prompt_file"
  EXEC_LOG_PATH[$idx]="$log_file"
}

print_execution_plan() {
  local idx="$1"

  resolve_worktree_plan "$idx"

  printf '  - exec_id: %s\n' "${EXEC_ID[$idx]}"
  printf '    model: %s\n' "${EXEC_MODEL[$idx]}"
  if [[ "$CLI" == "claude" ]]; then
    printf '    effort: %s\n' "${EXEC_EFFORT[$idx]}"
  fi
  if [[ -n "${EXEC_PROMPT_INLINE[$idx]}" ]]; then
    printf '    prompt: inline\n'
  fi
  if [[ -n "${EXEC_PROMPT_PATH[$idx]}" ]]; then
    printf '    prompt_path: %s\n' "${EXEC_PROMPT_PATH[$idx]}"
  fi
  printf '    techspec: %s\n' "${EXEC_TECHSPEC_PATH[$idx]}"
  printf '    worktree: %s\n' "${EXEC_WORKTREE_PATH[$idx]}"
  printf '    output_dir: %s/%s/\n' "$OUTPUT_BASE" "${EXEC_ID[$idx]}"
}

run_cli() {
  local prompt_file="$1"
  local log_file="$2"
  local worktree_path="$3"
  local model="$4"
  local effort="$5"

  (
    cd "$worktree_path" || exit 1
    case "$CLI" in
      claude)
        claude -p \
          --model "$model" \
          --effort "$effort" \
          --permission-mode auto \
          < "$prompt_file" > "$log_file" 2>&1
        ;;
      codex)
        codex -q --full-auto -m "$model" \
          < "$prompt_file" > "$log_file" 2>&1
        ;;
      *)
        say_err "unknown cli: $CLI"
        exit 2
        ;;
    esac
  )
}

run_task_async() {
  local idx="$1"
  run_cli \
    "${EXEC_PROMPT_FILE[$idx]}" \
    "${EXEC_LOG_PATH[$idx]}" \
    "${EXEC_WORKTREE_PATH[$idx]}" \
    "${EXEC_MODEL[$idx]}" \
    "${EXEC_EFFORT[$idx]}"
}

mark_running() {
  local idx="$1"
  state_set_execution \
    "${EXEC_ID[$idx]}" \
    "${EXEC_WORKTREE_PATH[$idx]}" \
    "${EXEC_WORKTREE_BRANCH[$idx]}" \
    "$WAVE_TS" \
    'running'
}

mark_finished() {
  local idx="$1"
  local status="$2"
  state_set_execution \
    "${EXEC_ID[$idx]}" \
    "${EXEC_WORKTREE_PATH[$idx]}" \
    "${EXEC_WORKTREE_BRANCH[$idx]}" \
    "$WAVE_TS" \
    "$status"
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

  batch_indices=("$@")
  batch_pids=()
  launched_indices=()
  CHILDREN=()

  for idx in "${batch_indices[@]}"; do
    prepare_execution "$idx"
    ensure_worktree "$idx" || {
      EXEC_LOG_PATH[$idx]="$LOG_DIR/${EXEC_ID[$idx]}.log"
      printf '%s\n' "failed to create or reuse worktree: ${EXEC_WORKTREE_PATH[$idx]}" > "${EXEC_LOG_PATH[$idx]}"
      mark_finished "$idx" 'failed'
      printf '%s: FAILED | log=%s\n' "${EXEC_ID[$idx]}" "${EXEC_LOG_PATH[$idx]}"
      ANY_FAILED=1
      FAILED_COUNT=$((FAILED_COUNT + 1))
      continue
    }
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
      DONE_COUNT=$((DONE_COUNT + 1))
    else
      rc=$?
      status='failed'
      ANY_FAILED=1
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    mark_finished "$idx" "$status"
    if [[ $rc -eq 0 ]]; then
      printf '%s: DONE | log=%s\n' "${EXEC_ID[$idx]}" "${EXEC_LOG_PATH[$idx]}"
    else
      printf '%s: FAILED | log=%s\n' "${EXEC_ID[$idx]}" "${EXEC_LOG_PATH[$idx]}"
    fi
  done

  CHILDREN=()
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
        printf 'Batch %d\n' "$batch_num"
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
        printf 'Batch %d\n' "$batch_num"
        print_batch "${batch[@]}"
        batch_num=$((batch_num + 1))
        batch=()
      fi
      printf 'Batch %d\n' "$batch_num"
      print_batch "$i"
      batch_num=$((batch_num + 1))
    fi
  done

  if [[ ${#batch[@]} -gt 0 ]]; then
    printf 'Batch %d\n' "$batch_num"
    print_batch "${batch[@]}"
  fi
}

print_batch() {
  local idx
  for idx in "$@"; do
    print_execution_plan "$idx"
  done
}

run_execute() {
  local -a batch
  local i

  init_state
  mkdir -p "$LOG_DIR"
  batch=()

  for ((i=0; i<EXEC_COUNT; i++)); do
    if [[ "${EXEC_IS_BARRIER[$i]}" == "1" ]]; then
      if [[ ${#batch[@]} -gt 0 ]]; then
        run_batch "${batch[@]}"
        batch=()
      fi
      continue
    fi

    if [[ "${EXEC_PARALLEL[$i]}" == "yes" ]]; then
      batch+=("$i")
    else
      if [[ ${#batch[@]} -gt 0 ]]; then
        run_batch "${batch[@]}"
        batch=()
      fi
      run_batch "$i"
    fi
  done

  if [[ ${#batch[@]} -gt 0 ]]; then
    run_batch "${batch[@]}"
  fi

  printf 'Summary: done=%d failed=%d\n' "$DONE_COUNT" "$FAILED_COUNT"
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
    else
      usage
      exit 2
    fi
  fi

  check_prereqs
  load_config
  WAVE_TS=$(date +%Y%m%d_%H%M%S)
  LOG_DIR="$LOGS_BASE/$WAVE_TS"

  if [[ $DRY_RUN -eq 1 ]]; then
    run_dry_run
  else
    run_execute
  fi
}

main "$@"

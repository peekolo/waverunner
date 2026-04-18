# ai-wave-runner — Tech Spec

**Status:** ready for implementation
**Scope:** two bash scripts (`install.sh`, `run.sh`) + templates. Mac + Linux (incl. WSL/Ubuntu). Single-CLI per install (claude OR codex). No DAG, no tmux, no retries.

---

## 1. Prerequisites

Both `install.sh` and `run.sh` check at startup; if missing, print one-line install hint and exit 2.

| Tool  | Mac install            | Linux install         |
| ----- | ---------------------- | --------------------- |
| `jq`  | `brew install jq`      | `apt install jq`      |
| `git` | `brew install git`     | `apt install git`     |

Bash 3.2+ (Mac stock). Code MUST avoid: `declare -A`, `mapfile`/`readarray`, `${var^^}`/`${var,,}`, `&>` redirect, `local -n`. Indexed arrays, `[[ ]]`, `(( ))`, `trap`, `wait` are fine.

Shebang: `#!/usr/bin/env bash`.

---

## 2. Source Repo Layout

```
theexecutors/
├── install.sh
├── src/
│   └── run.sh                       # single self-contained script
└── templates/
    ├── config.json.tpl              # filled by installer
    ├── master_prompt.md.tpl         # empty section headers
    └── execution_example.json       # snippet user copies into config
```

No `adapters/` directory. CLI dispatch is a `case` block inside `run.sh`.

---

## 3. Installed Layout

```
<target>/
├── run.sh                           # copy of src/run.sh; chmod +x
├── config.json                      # MANDATORY — fill before running
├── master_prompt.md                 # MANDATORY — fill before running
├── specs/                           # user drops techspec MDs here
├── prompts/                         # user drops prompt MDs here
├── output/                          # auto-created on first run
│   └── <exec_id>/                   # per-execution deliverables
├── logs/                            # auto-created on first run
│   └── <wave_ts>/
│       ├── <exec_id>.prompt.md      # assembled prompt (audit)
│       └── <exec_id>.log            # CLI stdout+stderr
└── state.json                       # auto-created; tracks worktrees
```

`specs/` and `prompts/` are conventions only — paths in `config.json` may point anywhere.

---

## 4. Config Schema (`config.json`)

```json
{
  "cli": "claude",
  "project_root": "/var/www/yang_csb",
  "git_dir": "/var/www/yang_csb",
  "master_prompt_path": "./master_prompt.md",
  "output_base": "./output",
  "executions": [
    {
      "techspec_path": "./specs/SPEC-03.md",
      "prompt_path": "./prompts/SPEC-03.md",
      "prompt": "Focus on the autocorrelation regime first.",
      "parallel": "yes",
      "model": "claude-sonnet-4-6",
      "effort": "high"
    },
    {
      "techspec_path": "./specs/SPEC-04.md",
      "prompt_path": "./prompts/SPEC-04.md",
      "parallel": "yes",
      "model": "claude-sonnet-4-6",
      "effort": "high"
    },
    { "parallel": "no" },
    {
      "techspec_path": "./specs/SPEC-05.md",
      "prompt_path": "./prompts/SPEC-05.md",
      "parallel": "no",
      "model": "claude-opus-4-7",
      "effort": "high"
    }
  ]
}
```

### Top-level fields

| Field                | Required | Notes                                                   |
| -------------------- | -------- | ------------------------------------------------------- |
| `cli`                | yes      | `"claude"` or `"codex"`. Set by installer.              |
| `project_root`       | yes      | Used only as a sanity reference; agents `cd` to worktree, not here. |
| `git_dir`            | yes      | Repo root for `git worktree add`.                       |
| `master_prompt_path` | yes      | Relative to installed dir or absolute.                  |
| `output_base`        | yes      | Relative to installed dir or absolute. Per-exec subdirs created here. |

### Per-execution fields

| Field           | Required        | Notes                                                       |
| --------------- | --------------- | ----------------------------------------------------------- |
| `techspec_path` | yes (if non-empty entry) | Path to MD; **referenced**, not inlined.            |
| `prompt`        | one of these two required | Inline string, piped into prompt.                 |
| `prompt_path`   | one of these two required | Path to MD; contents piped into prompt.           |
| `parallel`      | yes             | `"yes"` or `"no"`. Drives batching (§6).                    |
| `model`         | yes (if non-empty entry) | Passed to CLI `-m`/`--model`.                      |
| `effort`        | yes for claude  | Ignored for codex (warn once at startup).                   |

### Empty entry

`{ "parallel": "no" }` (no other keys) is a **no-op barrier** — flushes the current parallel batch and runs nothing. Use it to separate two parallel batches.

---

## 5. Execution ID

Derived per execution at parse time:

```
exec_id = <NN>_<sanitized_basename_of_techspec_path_without_ext>
```

- `NN` = 1-indexed position in `executions[]`, zero-padded to 2 digits.
- Sanitization: replace any char not in `[A-Za-z0-9_-]` with `_`.
- Empty entries get no exec_id (they don't run).

Example: `executions[2].techspec_path = "./specs/SPEC-03_autocorr.md"` → `02_SPEC-03_autocorr`.

If two executions resolve to the same exec_id (duplicate techspec), append `_<YYYYMMDD_HHMMSS>` to the second.

---

## 6. Batching Rules

Linear scan over `executions[]`. State machine:

```
batch = []
for entry in executions:
  if entry.parallel == "yes":
    batch.append(entry)            # only if entry has techspec_path (non-empty)
  else:                            # "no" or empty
    if batch: run_batch(batch); wait_all; batch = []
    if entry has techspec_path: run_batch([entry]); wait
flush: if batch: run_batch(batch); wait_all
```

`run_batch` launches each task in background, collects PIDs, then `wait`s on all of them.

Stop-on-failure: if any task in a batch exits non-zero, **the wave continues** through remaining batches but exits non-zero at end. (Out of scope: aborting on first failure. Add later if needed.)

Worked example: `n, y, y, y, n, n, y` →
1. `n1` alone
2. batch `[y1, y2, y3]`
3. `n2` alone
4. `n3` alone
5. batch `[y4]`

---

## 7. Worktree Management

`run.sh` owns all worktree creation. CLI dispatch never touches `git worktree`.

For each execution:

1. Read `state.json` for an entry under this `exec_id`.
2. If entry exists AND `git -C <git_dir> worktree list` includes that path → **reuse**, `cd` into it.
3. Else → create:
   - Path: `<git_dir>/.worktrees/<exec_id>`
   - Branch: `<exec_id>` (created off current HEAD if it doesn't exist)
   - Command: `git -C <git_dir> worktree add -b <exec_id> <git_dir>/.worktrees/<exec_id>`
   - If branch already exists, omit `-b`: `git worktree add <path> <exec_id>`
   - If path already exists (from outside our state) → append `_<YYYYMMDD_HHMMSS>` to exec_id and retry.
4. Update `state.json` (single-writer; updates happen serially after `wait`, never from inside backgrounded tasks).

`.worktrees/` is the conventional location. User may add `.worktrees/` to repo `.gitignore`; spec doesn't manage this.

---

## 8. Prompt Composition

For each execution, `run.sh` writes `logs/<wave_ts>/<exec_id>.prompt.md`:

```
<contents of master_prompt_path>

---

<value of prompt field, if present>

<contents of prompt_path, if present>

---

## Techspec
Read your techspec at: <absolute path to techspec_path>

## Output directory
Write all deliverables to: <absolute path to output_base/<exec_id>/>
```

- If only `prompt` is set, the `prompt_path` block is omitted (and vice versa). At least one MUST be present.
- `output_base/<exec_id>/` is `mkdir -p`'d before launching.
- Path resolution: relative paths in `config.json` are resolved from the installed dir.

The prompt file is then piped into the CLI via stdin.

---

## 9. CLI Dispatch

Inside `run.sh`:

```bash
run_cli() {
  local PROMPT_FILE="$1" LOG="$2" WT="$3" MODEL="$4" EFFORT="$5"
  cd "$WT" || return 1
  case "$CLI" in
    claude)
      cat "$PROMPT_FILE" | claude -p \
        --model "$MODEL" \
        --effort "$EFFORT" \
        --permission-mode auto \
        > "$LOG" 2>&1
      ;;
    codex)
      cat "$PROMPT_FILE" | codex -q --full-auto -m "$MODEL" \
        > "$LOG" 2>&1
      ;;
    *)
      echo "unknown cli: $CLI" >&2; return 2 ;;
  esac
}
```

Notes:
- Output goes to `$LOG` only (no `tee`); user tails the log file for live view. Keeps parallel output from interleaving on stdout.
- Exit code of `run_cli` = exit code of the CLI.
- `--permission-mode auto` and `--full-auto` are non-interactive switches. Confirm flag names against installed CLI versions before shipping.

---

## 10. State File (`state.json`)

```json
{
  "executions": {
    "01_SPEC-03": {
      "worktree_path": "/var/www/yang_csb/.worktrees/01_SPEC-03",
      "branch": "01_SPEC-03",
      "last_run_ts": "20260418_143022",
      "last_status": "done"
    }
  }
}
```

- Created empty (`{"executions":{}}`) on first run if missing.
- `last_status`: `"done"` | `"failed"` | `"running"`.
- Only `run.sh` writes. Updates happen between batches (not from backgrounded children) — no locking needed.
- Reads use `jq -r '.executions["<id>"].worktree_path // empty'`.

---

## 11. `install.sh` Behavior

Interactive prompts:

```
[1/4] Project root path?
      > /var/www/yang_csb
[2/4] Install wave runner at?
      > /var/www/yang_csb/ai-waves
[3/4] Which CLI? (1) claude  (2) codex
      > 1
[4/4] Git dir? (blank = same as project root)
      >
```

Steps:

1. Check prereqs (`jq`, `git`). Missing → print install hint, exit 2.
2. `mkdir -p <target>/{specs,prompts}` (output/, logs/ created on first run).
3. Copy `src/run.sh` → `<target>/run.sh`; `chmod +x`.
4. Render `templates/config.json.tpl` substituting answers → `<target>/config.json`.
5. Copy `templates/master_prompt.md.tpl` → `<target>/master_prompt.md`.
6. Copy `templates/execution_example.json` → `<target>/execution_example.json` (reference for users).
7. Print completion message:

```
Done. Wave runner installed at: <target>

Next steps:
  1. Edit config.json         — verify paths, fill executions[]
  2. Fill in master_prompt.md — project-wide context for every executor
  3. Drop techspec MDs in specs/  and prompt MDs in prompts/
  4. Run:
       <target>/run.sh --dry-run
       <target>/run.sh
```

### `--upgrade` flag

```
./install.sh --upgrade <target>
```

Overwrites only: `run.sh`. Does NOT touch: `config.json`, `master_prompt.md`, `specs/`, `prompts/`, `output/`, `logs/`, `state.json`.

Re-runs prereq check.

---

## 12. `run.sh` Behavior

Usage:

```
./run.sh                # run the wave defined in ./config.json
./run.sh --dry-run      # parse, plan, print batches; no execution, no worktrees
```

No other flags. `run.sh` always reads `config.json` and `master_prompt.md` from its own directory (resolved via `dirname "$0"`).

Lifecycle:

1. Prereq check (jq, git). Fail → exit 2.
2. Validate `config.json`: required top-level fields present, `cli` is one of `claude`/`codex`, every non-empty execution has `techspec_path`, `model`, and at least one of `prompt`/`prompt_path`.
3. Resolve `WAVE_TS = $(date +%Y%m%d_%H%M%S)`.
4. Create `logs/<WAVE_TS>/`.
5. For each execution: derive `exec_id`, classify `parallel`, build batches per §6.
6. **Dry-run path:** print resolved batch list — for each entry, print `exec_id`, model, effort, prompt sources, techspec abs path, intended worktree path (existing or new), output dir. Exit 0.
7. **Execute path:** for each batch:
   - For each task in batch: assemble prompt file (§8), resolve worktree (§7), `mkdir -p` output dir, mark state `running`, launch `run_cli ... &`, record PID.
   - `wait` on all PIDs in batch; capture per-PID exit codes.
   - Update `state.json` for each task with `done`/`failed` + timestamp.
   - Print `exec_id: DONE | FAILED | log=<path>` per task.
8. Final summary: counts of done/failed; exit 0 if all done, 1 if any failed.

Signal handling:

```bash
CHILDREN=()
cleanup() {
  echo "interrupted; killing children..." >&2
  for pid in "${CHILDREN[@]}"; do kill "$pid" 2>/dev/null; done
  wait
  exit 130
}
trap cleanup INT TERM
```

`CHILDREN` is reset between batches. After each launch: `CHILDREN+=("$!")`.

Exit codes:

| Code | Meaning                                  |
| ---- | ---------------------------------------- |
| 0    | All executions succeeded                 |
| 1    | One or more executions failed            |
| 2    | Prereq missing or config invalid         |
| 130  | Interrupted (SIGINT/SIGTERM)             |

---

## 13. Templates

### `templates/config.json.tpl`

```json
{
  "cli": "{{CLI}}",
  "project_root": "{{PROJECT_ROOT}}",
  "git_dir": "{{GIT_DIR}}",
  "master_prompt_path": "./master_prompt.md",
  "output_base": "./output",
  "executions": []
}
```

### `templates/master_prompt.md.tpl`

```markdown
# Project context

## What this project is
<one paragraph>

## Directory layout
<key paths the agent should know>

## Environment
<how to run tests, venv path, docker commands, etc.>

## Hard constraints
<what the agent must never do>

## Shared constants / pinned choices
<values all executions reference>
```

### `templates/execution_example.json`

```json
{
  "techspec_path": "./specs/SPEC-XX.md",
  "prompt_path": "./prompts/SPEC-XX.md",
  "prompt": "optional inline note",
  "parallel": "yes",
  "model": "claude-sonnet-4-6",
  "effort": "high"
}
```

---

## 14. Out of Scope

- Retries (failed tasks re-run manually by re-invoking `run.sh` after editing config or fixing the issue)
- Result parsing or verdict aggregation
- DAG dependencies
- tmux / live multi-pane viewing (tail individual `logs/<wave_ts>/<exec_id>.log` instead)
- Authentication management (CLI tools must already be authenticated)
- Log rotation / pruning
- Per-task secrets / env vars
- Worktree cleanup (`git worktree remove`) — left to user
- Aborting wave on first failure (continue-through is the only mode)

---

## 15. Open Items to Verify Before Implementation

1. `claude -p --permission-mode auto --effort <x>` — confirm exact flag names on the target claude version (older versions used different flags).
2. `codex -q --full-auto -m <model>` — confirm this is the correct non-interactive invocation on the target codex version.
3. `git worktree add` behavior when branch exists vs. doesn't — confirmed cross-version (git ≥ 2.5).

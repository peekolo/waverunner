# ai-wave-runner — Design Document

**Purpose:** Project-agnostic, command-agnostic orchestrator for launching parallel (or
sequential) AI CLI agents across research waves. Supports `claude`, `codex`, and any
future CLI via an adapter pattern. Agents run in isolated git worktrees.

---

## Core Design Principles

- **Source repo lives at `/var/www/theexecutors`** (or wherever checked out) — users
  never run waves from here
- **`install.sh` copies a minimal self-contained bundle** into a user-chosen target path
  — after install, the target has no dependency on the source repo
- **Two scripts**: `install.sh` (one-time setup, run from source repo) + `run.sh`
  (daily driver, run from installed path)
- **Command-agnostic via adapters** — adding a new AI CLI = adding one adapter file;
  `run.sh` never changes
- **Two-layer prompt composition**: `context.md` (project-wide, written once) +
  `briefs/TASK.md` (task-specific) — briefs stay lean
- **`--upgrade` flag** on `install.sh` to refresh `run.sh` and adapters without
  touching user files

---

## Source Repo Layout (`/var/www/theexecutors/`)

```
theexecutors/
├── install.sh                    # interactive installer — only file users run from here
├── src/
│   ├── run.sh                    # copied verbatim to target; uses $(dirname $0) for
│   │                             # relative paths — fully self-contained after copy
│   └── adapters/
│       ├── claude.sh
│       └── codex.sh
└── templates/
    ├── config.json.tpl           # placeholders; installer substitutes user answers
    ├── context.md.tpl            # section headers for user to fill in
    ├── wave_example.json         # annotated starter wave config
    └── brief_example.md          # annotated starter brief
```

---

## Installed Copy Layout (target path, created by `install.sh`)

```
<target>/                         # e.g., /var/www/yang_csb/ai-waves/
│
├── run.sh                        # ready to use; self-contained
│
├── config.json                   # MANDATORY — fill in after install
├── context.md                    # MANDATORY — fill in after install
│
├── adapters/
│   └── claude.sh                 # only adapters selected during install
│
├── waves/
│   └── wave_example.json         # annotated starter; replace with real wave configs
│
├── briefs/
│   └── brief_example.md          # annotated starter; replace with real briefs
│
└── logs/                         # auto-created on first run; add to .gitignore
    └── wave1_20260418_143022/
        ├── TASK-A.log
        └── TASK-B.log
```

---

## Mandatory User Files

These two files must be filled in before running any wave. `install.sh` creates them
from templates and prints explicit instructions.

### `config.json`

```json
{
  "project_name": "yang_csb",
  "project_root": "/var/www/yang_csb",
  "git_dir": "/var/www/yang_csb",
  "log_dir": "./logs",
  "default_output_base": "dev/data/spec_runs"
}
```

| Field | Purpose |
|---|---|
| `project_root` | Working directory for all agents; where `run.sh` `cd`s before launching |
| `git_dir` | Root of the git repo for worktree creation (usually same as project_root) |
| `log_dir` | Where per-run log directories are created (relative to installed path) |
| `default_output_base` | Substituted for `{default_output_base}` in wave configs |

### `context.md`

Injected at the top of every agent's prompt — the project-wide system prompt layer.
Keeps individual briefs lean; no need to repeat project context per brief.

Suggested sections:
```markdown
# Project Context

## What this project is
<one paragraph — what the codebase does>

## Directory layout
<key paths the agent needs to know>

## Environment
<how to run tests, venv path, docker commands, etc.>

## Hard constraints
<what the agent must never do — e.g., do not modify strategy source, do not re-decide pinned constants>

## Shared constants / pinned choices
<values all specs reference — fee model, partition boundaries, MC params, etc.>
```

---

## Wave Config Schema (`waves/wave1.json`)

```json
{
  "wave_id": "wave1",
  "description": "Step 3 — Wave 1 falsification studies",
  "execution_mode": "parallel",
  "tasks": [
    {
      "id": "SPEC-03",
      "title": "Autocorrelation regime study",
      "command": "claude",
      "model": "claude-sonnet-4-6",
      "effort": "high",
      "brief": "briefs/SPEC-03.md",
      "worktree_name": "spec-03-autocorrelation",
      "output_dir": "{default_output_base}/SPEC-03_autocorrelation_{DATE}",
      "max_budget_usd": 8.0,
      "depends_on": [],
      "priority": 1
    }
  ]
}
```

**Field reference:**

| Field | Type | Notes |
|---|---|---|
| `command` | string | Adapter name: `"claude"`, `"codex"`, etc. |
| `execution_mode` | enum | `"parallel"` \| `"sequential"` \| `"dag"` |
| `depends_on` | string[] | Task IDs within this wave that must complete first |
| `worktree_name` | string | Becomes the git branch + worktree dir (adapter-specific use) |
| `effort` | string | Passed to adapters that support it (`claude`: `low/medium/high/xhigh/max`) |
| `max_budget_usd` | number | Per-task cost cap (adapter-specific) |
| `output_dir` | string | `{DATE}` and `{default_output_base}` substituted at runtime |
| `priority` | integer | Launch order for sequential mode; display order for parallel |

**Execution modes:**
- `parallel` — all tasks launched simultaneously; script waits for all PIDs
- `sequential` — one at a time in `priority` order; stops on first failure
- `dag` — topological sort by `depends_on`; tasks launch as soon as all dependencies exit

---

## Prompt Composition

`run.sh` builds each agent's final prompt as:

```
[content of context.md]
---
[content of briefs/TASK.md]

## Output directory
[resolved output_dir with {DATE} and {default_output_base} substituted]
```

Briefs contain only task-specific method, acceptance criteria, and do-not list.
All project-wide rules, paths, and constants live in `context.md` — written once.

---

## Adapter Pattern

Each adapter is a shell file sourced by `run.sh`. Must define one function:

```bash
adapter_run_task TASK_JSON PROMPT LOG_FILE PROJECT_ROOT
```

### `adapters/claude.sh`

```bash
adapter_run_task() {
  local TASK="$1" PROMPT="$2" LOG="$3" PROJECT_ROOT="$4"
  local MODEL EFFORT WORKTREE BUDGET NAME
  MODEL=$(echo "$TASK"    | jq -r '.model    // "claude-sonnet-4-6"')
  EFFORT=$(echo "$TASK"   | jq -r '.effort   // "high"')
  WORKTREE=$(echo "$TASK" | jq -r '.worktree_name')
  BUDGET=$(echo "$TASK"   | jq -r '.max_budget_usd // "10"')
  NAME=$(echo "$TASK"     | jq -r '.id')

  cd "$PROJECT_ROOT" || exit 1
  claude -p "$PROMPT" \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --worktree "$WORKTREE" \
    --permission-mode auto \
    --max-budget-usd "$BUDGET" \
    --name "$NAME" \
    2>&1 | tee "$LOG"
}
```

Key claude flags:
- `-p` — non-interactive / fire-and-forget
- `--worktree` — native git worktree isolation (creates branch + worktree automatically)
- `--permission-mode auto` — unattended; no prompts
- `--max-budget-usd` — per-task cost cap
- `--effort` — controls extended thinking level

### `adapters/codex.sh`

```bash
adapter_run_task() {
  local TASK="$1" PROMPT="$2" LOG="$3" PROJECT_ROOT="$4"
  local MODEL
  MODEL=$(echo "$TASK" | jq -r '.model // "codex-mini-latest"')

  cd "$PROJECT_ROOT" || exit 1
  codex -q --full-auto -m "$MODEL" "$PROMPT" 2>&1 | tee "$LOG"
}
```

> **Note:** confirm `codex -q --full-auto` is the correct non-interactive invocation
> for your codex version before using this adapter.

Adding a new AI CLI = one new adapter file. No changes to `run.sh`.

---

## `install.sh` — Interactive Installer

Run once from the source repo. Asks the user a small set of questions, copies the
minimal bundle to the target path, and prints next-step instructions.

### Interactive questions

```
[1/4] Project root path? (where your codebase lives)
      > /var/www/yang_csb

[2/4] Install wave runner at?
      > /var/www/yang_csb/ai-waves

[3/4] Which AI adapters do you need?
      1) claude only
      2) codex only
      3) both
      > 1

[4/4] Git dir? (leave blank if same as project root)
      >
```

### What install does

1. Creates target path + `adapters/`, `waves/`, `briefs/`, `logs/`
2. Copies `src/run.sh` → `target/run.sh`
3. Copies selected `src/adapters/*.sh` → `target/adapters/`
4. Renders `templates/config.json.tpl` with user answers → `target/config.json`
5. Copies `templates/context.md.tpl` → `target/context.md`
6. Copies `templates/wave_example.json` + `brief_example.md` → `target/waves/` + `target/briefs/`
7. Appends `logs/` to `target/.gitignore` (creates if absent)
8. Prints completion message (see below)

### Completion message

```
Done. Wave runner installed at: /var/www/yang_csb/ai-waves/

Next steps:
  1. Edit config.json         — verify project_root, git_dir, output paths
  2. Fill in context.md       — project context injected into every agent prompt
  3. Create waves/wave1.json  — define your first wave (see wave_example.json)
  4. Create briefs/TASK.md    — one brief per task (see brief_example.md)

Then run:
  /var/www/yang_csb/ai-waves/run.sh waves/wave1.json --dry-run
  /var/www/yang_csb/ai-waves/run.sh waves/wave1.json
```

### `--upgrade` flag

```bash
./install.sh --upgrade /var/www/yang_csb/ai-waves
```

Overwrites only: `run.sh` and `adapters/`.
Does NOT touch: `config.json`, `context.md`, `waves/`, `briefs/`, `logs/`.

Prints a diff summary of what changed in `run.sh` since the previous version (via
`diff` between old and new).

---

## `run.sh` — Daily Driver

### Usage

```bash
# From the installed path:
./run.sh waves/wave1.json              # launch wave
./run.sh waves/wave1.json --dry-run    # print what would run, no execution
./run.sh waves/wave1.json --watch      # launch with tmux panes (claude adapter only)
```

### Behavior

1. Load `config.json` from same directory as `run.sh`
2. Load `context.md` from same directory
3. Parse wave config: wave_id, execution_mode, tasks[]
4. Create `LOG_DIR = <log_dir>/<wave_id>_<timestamp>/`
5. For each task (order per execution_mode):
   - Substitute `{DATE}` and `{default_output_base}` in `output_dir`
   - Build prompt: `context.md` + `---` + `briefs/<brief>` + output dir footer
   - Source adapter: `source adapters/<command>.sh`
   - **parallel**: `adapter_run_task ... &`, collect PID
   - **sequential**: `adapter_run_task ...`, stop on failure
   - **dag**: topological sort; launch task when all `depends_on` PIDs have exited
6. `wait` all PIDs; print `TASK-ID: DONE | FAILED` + log path per task
7. `--dry-run`: print resolved config for each task (command, model, worktree, budget,
   brief path, output_dir) — no execution
8. `--watch`: pass `--tmux` through to claude adapter for live pane monitoring

---

## Brief File Design

Each brief contains only task-specific content. Project context comes from `context.md`.

```markdown
# TASK-ID: Title

## Mission
<what question you answer and why — one paragraph>

## Method
<numbered steps: exactly what to run, what to measure, what thresholds apply>

## Acceptance criteria
- <binary check 1>
- <binary check 2>

## Deliverables
Write all output to the directory specified at the end of this prompt:
- results.json  — raw numbers / data
- report.md     — must contain `VERDICT: <value>` on its own line

## Do NOT
- <task-specific scope guardrails>
- Exit without writing results.json and report.md
```

---

## Intentionally Out of Scope

- No retry logic — failed tasks re-run manually
- No result parsing or verdict aggregation — human review step handles this
- No inter-wave dependency tracking — human gates in the runbook are the mechanism
- No web UI, database, or durable state beyond log files
- No authentication management — assumes CLI tools are already authenticated

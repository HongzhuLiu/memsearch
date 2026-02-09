# memsearch — Claude Code Plugin

**Automatic persistent memory for Claude Code.** No commands to learn, no manual saving — just install the plugin and Claude remembers what you worked on across sessions.

```bash
claude --plugin-dir /path/to/memsearch/plugin
```

## How It Works

The plugin hooks into 4 Claude Code lifecycle events. A singleton `memsearch watch` process handles all indexing; hooks only read or write markdown files.

```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                    memsearch plugin lifecycle                           │
  └─────────────────────────────────────────────────────────────────────────┘

  SESSION START
  ─────────────
  ┌──────────────┐     ┌─────────────────┐     ┌──────────────────────────┐
  │ SessionStart │────▶│ Start singleton │────▶│ Inject recent memories   │
  │   hook       │     │ memsearch watch │     │ into context             │
  └──────────────┘     │ (PID file lock) │     │ { "additionalContext" }  │
                       └─────────────────┘     └──────────────────────────┘
                              │
                              ▼
                       ┌─────────────────┐
                       │ watch monitors  │ (background, 1500ms debounce)
                       │ .memsearch/     │
                       │   memory/*.md   │──── auto-index on any change
                       └─────────────────┘

  EVERY USER PROMPT
  ─────────────────
  ┌──────────────────┐     ┌─────────────────┐     ┌────────────────────┐
  │ UserPromptSubmit │────▶│ memsearch search │────▶│ Inject top-3       │
  │   hook           │     │ "$user_prompt"   │     │ relevant memories  │
  └──────────────────┘     │ --top-k 3        │     └────────────────────┘
                           └─────────────────┘
                           (skip if < 10 chars)

  WHEN CLAUDE FINISHES RESPONDING
  ────────────────────────────────
  ┌──────────┐     ┌──────────────────────┐     ┌──────────────────────┐
  │  Stop    │────▶│ Agent subagent runs  │────▶│ Write AI summary to  │
  │ (agent   │     │ parse-transcript.sh  │     │ .memsearch/memory/   │
  │  hook)   │     │ (truncate + format)  │     │ YYYY-MM-DD.md        │
  └──────────┘     └──────────────────────┘     └──────────────────────┘
                                                  │
                                                  └──▶ watch detects change
                                                       → auto-indexes

  SESSION END
  ───────────
  ┌──────────────┐
  │ SessionEnd   │──── stop watch process (cleanup)
  └──────────────┘
```

### Hook Summary

| Hook | Type | Timeout | What it does |
|------|------|---------|-------------|
| **SessionStart** | command | 10s | Start `memsearch watch` singleton + inject recent memories |
| **UserPromptSubmit** | command | 15s | Semantic search on user prompt → inject relevant memories |
| **Stop** | agent | 60s | Parse transcript → AI summary → write to daily `.md` log |
| **SessionEnd** | command | 10s | Stop the `memsearch watch` process |

### Design: watch as single source of indexing

The key architectural decision: **indexing is managed in exactly one place** — the `memsearch watch` background process started at SessionStart.

Previous designs had `memsearch index` scattered across PostToolUse, PreCompact, SessionEnd, and Stop hooks. This was redundant and could cause race conditions. Now:

- **Hooks only write `.md` files** — they never call `memsearch index`
- **Watch detects changes and indexes** — with 1500ms debounce, dedup built in
- **Singleton via PID file** — `.memsearch/.watch.pid` ensures one watcher per project, even across multiple concurrent Claude sessions

### Why Stop uses an agent hook

The **Stop** hook is the only one that uses an agent hook (subagent with AI capabilities). All other hooks are simple command (bash) hooks. Here's why:

- **UserPromptSubmit** only needs `memsearch search` — no AI reasoning
- **SessionStart / SessionEnd** only need to start/stop watch + read files — no AI reasoning
- **Stop** needs AI to read a conversation transcript and generate a meaningful summary — a bash script can't do that

The agent hook subagent calls `parse-transcript.sh` to get pre-processed text, then writes a summary. Zero extra LLM API calls — it uses Claude's built-in subagent capability.

### Long session protection

Transcript parsing is handled by `parse-transcript.sh` — a deterministic bash script, not AI prompt instructions. The subagent calls it and receives clean, bounded output.

The script applies these rules:

- Each user/assistant message exceeding **500 chars** → truncated to **last 500 chars** (tail is more informative — final decisions, conclusions, results)
- Tool calls → **tool name + one-line input summary** (skip full input/output)
- Tool results → **one-line truncated preview**
- `file-history-snapshot` entries → **skipped entirely**
- Transcript exceeding **200 lines** → only the **last 200 lines** are processed

Limits are configurable via environment variables: `MEMSEARCH_MAX_LINES` (default 200), `MEMSEARCH_MAX_CHARS` (default 500).

## Memory Storage

All memories live in **`.memsearch/memory/`** inside your project directory:

```
your-project/
└── .memsearch/
    ├── .watch.pid        ← singleton watcher PID
    └── memory/
        ├── 2026-02-07.md
        ├── 2026-02-08.md
        └── 2026-02-09.md    ← today's session summaries
```

Each file contains session summaries in plain markdown:

```markdown
## Session 14:30
- Implemented caching system with Redis L1 and in-process LRU L2
- Fixed N+1 query issue in order-service using selectinload
- Decided to use Prometheus counters for cache hit/miss metrics

## Session 17:45
- Debugged React hydration mismatch — Date.now() during SSR
- Added comprehensive test suite for the caching middleware
```

**Markdown is the source of truth.** The Milvus vector index is a derived cache that can be rebuilt at any time with `memsearch index .memsearch/memory/`.

## memsearch plugin vs claude-mem

| | memsearch plugin | claude-mem |
|---|---|---|
| **Prompt-level recall** | Semantic search on **every prompt** | Only at SessionStart |
| **Session summary** | **Agent hook subagent** — zero extra API calls, no background service | Separate Worker service (port 37777) + Anthropic Agent SDK API calls |
| **Index maintenance** | **`memsearch watch` singleton** — one process, auto-debounced | Manual index calls scattered across hooks |
| **Storage format** | **Transparent `.md` files** — human-readable, git-friendly | Opaque SQLite + Chroma binary |
| **Architecture** | 4 hooks + 1 watch process, ~300 lines total | Node.js/Bun Worker service + Express server + React UI |
| **Runtime dependency** | Python (`memsearch` CLI) | Node.js + Bun runtime |
| **Vector backend** | **Milvus** (Lite → Server → Zilliz Cloud) | Chroma (local only) |
| **Background processes** | **1 watch** (lightweight file watcher) | Worker service (Express + Agent SDK) |
| **Temp files** | **None** — reads transcript via `$ARGUMENTS` | `session.log` intermediate state |
| **Data portability** | Copy `.memsearch/memory/*.md` — that's it | Export from SQLite + Chroma |
| **Cost** | **Zero** extra LLM calls (agent hook is free) | Claude API calls for observation compression |

### Key design differences

**memsearch** takes a **minimalist, Unix-philosophy approach**: a singleton file watcher handles indexing, hooks are small stateless scripts that read or write markdown. The only "smart" part is the Stop agent hook, which leverages Claude's built-in subagent to generate session summaries at zero cost.

**claude-mem** takes a **full-stack approach**: a Worker service compresses every tool observation into structured data via Claude API calls, stores them in SQLite + Chroma with FTS5 full-text indexes, and provides a React web UI for browsing memories. More powerful for heavy use, but significantly more complex.

## Plugin Files

```
plugin/
├── plugin.json               # Plugin manifest
└── hooks/
    ├── hooks.json             # Hook definitions (4 hooks)
    ├── common.sh              # Shared setup: env, memsearch detection, watch management
    ├── session-start.sh       # Start watch singleton + inject recent memories
    ├── user-prompt-submit.sh  # Semantic search on prompt → inject relevant memories
    ├── parse-transcript.sh    # Deterministic JSONL→text parser with truncation
    └── session-end.sh         # Stop watch process
```

## Prerequisites

- **memsearch** CLI in PATH — install via:
  ```bash
  pip install memsearch
  # or
  uv tool install memsearch
  ```
- **jq** — for JSON parsing in hook scripts (pre-installed on most systems)
- A configured memsearch backend (`.memsearch.toml` or `~/.memsearch/config.toml`)

## Quick Start

```bash
# 1. Install memsearch
pip install memsearch

# 2. Initialize config (if first time)
memsearch config init

# 3. Launch Claude with the plugin
claude --plugin-dir /path/to/memsearch/plugin

# 4. Have a conversation, then exit. Check your memories:
cat .memsearch/memory/$(date +%Y-%m-%d).md

# 5. Start a new session — Claude remembers!
claude --plugin-dir /path/to/memsearch/plugin
```

## Troubleshooting

**Memories not being injected?**
- Check that `.memsearch/memory/` exists and has `.md` files
- Verify `memsearch search "test query"` works from the command line
- Ensure `jq` is installed: `jq --version`

**Watch not running?**
- Check: `cat .memsearch/.watch.pid && ps -p $(cat .memsearch/.watch.pid)`
- Start manually: `memsearch watch .memsearch/memory/`

**Stop hook not writing summaries?**
- The agent hook subagent needs Read/Write/Bash tool access
- If it doesn't work, session summaries won't be auto-generated, but search still functions

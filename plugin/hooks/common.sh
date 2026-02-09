#!/usr/bin/env bash
# Shared setup for memsearch command hooks.
# Sourced by all hook scripts — not executed directly.

set -euo pipefail

# Read stdin JSON into $INPUT
INPUT="$(cat)"

# Memory directory and memsearch state directory are project-scoped
MEMSEARCH_DIR="${CLAUDE_PROJECT_DIR:-.}/.memsearch"
MEMORY_DIR="$MEMSEARCH_DIR/memory"

# Find memsearch binary: prefer PATH, fallback to uv run
MEMSEARCH_CMD=""
if command -v memsearch &>/dev/null; then
  MEMSEARCH_CMD="memsearch"
elif command -v uv &>/dev/null; then
  MEMSEARCH_CMD="uv run memsearch"
fi

# Helper: ensure memory directory exists
ensure_memory_dir() {
  mkdir -p "$MEMORY_DIR"
}

# Helper: run memsearch with arguments, silently fail if not available
run_memsearch() {
  if [ -n "$MEMSEARCH_CMD" ]; then
    $MEMSEARCH_CMD "$@" 2>/dev/null || true
  fi
}

# --- Watch singleton management ---

WATCH_PIDFILE="$MEMSEARCH_DIR/.watch.pid"

# Check if a memsearch watch process is already running for this directory
is_watch_running() {
  if [ -f "$WATCH_PIDFILE" ]; then
    local pid
    pid=$(cat "$WATCH_PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    # Stale PID file, clean up
    rm -f "$WATCH_PIDFILE"
  fi
  return 1
}

# Start memsearch watch as a singleton background process
start_watch() {
  if [ -z "$MEMSEARCH_CMD" ]; then
    return 0
  fi
  ensure_memory_dir
  if is_watch_running; then
    return 0
  fi
  nohup $MEMSEARCH_CMD watch "$MEMORY_DIR" &>/dev/null &
  echo $! > "$WATCH_PIDFILE"
}

# Stop the watch process if running
stop_watch() {
  if [ -f "$WATCH_PIDFILE" ]; then
    local pid
    pid=$(cat "$WATCH_PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$WATCH_PIDFILE"
  fi
}

#!/usr/bin/env bash
# SessionStart hook: start watch singleton + inject recent memory context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Start memsearch watch as a singleton background process.
# This is the ONLY place indexing is managed — all other hooks just write .md files.
start_watch

# If memory dir doesn't exist or has no .md files, nothing to inject
if [ ! -d "$MEMORY_DIR" ] || ! ls "$MEMORY_DIR"/*.md &>/dev/null; then
  echo '{}'
  exit 0
fi

context=""

# Find the 2 most recent daily log files (sorted by filename descending)
recent_files=$(ls -1 "$MEMORY_DIR"/*.md 2>/dev/null | sort -r | head -2)

if [ -n "$recent_files" ]; then
  context="# Recent Memory\n\n"
  for f in $recent_files; do
    basename_f=$(basename "$f")
    # Read last ~30 lines from each file
    content=$(tail -30 "$f" 2>/dev/null || true)
    if [ -n "$content" ]; then
      context+="## $basename_f\n$content\n\n"
    fi
  done
fi

# If memsearch is available, also do a semantic search for recent context
if [ -n "$MEMSEARCH_CMD" ]; then
  search_results=$($MEMSEARCH_CMD search "recent session summary" --top-k 3 --json-output 2>/dev/null || true)
  if [ -n "$search_results" ] && [ "$search_results" != "[]" ] && [ "$search_results" != "null" ]; then
    formatted=$(echo "$search_results" | jq -r '
      .[]? |
      "- [\(.source // "unknown"):\(.heading // "")]  \(.content // "" | .[0:200])"
    ' 2>/dev/null || true)
    if [ -n "$formatted" ]; then
      context+="\n## Semantic Search: Recent Sessions\n$formatted\n"
    fi
  fi
fi

if [ -n "$context" ]; then
  json_context=$(printf '%s' "$context" | jq -Rs .)
  echo "{\"additionalContext\": $json_context}"
else
  echo '{}'
fi

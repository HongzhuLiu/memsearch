#!/usr/bin/env bash
# Stop hook: parse transcript, summarize with claude -p, and save to memory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Prevent infinite loop: if this Stop was triggered by a previous Stop hook, bail out
STOP_HOOK_ACTIVE=$(_json_val "$INPUT" "stop_hook_active" "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  echo '{}'
  exit 0
fi

# Skip summarization when the required API key is missing — embedding/search
# would fail, and the session likely only contains the "key not set" warning.
_required_env_var() {
  case "$1" in
    openai) echo "OPENAI_API_KEY" ;;
    google) echo "GOOGLE_API_KEY" ;;
    voyage) echo "VOYAGE_API_KEY" ;;
    *) echo "" ;;  # ollama, local — no API key needed
  esac
}
_PROVIDER=$($MEMSEARCH_CMD config get embedding.provider 2>/dev/null || echo "openai")
_REQ_KEY=$(_required_env_var "$_PROVIDER")
if [ -n "$_REQ_KEY" ] && [ -z "${!_REQ_KEY:-}" ]; then
  echo '{}'
  exit 0
fi

# Extract transcript path from hook input
TRANSCRIPT_PATH=$(_json_val "$INPUT" "transcript_path" "")

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo '{}'
  exit 0
fi

# Check if transcript is empty (< 3 lines = no real content)
LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
if [ "$LINE_COUNT" -lt 3 ]; then
  echo '{}'
  exit 0
fi

ensure_memory_dir

# Parse transcript — extract the last turn only (one user question + all responses)
PARSED=$("$SCRIPT_DIR/parse-transcript.sh" "$TRANSCRIPT_PATH" 2>/dev/null || true)

if [ -z "$PARSED" ] || [ "$PARSED" = "(empty transcript)" ] || [ "$PARSED" = "(no user message found)" ] || [ "$PARSED" = "(empty turn)" ]; then
  echo '{}'
  exit 0
fi

# Determine today's date and current time
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M)
MEMORY_FILE="$MEMORY_DIR/$TODAY.md"

# Extract session ID and last user turn UUID for progressive disclosure anchors
SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
LAST_USER_TURN_UUID=$(python3 -c "
import json, sys
uuid = ''
with open(sys.argv[1]) as f:
    for line in f:
        try:
            obj = json.loads(line)
            if obj.get('type') == 'user' and isinstance(obj.get('message', {}).get('content'), str):
                uuid = obj.get('uuid', '')
        except: pass
print(uuid)
" "$TRANSCRIPT_PATH" 2>/dev/null || true)

# Use claude -p to summarize the last turn into structured bullet points.
# --model haiku: cheap and fast model for summarization
# --no-session-persistence: don't save this throwaway session to disk
# --no-chrome: skip browser integration
# --system-prompt: separate role instructions from data (transcript via stdin)
#
# MEMSEARCH_RAW_TRANSCRIPT=1: 保留原始对话内容，不生成摘要
# MEMSEARCH_RAW_TRANSCRIPT=both: 同时保留原始内容和摘要

RAW_MODE="${MEMSEARCH_RAW_TRANSCRIPT:-}"

SUMMARY=""
if [ "$RAW_MODE" = "1" ] || [ "$RAW_MODE" = "true" ]; then
  # 模式1: 只保留原始对话内容
  SUMMARY="$PARSED"
elif [ "$RAW_MODE" = "both" ]; then
  # 模式2: 同时保留原始内容和摘要
  if command -v claude &>/dev/null; then
    AI_SUMMARY=$(printf '%s' "$PARSED" | MEMSEARCH_NO_WATCH=1 CLAUDECODE= claude -p \
      --model haiku \
      --no-session-persistence \
      --no-chrome \
      --system-prompt "用一句话记录这轮对话，格式：'关键词：做了什么'。

示例：
- '摘要优化：将prompt从详细条目改为单行总结'
- '文件搜索：找到stop.sh并读取内容'
- '用户偏好：确认用户喜欢喝茶'

规则：
- 只输出一行，以'-'开头
- 省略所有细节，只保留核心动作
- 用用户使用的语言" \
      2>/dev/null || true)
  fi
  if [ -n "$AI_SUMMARY" ]; then
    SUMMARY="${AI_SUMMARY}

<details>
<summary>📝 原始对话</summary>

\`\`\`
$PARSED
\`\`\`
</details>"
  else
    SUMMARY="$PARSED"
  fi
else
  # 默认模式: 只生成摘要
  if command -v claude&>/dev/null; then
    SUMMARY=$(printf '%s' "$PARSED" | MEMSEARCH_NO_WATCH=1 CLAUDECODE= claude -p \
      --model haiku \
      --no-session-persistence \
      --no-chrome \
      --system-prompt "用一句话记录这轮对话，格式：'关键词：做了什么'。

示例：
- '摘要优化：将prompt从详细条目改为单行总结'
- '文件搜索：找到stop.sh并读取内容'
- '用户偏好：确认用户喜欢喝茶'

规则：
- 只输出一行，以'-'开头
- 省略所有细节，只保留核心动作
- 用用户使用的语言" \
      2>/dev/null || true)
  fi
  # If claude is not available or returned empty, fall back to raw parsed output
  if [ -z "$SUMMARY" ]; then
    SUMMARY="$PARSED"
  fi
fi

# Append as a sub-heading under the session heading written by SessionStart
# Include HTML comment anchor for progressive disclosure (L3 transcript lookup)
{
  echo "### $NOW"
  if [ -n "$SESSION_ID" ]; then
    echo "<!-- session:${SESSION_ID} turn:${LAST_USER_TURN_UUID} transcript:${TRANSCRIPT_PATH} -->"
  fi
  echo "$SUMMARY"
  echo ""
} >> "$MEMORY_FILE"

# Index immediately — don't rely on watch (which may be killed by SessionEnd before debounce fires)
run_memsearch index "$MEMORY_DIR"

echo '{}'

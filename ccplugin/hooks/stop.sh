#!/usr/bin/env bash
# Stop hook: parse transcript, summarize with claude -p, and save to memory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Prevent infinite loop
STOP_HOOK_ACTIVE=$(_json_val "$INPUT" "stop_hook_active" "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  echo '{}'
  exit 0
fi

# Skip summarization when required API key missing
_required_env_var() {
  case "$1" in
    openai) echo "OPENAI_API_KEY" ;;
    google) echo "GOOGLE_API_KEY" ;;
    voyage) echo "VOYAGE_API_KEY" ;;
    *) echo "" ;;
  esac
}
_PROVIDER=$($MEMSEARCH_CMD config get embedding.provider 2>/dev/null || echo "openai")
_REQ_KEY=$(_required_env_var "$_PROVIDER")
if [ -n "$_REQ_KEY" ] && [ -z "${!_REQ_KEY:-}" ]; then
  echo '{}'
  exit 0
fi

TRANSCRIPT_PATH=$(_json_val "$INPUT" "transcript_path" "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo '{}'
  exit 0
fi

LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
if [ "$LINE_COUNT" -lt 3 ]; then
  echo '{}'
  exit 0
fi

ensure_memory_dir

PARSED=$("$SCRIPT_DIR/parse-transcript.sh" "$TRANSCRIPT_PATH" 2>/dev/null || true)

if [ -z "$PARSED" ] || \
   [ "$PARSED" = "(empty transcript)" ] || \
   [ "$PARSED" = "(no user message found)" ] || \
   [ "$PARSED" = "(empty turn)" ]; then
  echo '{}'
  exit 0
fi

TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M)
MEMORY_FILE="$MEMORY_DIR/$TODAY.md"

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

########################################################
# ✅ 统一的向量优化 Prompt
########################################################

SYSTEM_PROMPT="你是长期记忆系统。

请将本轮对话压缩为一条“向量检索友好”的结构化摘要。

输出格式必须严格如下：

- [主题] 动作 | 对象 | 结果

规则：
- 只输出一行
- 必须以 '- ' 开头
- 主题用方括号包裹，长度2-6个字
- 动作必须是明确动词（优化、设计、分析、修复、实现、解释、确认、重构等）
- 使用 '|' 作为语义分隔符
- 不要使用泛词（讨论、聊天、问题）
- 省略所有细节
- 使用用户的语言
- 不要输出额外说明或示例

示例：
- [记忆系统] 优化摘要结构 | stop hook | 提升向量检索质量
- [数据库] 修复连接错误 | mysql root | 解决权限问题
- [AgentOS] 设计技能加载机制 | progressive loading | 支持模块化扩展"

RAW_MODE="${MEMSEARCH_RAW_TRANSCRIPT:-}"

SUMMARY=""

if [ "$RAW_MODE" = "1" ] || [ "$RAW_MODE" = "true" ]; then

  SUMMARY="$PARSED"

elif [ "$RAW_MODE" = "both" ]; then

  if command -v claude &>/dev/null; then
    AI_SUMMARY=$(printf '%s' "$PARSED" | MEMSEARCH_NO_WATCH=1 CLAUDECODE= claude -p \
      --model haiku \
      --no-session-persistence \
      --no-chrome \
      --system-prompt "$SYSTEM_PROMPT" \
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

  if command -v claude &>/dev/null; then
    SUMMARY=$(printf '%s' "$PARSED" | MEMSEARCH_NO_WATCH=1 CLAUDECODE= claude -p \
      --model haiku \
      --no-session-persistence \
      --no-chrome \
      --system-prompt "$SYSTEM_PROMPT" \
      2>/dev/null || true)
  fi

  if [ -z "$SUMMARY" ]; then
    SUMMARY="$PARSED"
  fi

fi

{
  echo "### $NOW"
  if [ -n "$SESSION_ID" ]; then
    echo "<!-- session:${SESSION_ID} turn:${LAST_USER_TURN_UUID} transcript:${TRANSCRIPT_PATH} -->"
  fi
  echo "$SUMMARY"
  echo ""
} >> "$MEMORY_FILE"

run_memsearch index "$MEMORY_DIR"

echo '{}'
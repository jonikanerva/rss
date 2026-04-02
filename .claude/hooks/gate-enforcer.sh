#!/bin/bash
# Gate enforcer hook for Claude Code PreToolUse
# Blocks: .env reads, any push to main/master, rm -rf
#
# Receives tool input JSON on stdin.
# Exit 2 = block with message on stderr.

set -euo pipefail

TOOL_INPUT=$(cat)

# Extract tool name and command from JSON
TOOL_NAME=$(echo "$TOOL_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")
COMMAND=$(echo "$TOOL_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); i=d.get('tool_input',{}); print(i.get('command',''))" 2>/dev/null || echo "")
FILE_PATH=$(echo "$TOOL_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); i=d.get('tool_input',{}); print(i.get('file_path',''))" 2>/dev/null || echo "")

# Block .env file reads
if [[ "$TOOL_NAME" == "Read" && "$FILE_PATH" == *".env"* ]]; then
  echo "Blocked: reading .env files is not allowed" >&2
  exit 2
fi

# Check Bash commands
if [[ "$TOOL_NAME" == "Bash" && -n "$COMMAND" ]]; then
  # Block .env content reads via shell — extract first word (the actual command)
  # to avoid false positives from .env appearing in arguments like PR bodies
  FIRST_WORD=$(echo "$COMMAND" | awk '{print $1}')
  case "$FIRST_WORD" in
    cat|grep|rg|find|head|tail|less|more|sed|awk)
      if echo "$COMMAND" | grep -qE '\.env(\.|$|\b)'; then
        echo "Blocked: reading .env content is not allowed" >&2
        exit 2
      fi
      ;;
  esac

  # Block any push to main/master (normal or force) — only when git is the actual command
  if [[ "$FIRST_WORD" == "git" ]]; then
    if echo "$COMMAND" | grep -qE '^git push.*\borigin\s+(main|master)(\s|$)'; then
      echo "Blocked: pushing to protected branch (main/master) is not allowed" >&2
      exit 2
    fi
  fi

  # Block rm -rf — only when rm is the actual command
  if [[ "$FIRST_WORD" == "rm" ]] && echo "$COMMAND" | grep -qF 'rm -rf'; then
    echo "Blocked: destructive rm -rf command is not allowed" >&2
    exit 2
  fi
fi

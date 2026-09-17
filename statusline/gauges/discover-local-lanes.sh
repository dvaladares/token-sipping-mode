#!/bin/sh
# discover-local-lanes.sh: list local model lanes on this Mac. One line per lane.
# Plain POSIX sh. No Claude specific paths. Only localhost probes. Always exits 0.
# Usage: discover-local-lanes.sh [--json]
# Callable from any seat or harness (Claude Code, Antigravity, a shell).

JSON=0
[ "$1" = "--json" ] && JSON=1

DB_HOME="${DARKBLOOM_HOME:-$HOME/.darkbloom}"
SKILL_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# port_open PORT -> 0 if something listens on 127.0.0.1:PORT
port_open() {
  if command -v nc >/dev/null 2>&1; then
    nc -z -w1 127.0.0.1 "$1" >/dev/null 2>&1
  elif command -v curl >/dev/null 2>&1; then
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$1/" >/dev/null 2>&1
    [ $? -ne 7 ]
  else
    return 1
  fi
}

# json_field FILE KEY -> first scalar value for "key": value
json_field() {
  sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$1" 2>/dev/null | head -n1
}

# ---------- darkbloom ----------
db_state="missing"; db_mode="none"; db_models=""; db_warm=""; db_port=""; db_local="down"
db_helper="$DB_HOME/bin/ask-qwen"; db_mcp="$DB_HOME/mcp-darkbloom.mjs"
if [ -x "$DB_HOME/bin/darkbloom" ] || [ -f "$DB_HOME/daemon-state.json" ]; then
  db_state="down"
  pid=$(json_field "$DB_HOME/daemon-state.json" pid)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    db_state="up"
    args=$(ps -o command= -p "$pid" 2>/dev/null)
    case "$args" in
      *--local-endpoint*) db_mode="fleet+local" ;;
      *--local*)          db_mode="local" ;;
      *coordinator*)      db_mode="fleet-only" ;;
      *)                  db_mode="unknown" ;;
    esac
  fi
  # daemon-state.json is live; loaded-models.json can be stale by days.
  st="$DB_HOME/daemon-state.json"; [ -f "$st" ] || st=/dev/null
  db_models=$(tr -d '\n' < "$st" 2>/dev/null \
    | sed -n 's/.*"advertised_models"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d '" ')
  db_warm=$(tr -d '\n' < "$st" 2>/dev/null \
    | sed -n 's/.*"warm_models"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d '" ')
  db_port=$(json_field "$DB_HOME/local.json" port); [ -z "$db_port" ] && db_port=8000
  port_open "$db_port" && db_local="up"
fi
[ -x "$db_helper" ] || db_helper="none"
[ -f "$db_mcp" ] || db_mcp="none"
[ -z "$db_port" ] && db_port=0

# ---------- other local servers ----------
# name|default port|binary
OTHERS="ollama|11434|ollama
llama-server|8080|llama-server
mlx_lm|8080|mlx_lm.server
lmstudio|1234|lms"

if [ "$JSON" -eq 1 ]; then
  printf '{"darkbloom":{"daemon":"%s","mode":"%s","models":"%s","warm":"%s","local_port":%s,"local_http":"%s","helper":"%s","mcp":"%s"}' \
    "$db_state" "$db_mode" "$db_models" "$db_warm" "${db_port:-0}" "$db_local" "$db_helper" "$db_mcp"
  printf ',"others":['
  first=1
  echo "$OTHERS" | while IFS='|' read -r name port bin; do
    [ -z "$name" ] && continue
    p="closed"; port_open "$port" && p="open"
    b="absent"; command -v "$bin" >/dev/null 2>&1 && b="present"
    [ $first -eq 0 ] && printf ','
    printf '{"lane":"%s","port":%s,"port_state":"%s","binary":"%s"}' "$name" "$port" "$p" "$b"
    first=0
  done
  printf '],"skill_dir":"%s"}\n' "$SKILL_DIR"
else
  printf 'LANE darkbloom daemon=%s mode=%s models=%s warm=%s local_http=%s port=%s helper=%s mcp=%s\n' \
    "$db_state" "$db_mode" "${db_models:-none}" "${db_warm:-none}" "$db_local" "$db_port" "$db_helper" "$db_mcp"
  echo "$OTHERS" | while IFS='|' read -r name port bin; do
    [ -z "$name" ] && continue
    p="closed"; port_open "$port" && p="open"
    b="absent"; command -v "$bin" >/dev/null 2>&1 && b="present"
    printf 'LANE %s port=%s %s binary=%s\n' "$name" "$port" "$p" "$b"
  done
  if [ "$db_state" = "up" ] && [ "$db_local" = "down" ]; then
    echo "NOTE darkbloom runs in $db_mode mode with no local HTTP listener. Local calls will fail."
    echo "NOTE fix: the operator restarts it with --local-endpoint --model <id>. Never restart it from an agent session."
  fi
fi
exit 0

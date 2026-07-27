#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Line 1: model | context% | dir (branch*) | thinking state
# Line 2/3: rate-limit dot bars for current (5h) and weekly (7d) windows

input=$(cat)

RESET='\033[0m'
BOLD='\033[1m'
C_BLUE='\033[38;5;75m'
C_GREEN='\033[38;5;114m'
C_YELLOW='\033[38;5;221m'
C_ORANGE='\033[38;5;208m'
C_RED='\033[38;5;203m'
C_GRAY='\033[38;5;242m'
C_WHITE='\033[38;5;250m'

model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // "."')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# frugal savings badge (prints nothing until metrics exist).
# Prefer the installed plugin's copy; fall back to the vendored one.
frugal_seg=""
frugal_py=$(ls -d "$HOME"/.claude/plugins/cache/*/frugal/*/scripts/statusline.py 2>/dev/null | head -1)
[ -z "$frugal_py" ] && [ -f "$HOME/.claude/frugal/bin/statusline.py" ] && frugal_py="$HOME/.claude/frugal/bin/statusline.py"
if [ -n "$frugal_py" ]; then
  frugal_txt=$(python3 "$frugal_py" ${session_id:+--session "$session_id"} 2>/dev/null)
  [ -n "$frugal_txt" ] && frugal_seg=" ${C_GRAY}|${RESET} ${C_GREEN}${frugal_txt}${RESET}"
fi
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
thinking=$(echo "$input" | jq -r '.thinking.enabled // false')

five_raw=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_raw=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

pct_color() {
  local pct="${1:-0}"
  if   [ "$pct" -ge 90 ]; then echo "$C_RED"
  elif [ "$pct" -ge 70 ]; then echo "$C_ORANGE"
  else echo "$C_GREEN"; fi
}

dots() {
  local pct="${1:-0}"
  local filled=$(( (pct + 5) / 10 ))
  [ "$filled" -gt 10 ] && filled=10
  [ "$filled" -lt 0 ] && filled=0
  local empty=$((10 - filled))
  local bar=""
  for ((i = 0; i < filled; i++)); do bar+="●"; done
  for ((i = 0; i < empty; i++)); do bar+="○"; done
  echo "$bar"
}

dir_name=$(basename "$cwd")

branch=""
dirty=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ] && dirty="*"
fi

# ---- Line 1 ----
ctx_color=$(pct_color "$ctx_pct")
line1="${BOLD}${C_BLUE}${model}${RESET} ${C_GRAY}|${RESET} ${ctx_color}✍️  ${ctx_pct}%${RESET} ${C_GRAY}|${RESET} ${C_GREEN}${dir_name}${RESET}"
if [ -n "$branch" ]; then
  line1+=" ${C_GRAY}(${RESET}${C_GREEN}${branch}${dirty}${RESET}${C_GRAY})${RESET}"
fi
if [ "$thinking" = "true" ]; then
  line1+=" ${C_GRAY}|${RESET} ${C_GRAY}● thinking${RESET}"
else
  line1+=" ${C_GRAY}|${RESET} ${C_GRAY}○ instant${RESET}"
fi
line1+="$frugal_seg"

# ---- Line 2 / 3: rate limit rows ----
rate_lines=""
if [ -n "$five_raw" ]; then
  five_pct=$(printf '%.0f' "$five_raw")
  five_bar=$(dots "$five_pct")
  five_time=""
  [ -n "$five_reset" ] && five_time=$(date -r "$five_reset" +"%-I:%M%p" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  five_color=$(pct_color "$five_pct")
  row="${C_WHITE}current${RESET}  ${five_color}${five_bar}${RESET} ${five_color}${five_pct}%${RESET}"
  [ -n "$five_time" ] && row+="  ${C_GRAY}↻ ${five_time}${RESET}"
  rate_lines+="${row}\n"
fi
if [ -n "$week_raw" ]; then
  week_pct=$(printf '%.0f' "$week_raw")
  week_bar=$(dots "$week_pct")
  week_time=""
  if [ -n "$week_reset" ]; then
    week_time=$(date -r "$week_reset" +"%b %e, %-I:%M%p" 2>/dev/null | tr -s ' ' | tr '[:upper:]' '[:lower:]')
  fi
  week_color=$(pct_color "$week_pct")
  row="${C_WHITE}weekly${RESET}   ${week_color}${week_bar}${RESET} ${week_color}${week_pct}%${RESET}"
  [ -n "$week_time" ] && row+="  ${C_GRAY}↻ ${week_time}${RESET}"
  rate_lines+="${row}\n"
fi

printf '%b\n' "$line1"
printf '%b' "$rate_lines"

#!/usr/bin/env bash
# claude-statusline — a session-scoped, honest statusline for Claude Code.
#
#   settings.json:  "statusLine": {"type": "command", "command": "bash ~/.claude/statusline.sh",
#                                  "refreshInterval": 30}
#   install.sh symlinks that path (and any other CLAUDE_CONFIG_DIR home) to this file.
#
# LAYOUT (each line is printed only when it has real data):
#   L1  identity   model (slug) · 👤 email [PLAN] (SEAT) · 🤖 agent · ‹session name›
#   L2  budget     ✍️ ctx% (used/size) · ⚡ warm% (ttl) · $cost · frugal · cache MISS · ⧉ compactions
#   L3  place      dir (branch* ⇡ ⇣) · owner/repo · +added −removed · 🌳 worktree · effort · fast · ⏱ session · [VIM]
#   L4  claude 5h  dot bar · pct · pace · ↻ reset (countdown)
#   L5  claude 7d  same          (L5b: spend limit, gateway accounts only)
#   L6  codex 5h   codex's OWN quota telemetry, from its rollout files (optional)
#   L7  codex 7d   same
#   L8  lanes      ← N agents · PR #n · ⇄ today claude N · codex N (tok) · agy N runs
#   L9  mcp        mcp N cfg · N live · DOWN <name>
#
# RULES THIS FILE LIVES BY
#   1. A field with no real data source is OMITTED. Never a placeholder, never a guess,
#      never a zero standing in for "unknown". Absent and empty look the same on screen
#      and mean opposite things.
#   2. Everything about the conversation is read from THIS session's input JSON or THIS
#      session's transcript (.transcript_path), never from a glob over every transcript
#      on the machine. Prompt cache, compactions and MCP liveness are per session.
#   3. One render must stay well under the harness's 300 ms debounce, because a render
#      still running when the next trigger fires is CANCELLED, not queued. One jq pass
#      extracts every input field; the slow helpers run in parallel; expensive lookups
#      are cached and refreshed by detached jobs that a render only READS; and the pure
#      helpers return through the variable R instead of $(...), because on macOS every
#      subshell fork costs 1-2 ms and there used to be ninety of them.
#   4. Nothing account-specific is hardcoded. Plan badge, seat label and quota paths
#      derive from the input JSON and CLAUDE_CONFIG_DIR, with an optional config file
#      at ~/.config/claude-statusline/config.sh for per-machine labels.
#   5. bash 3.2 compatible (stock macOS), and runs on GNU userland too.
#
# HISTORY worth keeping in the file, because each line below was a real bug:
#   2026-08-10  fabricated PR number, quota, shell count, model and identity fallbacks removed
#   2026-08-10  \x1f field separator instead of tab: bash `read` collapses leading empty
#               tab fields even with IFS set to tab alone, misaligning every later field
#   2026-08-11  resets_at arrives as BOTH bare epoch and ISO-8601; bare arithmetic on the
#               ISO form crashed bash and blanked the countdown
#   2026-08-28  the max20x seat wrote no quota file, so every reader saw the other account
#   2026-08-31  codex reports TWO windows (300 and 10080 min); head -1 dropped one silently
#   2026-08-31  `has("subagents")` is TRUE for an explicit null; test the TYPE instead
#   2026-08-31  a merged PR (#1579) rendered for weeks; dead PRs are now filtered
#   2026-09-01  the cache-rebuild field was MACHINE-WIDE (globbed both homes, one shared
#               cache file): every session showed the same "rebuilt 25m ago". Now per session,
#               and from Claude Code's own prompt_cache object (v2.1.251+) when present.
#   2026-09-01  25 jq spawns per render (662 ms) collapsed into one; helpers run in parallel;
#               pure helpers stopped forking subshells
#   2026-09-01  `timeout` does not exist on stock macOS, so guard() silently ran unbounded;
#               perl's Time::HiRes alarm is the portable fallback

# ==============================================================================
# 0. INPUT, LOCATION, CONFIG
# ==============================================================================
input=""
if [ ! -t 0 ]; then IFS= read -r -d '' input; fi      # builtin; no `cat` spawn

# Resolve our own path through symlinks so gauges/ is found when installed as a link.
SL_SELF=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)
[ -z "$SL_SELF" ] && SL_SELF=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]:-$0}" 2>/dev/null)
[ -z "$SL_SELF" ] && SL_SELF="${BASH_SOURCE[0]:-$0}"
SL_HOME=${SL_SELF%/*}
SL_LIB="$SL_HOME/gauges"

# --demo renders the bundled fixture so a fresh clone can see the layout.
case "${1:-}" in
  --demo)    _n=$(date +%s); input=$(sed "s#__CWD__#$PWD#g; s#__TRANSCRIPT__##g; s#__EXPIRES__#$(( _n + 2700 ))#g; s#__LAST_MISS__#$(( _n - 840 ))#g" "$SL_HOME/tests/fixtures/full.json" 2>/dev/null) ;;
  --version) echo "claude-statusline $(cd "$SL_HOME" 2>/dev/null && git describe --tags --always 2>/dev/null || echo dev)"; exit 0 ;;
esac

# Defaults. Override any of these in the config file, which is plain bash.
SL_CACHE_DIR="${SL_CACHE_DIR:-$HOME/.cache/claude-statusline}"
SL_QUOTA_DIR="${SL_QUOTA_DIR:-}"                 # empty = $SL_CACHE_DIR; set to share with other readers
SL_LEGACY_LIB="${SL_LEGACY_LIB:-$HOME/.claude/gauges}"   # a second place to look for helpers, after gauges/
SL_FRUGAL="${SL_FRUGAL:-$HOME/.claude/frugal/bin/statusline.py}"   # the installed hook copy; the repo copy is the fallback
[ -f "$SL_FRUGAL" ] || SL_FRUGAL="$SL_HOME/frugal/statusline.py"
SL_SHOW_CLAUDE_QUOTA="${SL_SHOW_CLAUDE_QUOTA:-1}"
SL_SHOW_CODEX="${SL_SHOW_CODEX:-1}"
SL_SHOW_DELEGATION="${SL_SHOW_DELEGATION:-1}"
SL_SHOW_MCP="${SL_SHOW_MCP:-1}"
SL_SHOW_VERSION="${SL_SHOW_VERSION:-0}"
SL_SHOW_CTX_TOKENS="${SL_SHOW_CTX_TOKENS:-1}"
SL_SHOW_REPO="${SL_SHOW_REPO:-1}"
SL_CTX_WARN="${SL_CTX_WARN:-80}"                 # ctx% at which the context field turns orange
SL_TTL_WARN_S="${SL_TTL_WARN_S:-900}"            # cache TTL left below this turns orange
SL_NARROW_COLS="${SL_NARROW_COLS:-100}"          # below this many columns, drop the dim extras

# Seat label: which config home is this session spending? Default derives from the
# directory name (~/.claude -> "default", ~/.claude-max20x -> "max20x"). A config file
# may redefine seat_label to print whatever the human calls that seat.
seat_label() {
  local b="${1##*/}"; b="${b#.}"
  case "$b" in
    claude)   printf 'default' ;;
    claude-*) printf '%s' "${b#claude-}" ;;
    *)        printf '%s' "$b" ;;
  esac
}

SL_CONFIG="${CLAUDE_STATUSLINE_CONFIG:-$HOME/.config/claude-statusline/config.sh}"
# shellcheck disable=SC1090
[ -r "$SL_CONFIG" ] && . "$SL_CONFIG"

_cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; _cfgdir="${_cfgdir%/}"
SL_SEAT=$(seat_label "$_cfgdir")
SL_SEAT_LC=$(printf '%s' "$SL_SEAT" | tr '[:upper:]' '[:lower:]')
[ -z "$SL_QUOTA_DIR" ] && SL_QUOTA_DIR="$SL_CACHE_DIR"

# The harness sets COLUMNS to the real terminal width (tput cols cannot see it). Below
# the narrow threshold, drop the dim extras first so the important fields survive.
SL_NARROW=0
if [ -n "${COLUMNS:-}" ] && [ "${COLUMNS:-200}" -lt "$SL_NARROW_COLS" ] 2>/dev/null; then
  SL_SHOW_CTX_TOKENS=0; SL_SHOW_REPO=0; SL_NARROW=1
fi

# ==============================================================================
# 1. ONE jq PASS — every input field, \x1f separated
# ==============================================================================
# Why one pass: jq costs real milliseconds to start; the previous version started it 25
# times per render. Why \x1f: bash `read` treats tab as IFS whitespace and silently
# collapses a run of leading empty fields, shifting every later value one slot left.
# \x1f is not whitespace, so empty fields stay empty and aligned. jq builds the
# separator with `[31] | implode` so the source holds no raw control byte.
US=$'\x1f'
IFS="$US" read -r \
  model_id model_name \
  ctx_pct ctx_in ctx_out ctx_size exceeds200k \
  tpath cwd_in session_id session_name cc_version out_style \
  effort_level fast_mode agent_name vim_mode worktree_name \
  repo_owner repo_name \
  cost_usd dur_ms api_ms lines_add lines_del \
  in_email in_org_type in_org_name in_org_tier in_user_tier \
  five_raw five_reset week_raw week_reset spend_raw spend_reset \
  pc_present pc_warm pc_observed pc_ttl pc_expires pc_requests pc_misses pc_expected pc_hit pc_write pc_miss_tok pc_last_miss pc_recache \
  sub_type sub_n pr_num pr_url pr_review pr_kind \
  < <(printf '%s' "$input" | jq -r '
    def s(x): (x // "") | tostring;
    [ s(.model.id), s(.model.display_name),
      s(.context_window.used_percentage // .context.used_percentage // .context_window_used_percentage),
      s(.context_window.total_input_tokens // .context.input_tokens),
      s(.context_window.total_output_tokens),
      s(.context_window.context_window_size),
      s(.exceeds_200k_tokens // false),
      s(.transcript_path), s(.cwd // .workspace.current_dir // .workspace.project_dir),
      s(.session_id), s(.session_name), s(.version), s(.output_style.name),
      s(.effort.level), s(.fast_mode // false), s(.agent.name), s(.vim.mode), s(.worktree.name),
      s(.workspace.repo.owner), s(.workspace.repo.name),
      s(.cost.total_cost_usd), s(.cost.total_duration_ms), s(.cost.total_api_duration_ms),
      s(.cost.total_lines_added), s(.cost.total_lines_removed),
      s(.oauthAccount.emailAddress // .account.email // .email // .user_email),
      s(.oauthAccount.organizationType // .account.type),
      s(.oauthAccount.organizationName // .account.organization),
      s(.oauthAccount.organizationRateLimitTier // .account.tier),
      s(.oauthAccount.userRateLimitTier),
      s(.rate_limits.five_hour.used_percentage // .rate_limits.five_hour.utilization // .quota.current.used_percentage // .quota.five_hour.used_percentage),
      s(.rate_limits.five_hour.resets_at // .quota.current.resets_at // .quota.five_hour.resets_at),
      s(.rate_limits.seven_day.used_percentage // .rate_limits.seven_day.utilization // .quota.weekly.used_percentage // .quota.seven_day.used_percentage),
      s(.rate_limits.seven_day.resets_at // .quota.weekly.resets_at // .quota.seven_day.resets_at),
      s(.rate_limits.spend_limit.used_percentage), s(.rate_limits.spend_limit.resets_at),
      (if (.prompt_cache | type) == "object" then "1" else "" end),
      s(.prompt_cache.warm // false), s(.prompt_cache.caching_observed // false), s(.prompt_cache.ttl),
      s(.prompt_cache.expires_at), s(.prompt_cache.requests), s(.prompt_cache.misses), s(.prompt_cache.expected_rebuilds),
      s(.prompt_cache.hit_ratio), s(.prompt_cache.cache_write_tokens), s(.prompt_cache.miss_recache_tokens),
      s(.prompt_cache.last_miss_at), s(.prompt_cache.recache_tokens_if_cold),
      (.subagents | type), s(.subagents | if type == "array" then length else "" end),
      s(.pr.number), s(.pr.url), s(.pr.review_state), s(.pr.kind)
    ] | join([31] | implode)' 2>/dev/null)

now_epoch=$(date +%s 2>/dev/null)
cwd="$cwd_in"; [ -z "$cwd" ] && cwd="$PWD"

# ==============================================================================
# 2. PORTABILITY SHIMS AND PURE-BASH HELPERS (results land in R; no subshells)
# ==============================================================================
RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; UNDERLINE=$'\033[4m'
C_SKY_BLUE=$'\033[38;5;75m'; C_CYAN=$'\033[38;5;51m'; C_SOFT_GREEN=$'\033[38;5;114m'
C_GOLD=$'\033[38;5;214m'; C_YELLOW=$'\033[38;5;221m'; C_ORANGE=$'\033[38;5;208m'
C_RED=$'\033[38;5;203m'; C_MAGENTA=$'\033[38;5;213m'; C_PURPLE=$'\033[38;5;141m'
C_MUTED_GRAY=$'\033[38;5;242m'; C_LIGHT_GRAY=$'\033[38;5;250m'
R=""

# Run a command with a wall-clock cap. Stock macOS has no `timeout`; without a real cap
# the old guard() was decorative. perl with Time::HiRes takes fractional seconds.
if command -v timeout >/dev/null 2>&1; then
  guard() { local s="$1"; shift; timeout "${s}s" "$@" 2>/dev/null; }
elif command -v gtimeout >/dev/null 2>&1; then
  guard() { local s="$1"; shift; gtimeout "${s}s" "$@" 2>/dev/null; }
elif command -v perl >/dev/null 2>&1; then
  guard() { local s="$1"; shift; perl -MTime::HiRes=alarm -e 'alarm(shift); exec @ARGV' "$s" "$@" 2>/dev/null; }
else
  guard() { shift; "$@" 2>/dev/null; }
fi

case "$OSTYPE" in
  darwin*|*bsd*)
    epoch_fmt()    { date -r "$1" +"$2" 2>/dev/null; }
    iso_to_epoch() { date -j -f "%Y-%m-%dT%H:%M:%S%z" "$1" +%s 2>/dev/null; } ;;
  *)
    epoch_fmt()    { date -d "@$1" +"$2" 2>/dev/null; }
    iso_to_epoch() { date -d "$1" +%s 2>/dev/null; } ;;
esac

# resets_at has arrived as BOTH a bare epoch and an ISO-8601 string. Normalise; anything
# unparseable becomes empty so the segment is omitted rather than guessed.
to_epoch_() {
  local t="$1" n; R=""
  case "$t" in ''|null) return ;; esac
  case "$t" in
    *[!0-9]*)
      n=$(printf '%s' "$t" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
      R=$(iso_to_epoch "$n") ;;
    *) R="$t" ;;
  esac
}

int_() { R="${1%%.*}"; case "$R" in ''|*[!0-9-]*) R="" ;; esac; }
hk_()  { # 123456 -> 123k, 1234567 -> 1.2M, 1333735347 -> 1.3B
  int_ "$1"; local n="$R"; R=""
  [ -z "$n" ] && return
  if   [ "$n" -ge 1000000000 ]; then R="$((n/1000000000)).$(( (n%1000000000)/100000000 ))B"
  elif [ "$n" -ge 1000000 ]; then R="$((n/1000000)).$(( (n%1000000)/100000 ))M"
  elif [ "$n" -ge 1000 ];    then R="$((n/1000))k"
  else R="$n"; fi
}
fmt_dur_() { # seconds -> 45s | 12m | 1h12m | 2d03h
  int_ "$1"; local s="$R" d h m; R=""
  [ -z "$s" ] && return
  [ "$s" -lt 0 ] && s=0
  d=$((s/86400)); h=$(((s%86400)/3600)); m=$(((s%3600)/60))
  if   [ "$d" -gt 0 ]; then printf -v R '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf -v R '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then R="${m}m"
  else R="${s}s"; fi
}
fmt_cd_() { # countdown to an epoch; "now" once passed; empty if no target
  R=""; [ -z "$1" ] && return
  local diff=$(( $1 - now_epoch ))
  if [ "$diff" -le 0 ]; then R="now"; else fmt_dur_ "$diff"; fi
}
pct_color_() {
  local p="${1:-0}"
  if   [ "$p" -ge 90 ]; then R="$C_RED"
  elif [ "$p" -ge 70 ]; then R="$C_ORANGE"
  else R="$C_SOFT_GREEN"; fi
}
dots_() {
  local pct="${1:-0}" filled empty i
  filled=$(( (pct + 5) / 10 )); [ "$filled" -gt 10 ] && filled=10; [ "$filled" -lt 0 ] && filled=0
  empty=$((10 - filled)); R=""
  for ((i = 0; i < filled; i++)); do R+="●"; done
  for ((i = 0; i < empty; i++)); do R+="○"; done
}
join_() { # join non-empty args with " · "
  local out="" seg
  for seg in "$@"; do
    [ -z "$seg" ] && continue
    if [ -z "$out" ]; then out="$seg"; else out="${out} ${C_MUTED_GRAY}·${RESET} ${seg}"; fi
  done
  R="$out"
}
ratio_pct_() { # "0.912" -> 91, "1" -> 100, "0.7" -> 70 ; empty when not a number
  local v="$1" ip fp; R=""
  case "$v" in ''|null) return ;; esac
  ip="${v%%.*}"; fp="${v#*.}"; [ "$fp" = "$v" ] && fp=""
  fp="${fp}000"; fp="${fp:0:3}"
  case "$ip$fp" in ''|*[!0-9]*) return ;; esac
  R=$(( ip * 100 + (10#$fp + 5) / 10 ))
}
# Helper lookup: repo gauges/ first, then the legacy directory. R empty if absent, and
# every caller treats "absent helper" as "omit the field".
lib_() { R=""; if [ -e "$SL_LIB/$1" ]; then R="$SL_LIB/$1"; elif [ -e "$SL_LEGACY_LIB/$1" ]; then R="$SL_LEGACY_LIB/$1"; fi; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }   # the few case changes still spawn tr
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
osc8()  { printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"; }   # clickable text (iTerm2, Kitty, WezTerm)

# ==============================================================================
# 3. BACKGROUND WORK — helpers in parallel, side effects detached
# ==============================================================================
# The three python/bash helpers and the git probes cost 20-30 ms EACH when run one after
# another. Run them concurrently into per-render temp files and collect once; the wall
# cost becomes the slowest one, not the sum. PIDs are waited for individually so the
# detached refresh jobs below are never waited on.
mkdir -p "$SL_CACHE_DIR" 2>/dev/null
_run="$SL_CACHE_DIR/run-$$"
_pids=""
lib_ session-telemetry.py; _tel="$R"
if [ -n "$_tel" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
  guard 0.5 python3 "$_tel" "$tpath" "$now_epoch" > "$_run.tel" 2>/dev/null & _pids="$_pids $!"
fi
if [ -f "$SL_FRUGAL" ]; then
  guard 0.4 python3 "$SL_FRUGAL" ${session_id:+--session "$session_id"} > "$_run.frugal" 2>/dev/null & _pids="$_pids $!"
fi
lib_ mcp-health.sh; _mcp_sh="$R"
if [ "$SL_SHOW_MCP" = "1" ] && [ -n "$_mcp_sh" ]; then
  guard 0.4 bash "$_mcp_sh" "$tpath" "$_cfgdir" > "$_run.mcp" 2>/dev/null & _pids="$_pids $!"
fi
if [ -d "$cwd" ]; then
  { if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
      printf 'branch=%s\n' "$(git -C "$cwd" branch --show-current 2>/dev/null)"
      printf 'ab=%s\n' "$(git -C "$cwd" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)"
      if [ -n "$(guard 0.3 git -C "$cwd" status --porcelain 2>/dev/null | head -1)" ]; then printf 'dirty=*\n'; fi
    fi; } > "$_run.git" 2>/dev/null & _pids="$_pids $!"
fi

# Detached side effects (never waited on):
#  - drop this seat's rate-limit blob where other agents and hooks can read it
#  - keep the last raw input per seat, so "what did the harness actually send?" is a
#    one-line answer on any machine
if [ -n "$input" ]; then
  { printf '%s' "$input" > "$SL_CACHE_DIR/last-input-$SL_SEAT_LC.json.tmp" 2>/dev/null \
      && mv -f "$SL_CACHE_DIR/last-input-$SL_SEAT_LC.json.tmp" "$SL_CACHE_DIR/last-input-$SL_SEAT_LC.json" 2>/dev/null
    if [ -n "$five_raw" ] || [ -n "$week_raw" ]; then
      mkdir -p "$SL_QUOTA_DIR" 2>/dev/null
      _qtmp="$SL_QUOTA_DIR/quota-$SL_SEAT_LC.json.tmp"
      printf '%s' "$input" | jq -c --arg seat "$SL_SEAT_LC" --arg sid "$session_id" \
        'select(.rate_limits != null) | {ts: (now | floor), seat: $seat, session_id: $sid, rate_limits}' > "$_qtmp" 2>/dev/null
      if [ -s "$_qtmp" ]; then
        mv -f "$_qtmp" "$SL_QUOTA_DIR/quota-$SL_SEAT_LC.json" 2>/dev/null
        cp "$SL_QUOTA_DIR/quota-$SL_SEAT_LC.json" "$SL_QUOTA_DIR/quota.json.tmp" 2>/dev/null \
          && mv -f "$SL_QUOTA_DIR/quota.json.tmp" "$SL_QUOTA_DIR/quota.json" 2>/dev/null
      else rm -f "$_qtmp" 2>/dev/null; fi
    fi
  } >/dev/null 2>&1 &
fi

# ==============================================================================
# 4. IDENTITY — model, account, seat, agent, session name
# ==============================================================================
# The harness's display_name is already human ("Fable 5.1", "Opus 5 (1M context)"); trust
# it. The old prettify table relabelled claude-fable-5-1 as "Fable 5", which is wrong.
[ -z "$model_name" ] && model_name="$model_id"
model_field=""
if [ -n "$model_name" ] && [ -n "$model_id" ] && [ "$model_name" != "$model_id" ] && [ "$SL_NARROW" = "0" ]; then
  model_field="${BOLD}${C_SKY_BLUE}${model_name}${RESET} ${C_MUTED_GRAY}(${model_id})${RESET}"
elif [ -n "$model_name" ]; then
  model_field="${BOLD}${C_SKY_BLUE}${model_name}${RESET}"
fi

# Account: the input JSON first; else this seat's own account record on disk. Never
# another seat's.
#
# WHERE THE RECORD LIVES. With CLAUDE_CONFIG_DIR set, Claude Code keeps it in
# <dir>/.claude.json. For the DEFAULT home it is ~/.claude.json (in $HOME), and a stale
# ~/.claude/.claude.json may also exist WITHOUT the oauthAccount key. Found 2026-09-01:
# the default seat read that stale file first, stopped, and showed "no account" while
# ~/.claude.json held the email all along. So: try each candidate for THIS seat in order
# and stop at the first that carries an email.
account_email="$in_email"; org_type="$in_org_type"; org_name="$in_org_name"
org_tier="$in_org_tier"; user_tier="$in_user_tier"
if [ -z "$account_email" ]; then
  if [ -z "${CLAUDE_CONFIG_DIR:-}" ] || [ "$_cfgdir" = "$HOME/.claude" ]; then
    _acct_candidates="$HOME/.claude.json $_cfgdir/.claude.json"
  else
    _acct_candidates="$_cfgdir/.claude.json"
  fi
  for account_file in $_acct_candidates; do
    [ -f "$account_file" ] || continue
    IFS="$US" read -r account_email org_type org_name org_tier user_tier < <(
      guard 0.2 jq -r 'def s(x): (x // "") | tostring;
        [ s(.oauthAccount.emailAddress), s(.oauthAccount.organizationType), s(.oauthAccount.organizationName),
          s(.oauthAccount.organizationRateLimitTier), s(.oauthAccount.userRateLimitTier) ] | join([31] | implode)' "$account_file")
    [ -n "$account_email" ] && break
  done
fi

# Plan badge from the real tier fields only. Unknown tier -> no badge, not a guess.
_tier_lc=$(lower "$org_tier $user_tier")
account_color="$C_CYAN"; account_badge=""
case "$org_type" in
  claude_max)
    account_color="$C_MAGENTA"
    case "$_tier_lc" in *20x*|*_20*) account_badge="MAX 20x" ;; *5x*|*_5*) account_badge="MAX 5x" ;; *) account_badge="MAX" ;; esac ;;
  claude_pro)
    account_color="$C_YELLOW"; account_badge="PRO" ;;
  claude_team)
    # The plan is TEAM; the user's rate-limit tier (e.g. default_claude_max_5x) is shown
    # as a suffix, not relabelled as a MAX plan the org does not have.
    account_badge="$(upper "${org_name:-team}") TEAM"
    case "$_tier_lc" in *20x*) account_badge="${account_badge} 20x" ;; *5x*) account_badge="${account_badge} 5x" ;; esac ;;
  claude_enterprise)
    account_color="$C_PURPLE"; account_badge="ENTERPRISE"; [ -n "$org_name" ] && account_badge="$(upper "$org_name") ENTERPRISE" ;;
  "") ;;
  *)  account_badge=$(upper "${org_type#claude_}" | tr '_' ' ') ;;
esac

seat_tag=$(upper "$SL_SEAT")
if [ -n "$account_email" ]; then
  account_field="${BOLD}${account_color}👤 ${account_email}${RESET}"
  [ -n "$account_badge" ] && account_field="${account_field} ${BOLD}${account_color}[${account_badge}]${RESET}"
  account_field="${account_field} ${account_color}(${seat_tag})${RESET}"
else
  # The seat is always named, even when the email is unknown: two accounts must never
  # look alike. Unknown is reported as unknown, not guessed.
  account_field="${BOLD}${C_YELLOW}👤 seat ${seat_tag}${RESET} ${C_YELLOW}(no account in ${_cfgdir##*/})${RESET}"
fi

agent_field=""; [ -n "$agent_name" ] && agent_field="${C_PURPLE}🤖 ${agent_name}${RESET}"
name_field="";  [ -n "$session_name" ] && [ "$SL_NARROW" = "0" ] && name_field="${C_MUTED_GRAY}‹${session_name}›${RESET}"
version_field=""; [ "$SL_SHOW_VERSION" = "1" ] && [ -n "$cc_version" ] && version_field="${C_MUTED_GRAY}v${cc_version}${RESET}"

# ==============================================================================
# 5. BUDGET — context, prompt cache, cost, compactions (all per session)
# ==============================================================================
int_ "$ctx_pct"; ctx_pct="$R"; int_ "$ctx_in"; ctx_in="$R"; int_ "$ctx_size"; ctx_size="$R"
if [ -z "$ctx_pct" ] && [ -n "$ctx_in" ] && [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ]; then
  ctx_pct=$(( ctx_in * 100 / ctx_size ))
fi
if [ -n "$ctx_pct" ]; then
  if   [ "$ctx_pct" -ge 90 ]; then ctx_color="$C_RED"
  elif [ "$ctx_pct" -ge "$SL_CTX_WARN" ]; then ctx_color="$C_ORANGE"
  else ctx_color="$C_SOFT_GREEN"; fi
  ctx_field="${ctx_color}✍️  ${ctx_pct}%${RESET}"
  if [ "$SL_SHOW_CTX_TOKENS" = "1" ] && [ -n "$ctx_in" ] && [ -n "$ctx_size" ]; then
    hk_ "$ctx_in"; _a="$R"; hk_ "$ctx_size"
    ctx_field="${ctx_field} ${C_MUTED_GRAY}(${_a}/${R})${RESET}"
  fi
  [ "$exceeds200k" = "true" ] && ctx_field="${ctx_field} ${BOLD}${C_RED}>200k${RESET}"
else
  ctx_field="${C_MUTED_GRAY}✍️  --${RESET}"     # explicit no-data marker, not a number
fi

# Collect the parallel helpers now; everything below only reads variables.
[ -n "$_pids" ] && wait $_pids 2>/dev/null
cache_pct=""; rebuild_kind=""; rebuild_size=""; rebuild_age=""; ttl_left=""
compact_n=""; compact_age=""; compact_pre=""; compact_post=""
if [ -s "$_run.tel" ]; then
  while read -r k v; do
    case "$k" in
      cache_pct)     cache_pct="$v" ;;
      rebuild_kind)  rebuild_kind="$v" ;;
      rebuild_size)  rebuild_size="$v" ;;
      rebuild_age_s) rebuild_age="$v" ;;
      ttl_left_s)    ttl_left="$v" ;;
      compact_n)     compact_n="$v" ;;
      compact_age_s) compact_age="$v" ;;
      compact_pre)   compact_pre="$v" ;;
      compact_post)  compact_post="$v" ;;
    esac
  done < "$_run.tel"
fi
frugal_txt=""; [ -s "$_run.frugal" ] && IFS= read -r frugal_txt < "$_run.frugal"
_mcp="";       [ -s "$_run.mcp" ]    && IFS= read -r _mcp < "$_run.mcp"
branch=""; dirty=""; behind=""; ahead=""
if [ -s "$_run.git" ]; then
  while IFS= read -r l; do
    case "$l" in
      branch=*) branch="${l#branch=}" ;;
      dirty=*)  dirty="*" ;;
      ab=*)     l="${l#ab=}"; behind="${l%%[!0-9]*}"; ahead="${l##*[!0-9]}" ;;   # "behind<TAB>ahead"
    esac
  done < "$_run.git"
fi
rm -f "$_run.tel" "$_run.frugal" "$_run.mcp" "$_run.git" 2>/dev/null

# Prompt cache. PRIMARY source: Claude Code's own prompt_cache object (v2.1.251+), which
# is computed from the API's cache token counts for THIS session's main conversation.
# FALLBACK when absent (older Claude Code, or before the first response): the same
# numbers derived from this session's transcript by lib/session-telemetry.py.
warm_field=""; miss_field=""
if [ "$pc_present" = "1" ]; then
  if [ "$pc_observed" = "true" ]; then
    ratio_pct_ "$pc_hit"; hit="$R"
    if [ "$pc_warm" = "true" ]; then
      if [ -n "$hit" ]; then
        if   [ "$hit" -ge 90 ]; then wc_="$C_SOFT_GREEN"; elif [ "$hit" -ge 70 ]; then wc_="$C_ORANGE"; else wc_="$C_RED"; fi
        warm_field="${wc_}⚡ ${hit}% warm${RESET}"
      else
        warm_field="${C_SOFT_GREEN}⚡ warm${RESET}"
      fi
      int_ "$pc_expires"; pc_expires="$R"
      if [ -n "$pc_expires" ]; then
        left=$(( pc_expires - now_epoch )); fmt_dur_ "$left"
        if   [ "$left" -le 0 ];                then warm_field="${warm_field} ${BOLD}${C_RED}(ttl expired)${RESET}"
        elif [ "$left" -le "$SL_TTL_WARN_S" ]; then warm_field="${warm_field} ${C_ORANGE}(ttl ${R})${RESET}"
        else warm_field="${warm_field} ${C_MUTED_GRAY}(ttl ${R})${RESET}"; fi
      fi
    else
      # Cold: the next request re-caches the whole prefix. Say how much, when known.
      warm_field="${BOLD}${C_RED}⚡ cache COLD${RESET}"
      hk_ "$pc_recache"; [ -n "$R" ] && warm_field="${warm_field} ${C_RED}(~${R} to recache)${RESET}"
      [ -n "$hit" ] && warm_field="${warm_field} ${C_MUTED_GRAY}${hit}% session${RESET}"
    fi
  fi
  # A miss re-processes content the cache already held: 20x the price of a hit. Loud
  # for 10 minutes, dim for 3 hours, then gone.
  int_ "$pc_misses"; pc_misses="$R"; int_ "$pc_last_miss"; pc_last_miss="$R"
  if [ -n "$pc_misses" ] && [ "$pc_misses" -gt 0 ] && [ -n "$pc_last_miss" ]; then
    age=$(( now_epoch - pc_last_miss ))
    if [ "$age" -le 10800 ]; then
      detail="${pc_misses}×"; hk_ "$pc_miss_tok"; [ -n "$R" ] && detail="${detail}, ~${R} rewritten"
      fmt_dur_ "$age"
      if [ "$age" -le 600 ]; then
        miss_field="${BOLD}${C_RED}cache MISS ${R} ago${RESET} ${C_MUTED_GRAY}(${detail})${RESET}"
      else
        miss_field="${DIM}${C_YELLOW}cache miss ${R} ago (${detail})${RESET}"
      fi
    fi
  fi
elif [ -n "$cache_pct" ]; then
  if   [ "$cache_pct" -ge 90 ] 2>/dev/null; then wc_="$C_SOFT_GREEN"
  elif [ "$cache_pct" -ge 70 ] 2>/dev/null; then wc_="$C_ORANGE"
  else wc_="$C_RED"; fi
  warm_field="${wc_}⚡ ${cache_pct}% warm${RESET}"
  if [ -n "$ttl_left" ]; then
    fmt_dur_ "$ttl_left"
    if   [ "$ttl_left" -le 0 ] 2>/dev/null;                then warm_field="${warm_field} ${BOLD}${C_RED}(ttl expired)${RESET}"
    elif [ "$ttl_left" -le "$SL_TTL_WARN_S" ] 2>/dev/null; then warm_field="${warm_field} ${C_ORANGE}(ttl ${R})${RESET}"
    else warm_field="${warm_field} ${C_MUTED_GRAY}(ttl ${R})${RESET}"; fi
  fi
  if [ -n "$rebuild_kind" ]; then
    hk_ "$rebuild_size"; _sz="$R"; fmt_dur_ "$rebuild_age"
    if [ "$rebuild_kind" = "HOT" ]; then
      miss_field="${BOLD}${C_RED}cache ~${_sz} REBUILT ${R} ago${RESET}"
    else
      miss_field="${DIM}${C_YELLOW}cache ~${_sz} rebuilt ${R} ago${RESET}"
    fi
  fi
fi

compact_field=""
if [ -n "$compact_n" ] && [ "$compact_n" -gt 0 ] 2>/dev/null; then
  compact_field="${C_MUTED_GRAY}⧉ ${compact_n}× compacted"
  if [ -n "$compact_age" ]; then
    fmt_dur_ "$compact_age"; compact_field="${compact_field} (${R} ago"
    if [ -n "$compact_pre" ] && [ -n "$compact_post" ] && [ "$SL_NARROW" = "0" ]; then
      hk_ "$compact_pre"; _a="$R"; hk_ "$compact_post"; compact_field="${compact_field}, ${_a}→${R}"
    fi
    compact_field="${compact_field})"
  fi
  compact_field="${compact_field}${RESET}"
fi

# Cost: omitted when absent AND when zero. Team and Enterprise plans report 0 for every
# session; a permanent "$0.00" is noise that teaches the eye to skip the field.
cost_field=""
if [ -n "$cost_usd" ]; then
  printf -v cost_fmt '%.2f' "$cost_usd" 2>/dev/null
  [ -n "$cost_fmt" ] && [ "$cost_fmt" != "0.00" ] && cost_field="${C_GOLD}\$${cost_fmt}${RESET}"
fi
frugal_field=""; [ -n "$frugal_txt" ] && frugal_field="${C_SOFT_GREEN}${frugal_txt}${RESET}"

# ==============================================================================
# 6. PLACE — directory, git, repo, lines changed, worktree, effort, duration, vim
# ==============================================================================
dir_name="${cwd##*/}"; [ -z "$dir_name" ] && dir_name="root"; [ "$cwd" = "$HOME" ] && dir_name="~"
# Upstream divergence from `rev-list --left-right --count @{u}...HEAD`: ⇡ commits to
# push, ⇣ commits to pull. Shown only when non-zero; absent entirely with no upstream.
ab_field=""
[ -n "$ahead" ]  && [ "$ahead" != "0" ]  && ab_field=" ${C_SOFT_GREEN}⇡${ahead}${RESET}"
[ -n "$behind" ] && [ "$behind" != "0" ] && ab_field="${ab_field} ${C_ORANGE}⇣${behind}${RESET}"
branch_field=""; [ -n "$branch" ] && branch_field=" ${C_MUTED_GRAY}(${RESET}${C_SOFT_GREEN}${branch}${dirty}${RESET}${ab_field}${C_MUTED_GRAY})${RESET}"
dir_field="${C_SOFT_GREEN}${dir_name}${RESET}${branch_field}"

# owner/repo from the origin remote, parsed by the harness (zero cost). Shown when it
# adds information, i.e. the directory name is not already the repo name.
repo_field=""
if [ "$SL_SHOW_REPO" = "1" ] && [ -n "$repo_name" ] && [ "$repo_name" != "$dir_name" ]; then
  repo_field="${C_MUTED_GRAY}${repo_owner:+$repo_owner/}${repo_name}${RESET}"
fi

lines_field=""
int_ "$lines_add"; lines_add="$R"; int_ "$lines_del"; lines_del="$R"
if [ -n "$lines_add$lines_del" ] && [ $(( ${lines_add:-0} + ${lines_del:-0} )) -gt 0 ]; then
  lines_field="${C_SOFT_GREEN}+${lines_add:-0}${RESET} ${C_RED}−${lines_del:-0}${RESET}"
fi

worktree_field=""; [ -n "$worktree_name" ] && worktree_field="${C_PURPLE}🌳 ${worktree_name}${RESET}"

effort_field=""
if [ -n "$effort_level" ]; then
  case "$effort_level" in
    low) ec="$C_SOFT_GREEN" ;; medium) ec="$C_YELLOW" ;; high) ec="$C_ORANGE" ;; xhigh|max) ec="$C_RED" ;; *) ec="$C_MUTED_GRAY" ;;
  esac
  effort_field="${ec}${effort_level}${RESET}"
fi
fast_field=""; [ "$fast_mode" = "true" ] && fast_field="${C_CYAN}fast${RESET}"

dur_field=""
int_ "$dur_ms"; dur_ms="$R"
if [ -n "$dur_ms" ] && [ "$dur_ms" -ge 60000 ]; then
  fmt_dur_ $((dur_ms / 1000)); dur_field="${C_MUTED_GRAY}⏱ ${R}${RESET}"
fi

vim_field=""; [ -n "$vim_mode" ] && vim_field="${C_MUTED_GRAY}[$(upper "$vim_mode")]${RESET}"

# ==============================================================================
# 7. QUOTA BARS — claude (from input) and codex (its own telemetry)
# ==============================================================================
# One renderer for every window; result in R. Reset time shows as a clock when it is
# within a day, as a date when further out. Prints NOTHING without a real percent: a
# missing window must never read as 0%, which means "plenty left" at exactly the wrong
# moment.
#
# PACE (4th arg = window length in seconds). Compares quota used against time elapsed
# in the window: 56% used with 30% of the window gone is ⇡26 (burning fast); 11% used
# with 60% gone is ⇣49 (headroom). Quiet within 10 points of pace, so a healthy window
# shows nothing extra. Pure arithmetic on fields the harness already sends.
quota_line_() {
  local label="$1" pct="$2" reset="$3" win="${4:-}" bar color out t elapsed pace
  int_ "$pct"; pct="$R"; R=""; [ -z "$pct" ] && return 0
  int_ "$reset"; reset="$R"
  dots_ "$pct"; bar="$R"; pct_color_ "$pct"; color="$R"
  out="${C_LIGHT_GRAY}${label}${RESET} ${color}${bar}${RESET} ${color}${pct}%${RESET}"
  if [ -n "$win" ] && [ -n "$reset" ] && [ "$reset" -gt "$now_epoch" ] && [ $((reset - now_epoch)) -le "$win" ]; then
    elapsed=$(( (win - (reset - now_epoch)) * 100 / win ))
    pace=$(( pct - elapsed ))
    if   [ "$pace" -ge 10 ];  then out="${out} ${C_RED}⇡${pace}${RESET}"
    elif [ "$pace" -le -10 ]; then out="${out} ${C_SOFT_GREEN}⇣${pace#-}${RESET}"; fi
  fi
  if [ -n "$reset" ]; then
    if [ $((reset - now_epoch)) -lt 86400 ]; then t=$(epoch_fmt "$reset" "%-I:%M%p")
    else t=$(epoch_fmt "$reset" "%a %b %-e, %-I:%M%p"); fi
    t="${t/%AM/am}"; t="${t/%PM/pm}"
    fmt_cd_ "$reset"
    [ -n "$t" ] && out="${out}  ${C_MUTED_GRAY}↻ ${t} (${R})${RESET}"
  fi
  R="$out"
}

line_5h=""; line_7d=""; line_spend=""
if [ "$SL_SHOW_CLAUDE_QUOTA" = "1" ]; then
  # printf %.0f rounds the harness's float; int_ alone would truncate 99.6 to 99
  if [ -n "$five_raw" ]; then
    printf -v _p '%.0f' "$five_raw" 2>/dev/null; to_epoch_ "$five_reset"
    quota_line_ "claude 5h" "$_p" "$R" 18000; line_5h="$R"
  fi
  if [ -n "$week_raw" ]; then
    printf -v _p '%.0f' "$week_raw" 2>/dev/null; to_epoch_ "$week_reset"
    quota_line_ "claude 7d" "$_p" "$R" 604800; line_7d="$R"
  fi
  if [ -n "$spend_raw" ]; then
    printf -v _p '%.0f' "$spend_raw" 2>/dev/null; to_epoch_ "$spend_reset"
    quota_line_ "spend    " "$_p" "$R"; line_spend="$R"
  fi
fi

# ==============================================================================
# 8. LANES — subagents, PR, delegation gauge (cached, refreshed in the background)
# ==============================================================================
agent_str=""
if [ "$sub_type" = "array" ] && [ -n "$sub_n" ]; then
  if [ "$sub_n" -eq 1 ] 2>/dev/null; then agent_str="${C_LIGHT_GRAY}← 1 agent${RESET}"
  else agent_str="${C_LIGHT_GRAY}← ${sub_n} agents${RESET}"; fi
fi

# PR: the harness's .pr.number first; else this seat's branch-matched cache. Then drop
# MERGED/CLOSED PRs: a statusline shows what is ACTIONABLE. Keys are full URLs, so one
# number can match several repos; hide only when EVERY match is dead. Hiding a live PR
# is the harmful error; showing a dead one is only noise.
_prcache="$_cfgdir/gh-pr-status-cache.json"
if [ -z "$pr_num" ] && [ -f "$_prcache" ] && [ -n "$branch" ]; then
  pr_num=$(guard 0.1 jq -r --arg b "$branch" 'to_entries[] | select(.key | endswith($b) or contains($b)) | .value.number // empty' "$_prcache" | head -1)
fi
if [ -n "$pr_num" ]; then
  _dead=0; _alive=0
  for _c in "$_prcache" "$HOME"/.claude*/gh-pr-status-cache.json; do
    [ -f "$_c" ] || continue
    for _s in $(guard 0.1 jq -r --argjson n "$pr_num" 'to_entries[] | select(.value.number == $n) | .value.state // empty' "$_c"); do
      case "$_s" in MERGED|CLOSED) _dead=$((_dead + 1)) ;; *) _alive=$((_alive + 1)) ;; esac
    done
  done
  [ "$_dead" -gt 0 ] && [ "$_alive" -eq 0 ] && pr_num=""
fi
pr_str=""
if [ -n "$pr_num" ]; then
  pr_label="PR"; [ "$pr_kind" = "mr" ] && pr_label="MR"
  pr_txt="#${pr_num}"; [ -n "$pr_url" ] && pr_txt=$(osc8 "$pr_url" "#${pr_num}")
  pr_str="${C_LIGHT_GRAY}${pr_label} ${UNDERLINE}${pr_txt}${RESET}"
  if [ -n "$pr_review" ]; then
    case "$(lower "$pr_review")" in
      *approved*) sc="$C_SOFT_GREEN"; sl="approved" ;;
      *changes*)  sc="$C_RED"; sl="changes requested" ;;
      *draft*)    sc="$C_MUTED_GRAY"; sl="draft" ;;
      *pending*)  sc="$C_YELLOW"; sl="pending" ;;
      *comment*)  sc="$C_CYAN"; sl="commented" ;;
      *)          sc="$C_MUTED_GRAY"; sl=$(lower "$pr_review") ;;
    esac
    pr_str="${pr_str} ${C_MUTED_GRAY}·${RESET} ${sc}${sl}${RESET}"
  fi
fi

# Delegation gauge: today's runs AND tokens per lane, from each lane's OWN records, plus
# codex's OWN quota (both windows). gauges/today-usage.py does the counting:
#   claude = transcripts touched today under every ~/.claude*/projects; in = input +
#            cache_creation + cache_read of today's responses, out = output tokens
#   codex  = rollouts under ~/.codex/sessions/Y/M/D; in/out/total from total_token_usage
#   agy    = brain conversation dirs touched today; agy records no token usage on disk,
#            so its tokens are `-` and the field is omitted, never invented
# Refreshed by a detached job into an atomic cache with a version tag; a reader discards
# any cache whose tag it does not know, because a shifted column prints confident nonsense.
deleg_cache="$SL_CACHE_DIR/delegation-lanes.cache"; deleg_ttl=60; DELEG_TAG="v6"
_deleg_refresh() {
  local tmp="${deleg_cache}.tmp.$$" tu cq
  local cl_n="-" cl_in="-" cl_out="-" cdx_n="-" cdx_in="-" cdx_out="-" cdx_tok="-" agy_n="-" agy_in="-" agy_out="-"
  local cdx_pct="-" cdx_reset="-" cdx7_pct="-" cdx7_reset="-" cdx_age="-"
  lib_ today-usage.py; tu="$R"
  if [ -n "$tu" ]; then
    read -r cl_n cl_in cl_out cdx_n cdx_in cdx_out cdx_tok agy_n agy_in agy_out < <(guard 20 python3 "$tu")
    : "${cl_n:=-}" "${cl_in:=-}" "${cl_out:=-}" "${cdx_n:=-}" "${cdx_in:=-}" "${cdx_out:=-}" "${cdx_tok:=-}" "${agy_n:=-}" "${agy_in:=-}" "${agy_out:=-}"
  fi
  if [ -d "$HOME/.codex/sessions" ]; then
    lib_ codex-quota.py; cq="$R"
    if [ -n "$cq" ]; then
      # FIVE fields; the fifth is telemetry age. A missing catch variable would append it
      # to the fourth and corrupt the weekly reset.
      read -r cdx_pct cdx_reset cdx7_pct cdx7_reset cdx_age < <(guard 1.5 python3 "$cq")
      : "${cdx_pct:=-}" "${cdx_reset:=-}" "${cdx7_pct:=-}" "${cdx7_reset:=-}" "${cdx_age:=-}"
    fi
  fi
  printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' "$DELEG_TAG" "$(date +%s)" \
      "$cl_n" "$cl_in" "$cl_out" "$cdx_n" "$cdx_in" "$cdx_out" "$cdx_tok" \
      "$cdx_pct" "$cdx_reset" "$cdx7_pct" "$cdx7_reset" "$cdx_age" "$agy_n" "$agy_in" "$agy_out" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$deleg_cache" 2>/dev/null
}

deleg_tag=""; deleg_ts=0
cl_n=""; cl_in=""; cl_out=""; cdx_n=""; cdx_in=""; cdx_out=""; cdx_tok=""; cdx_pct=""; cdx_reset=""; cdx7_pct=""; cdx7_reset=""; cdx_age=""; agy_n=""; agy_in=""; agy_out=""
if [ "$SL_SHOW_DELEGATION" = "1" ] || [ "$SL_SHOW_CODEX" = "1" ]; then
  [ -f "$deleg_cache" ] && read -r deleg_tag deleg_ts cl_n cl_in cl_out cdx_n cdx_in cdx_out cdx_tok cdx_pct cdx_reset cdx7_pct cdx7_reset cdx_age agy_n agy_in agy_out < "$deleg_cache" 2>/dev/null
  case "$deleg_ts" in ''|*[!0-9]*) deleg_ts=0 ;; esac
  if [ "$deleg_tag" != "$DELEG_TAG" ]; then
    cl_n=""; cl_in=""; cl_out=""; cdx_n=""; cdx_in=""; cdx_out=""; cdx_tok=""; cdx_pct=""; cdx_reset=""; cdx7_pct=""; cdx7_reset=""; cdx_age=""; agy_n=""; agy_in=""; agy_out=""; deleg_ts=0
  fi
  [ $(( now_epoch - deleg_ts )) -ge "$deleg_ttl" ] && ( _deleg_refresh ) >/dev/null 2>&1 &
  for v in cl_n cl_in cl_out cdx_n cdx_in cdx_out cdx_tok cdx_pct cdx_reset cdx7_pct cdx7_reset cdx_age agy_n agy_in agy_out; do
    eval "[ \"\$$v\" = \"-\" ] && $v=\"\""
  done
fi

line_cdx=""; line_cdx7=""
if [ "$SL_SHOW_CODEX" = "1" ]; then
  quota_line_ "codex 5h" "$cdx_pct" "$cdx_reset" 18000;   line_cdx="$R"
  quota_line_ "codex 7d" "$cdx7_pct" "$cdx7_reset" 604800; line_cdx7="$R"
fi

# One shape for every lane: "<lane> <runs> (<in> in · <out> out)". The token pair is
# omitted when the lane records none (agy today), and dropped on a narrow pane. Input
# for Claude includes cache reads on purpose: that is what carrying the context costs.
lane_seg_() { # color label runs in out -> R
  local color="$1" label="$2" n="$3" tin="$4" tout="$5" a b
  R=""; [ -z "$n" ] && return
  R="${color}${label} ${BOLD}${n}${RESET}"
  if [ "$SL_NARROW" = "0" ] && [ -n "$tin" ] && [ -n "$tout" ] && [ "$tin" -gt 0 ] 2>/dev/null; then
    hk_ "$tin"; a="$R"; hk_ "$tout"; b="$R"
    R="${color}${label} ${BOLD}${n}${RESET} ${C_MUTED_GRAY}(${a} in · ${b} out)${RESET}"
  fi
}
deleg_str=""
if [ "$SL_SHOW_DELEGATION" = "1" ]; then
  parts=""
  lane_seg_ "$C_SKY_BLUE" claude "$cl_n" "$cl_in" "$cl_out";   [ -n "$R" ] && { seg="$R"; join_ "$parts" "$seg"; parts="$R"; }
  lane_seg_ "$C_CYAN"     codex  "$cdx_n" "$cdx_in" "$cdx_out"; [ -n "$R" ] && { seg="$R"; join_ "$parts" "$seg"; parts="$R"; }
  lane_seg_ "$C_PURPLE"   agy    "$agy_n" "$agy_in" "$agy_out"; [ -n "$R" ] && { seg="$R"; join_ "$parts" "$seg"; parts="$R"; }
  [ -n "$parts" ] && deleg_str="${C_LIGHT_GRAY}⇄ today${RESET}  ${parts} ${C_MUTED_GRAY}runs${RESET}"
fi

# ==============================================================================
# 9. MCP HEALTH — cfg / live / DOWN, from this session's transcript
# ==============================================================================
line_mcp=""
if [ -n "$_mcp" ]; then
  # Shape: "mcp 7 cfg · 3 live · DOWN aws-mcp". Parsed with bash expansions, no sed spawns.
  _n_cfg=""; _n_live=""; _down=""
  case "$_mcp" in *" cfg"*)  _n_cfg="${_mcp%% cfg*}";   _n_cfg="${_n_cfg##* }" ;; esac
  case "$_mcp" in *" live"*) _n_live="${_mcp%% live*}"; _n_live="${_n_live##* }" ;; esac
  case "$_mcp" in *"DOWN "*) _down="${_mcp##*DOWN }" ;; esac
  case "$_n_cfg"  in *[!0-9]*) _n_cfg="" ;; esac
  case "$_n_live" in *[!0-9]*) _n_live="" ;; esac
  if [ -n "$_n_cfg" ]; then
    line_mcp="${C_MUTED_GRAY}mcp${RESET} ${C_LIGHT_GRAY}${_n_cfg} cfg${RESET}"
    [ -n "$_n_live" ] && line_mcp="${line_mcp} ${C_MUTED_GRAY}·${RESET} ${C_SOFT_GREEN}${_n_live} live${RESET}"
    [ -n "$_down" ]   && line_mcp="${line_mcp} ${C_MUTED_GRAY}·${RESET} ${BOLD}${C_RED}DOWN ${_down}${RESET}"
  else
    # Unknown shape: show it raw rather than drop it. Absence reads as health.
    case "$_mcp" in *DOWN*) line_mcp="${BOLD}${C_RED}${_mcp}${RESET}" ;; *) line_mcp="${C_MUTED_GRAY}${_mcp}${RESET}" ;; esac
  fi
fi

# ==============================================================================
# 10. OUTPUT
# ==============================================================================
join_ "$model_field" "$account_field" "$agent_field" "$name_field" "$version_field"; line1="$R"
join_ "$ctx_field" "$warm_field" "$cost_field" "$frugal_field" "$miss_field" "$compact_field"; line2="$R"
join_ "$dir_field" "$repo_field" "$lines_field" "$worktree_field" "$effort_field" "$fast_field" "$dur_field" "$vim_field"; line3="$R"
join_ "$agent_str" "$pr_str" "$deleg_str"; line8="$R"

for l in "$line1" "$line2" "$line3" "$line_5h" "$line_7d" "$line_spend" "$line_cdx" "$line_cdx7" "$line8" "$line_mcp"; do
  [ -n "$l" ] && printf '%s\n' "$l"
done
# The harness hides a statusline whose command fails; always end successful.
exit 0

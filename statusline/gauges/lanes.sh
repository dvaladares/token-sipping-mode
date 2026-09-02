#!/usr/bin/env bash
# lanes.sh — burn gauges + delegation-lane probe + ladder rung, one call.
#
# Portable by design: every gauge and lane is probed, never assumed. A gauge with no
# real source prints UNKNOWN, never a fabricated number. Read-only, well under a second,
# safe to run at the top of every turn.
#
# Output contract (stable, parse-friendly):
#   GAUGE claude_5h <pct|UNKNOWN> [reset_epoch]
#   GAUGE claude_7d <pct|UNKNOWN> [reset_epoch]
#   GAUGE quota_age_s <seconds|UNKNOWN>
#   GAUGE quota_seat <seat|UNKNOWN>          which account the headline numbers describe
#   GAUGE seat <name> <5h> <7d> <age_s>      one line PER account, so you can see them all
#   GAUGE codex_5h <pct|UNKNOWN> [reset_epoch]
#   GAUGE codex_7d <pct|UNKNOWN> [reset_epoch]
#   LANE <name> <ok|missing|cold> [detail]
#   RUNG <L0|L1|L2|L3> <reason>
#
# Sources. The statusline writes quota-<seat>.json (and a most-recent quota.json) on
# every render into SL_QUOTA_DIR, and a delegation cache with codex's own telemetry.
# Both locations come from the same config file the statusline reads, so the two never
# disagree about where the numbers live.
set -uo pipefail
now=$(date +%s)

SL_CACHE_DIR="${SL_CACHE_DIR:-$HOME/.cache/claude-statusline}"
SL_QUOTA_DIR="${SL_QUOTA_DIR:-}"
SL_CONFIG="${CLAUDE_STATUSLINE_CONFIG:-$HOME/.config/claude-statusline/config.sh}"
# shellcheck disable=SC1090
[ -r "$SL_CONFIG" ] && . "$SL_CONFIG"
[ -z "$SL_QUOTA_DIR" ] && SL_QUOTA_DIR="$SL_CACHE_DIR"
QUOTA="${CLAUDE_QUOTA_FILE:-$SL_QUOTA_DIR/quota.json}"

have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1

# ---------- Claude plan windows (most recent render, any seat) ----------
five="UNKNOWN"; week="UNKNOWN"; age="UNKNOWN"; five_reset=""; week_reset=""; qseat="UNKNOWN"
if [ "$have_jq" = 1 ] && [ -f "$QUOTA" ]; then
  ts=$(jq -r '.ts // empty' "$QUOTA" 2>/dev/null)
  if [ -n "$ts" ]; then
    age=$(( now - ts ))
    five=$(jq -r '.rate_limits.five_hour.used_percentage // "UNKNOWN"' "$QUOTA")
    week=$(jq -r '.rate_limits.seven_day.used_percentage // "UNKNOWN"' "$QUOTA")
    five_reset=$(jq -r '.rate_limits.five_hour.resets_at // empty' "$QUOTA")
    week_reset=$(jq -r '.rate_limits.seven_day.resets_at // empty' "$QUOTA")
  fi
  qseat=$(jq -r '.seat // "UNKNOWN"' "$QUOTA" 2>/dev/null || echo UNKNOWN)
fi
echo "GAUGE claude_5h ${five} ${five_reset}"
echo "GAUGE claude_7d ${week} ${week_reset}"
echo "GAUGE quota_age_s ${age}"
echo "GAUGE quota_seat ${qseat}"

# One line per account. A seat that has not rendered simply does not appear; absent is
# unknown, never assumed empty.
if [ "$have_jq" = 1 ]; then
  for _qf in "$SL_QUOTA_DIR"/quota-*.json; do
    [ -f "$_qf" ] || continue
    _sn=$(jq -r '.seat // empty' "$_qf" 2>/dev/null); [ -n "$_sn" ] || continue
    _st=$(jq -r '.ts // empty' "$_qf" 2>/dev/null)
    _s5=$(jq -r '.rate_limits.five_hour.used_percentage // "UNKNOWN" | if type == "number" then round else . end' "$_qf" 2>/dev/null)
    _s7=$(jq -r '.rate_limits.seven_day.used_percentage // "UNKNOWN" | if type == "number" then round else . end' "$_qf" 2>/dev/null)
    if [ -n "$_st" ]; then _sa=$(( now - _st )); else _sa="UNKNOWN"; fi
    echo "GAUGE seat ${_sn} ${_s5} ${_s7} ${_sa}"
  done
fi

# ---------- Codex windows (its own rollout telemetry, cached by the statusline) ----------
# Cache layout is versioned; an unknown tag is discarded, not partially trusted.
cdx5="UNKNOWN"; cdx5_reset=""; cdx7="UNKNOWN"; cdx7_reset=""
DELEG="$SL_CACHE_DIR/delegation-lanes.cache"
if [ -f "$DELEG" ]; then
  read -r tag _dts _cl _cli _clo _cn _cin _cout _ct _p5 _r5 _p7 _r7 _age _agy _ain _aout < "$DELEG" 2>/dev/null
  if [ "${tag:-}" = "v6" ]; then
    [ -n "${_p5:-}" ] && [ "$_p5" != "-" ] && cdx5="$_p5"
    [ -n "${_r5:-}" ] && [ "$_r5" != "-" ] && cdx5_reset="$_r5"
    [ -n "${_p7:-}" ] && [ "$_p7" != "-" ] && cdx7="$_p7"
    [ -n "${_r7:-}" ] && [ "$_r7" != "-" ] && cdx7_reset="$_r7"
  fi
fi
echo "GAUGE codex_5h ${cdx5} ${cdx5_reset}"
echo "GAUGE codex_7d ${cdx7} ${cdx7_reset}"

# ---------- Lane probes: existence and readiness, never assumed ----------
for lane in codex agy; do
  if command -v "$lane" >/dev/null 2>&1; then echo "LANE $lane ok $(command -v "$lane")"
  else echo "LANE $lane missing"; fi
done
# A local model server, if you run one. Set LOCAL_LANE_CMD to a command that exits 0
# when the server is up (default: darkbloom's local endpoint check).
DB="${LOCAL_LANE_BIN:-$HOME/.darkbloom/bin/darkbloom}"
if [ -x "$DB" ]; then
  if "$DB" local --json >/dev/null 2>&1; then echo "LANE local ok $DB"
  else echo "LANE local cold run: $DB start --local"; fi
else
  echo "LANE local missing"
fi

# ---------- Ladder rung ----------
# Worst of the two Claude windows decides. UNKNOWN or stale (>30 min) gauges fail
# CONSERVATIVE: one rung above L0 rather than assumed headroom.
rung="L0"; reason="fresh windows"
n5=""; n7=""
case "$five" in ''|UNKNOWN) ;; *) n5=${five%.*} ;; esac
case "$week" in ''|UNKNOWN) ;; *) n7=${week%.*} ;; esac
if [ -z "$n5" ] || [ -z "$n7" ] || { [ "$age" != "UNKNOWN" ] && [ "$age" -gt 1800 ]; }; then
  rung="L1"; reason="gauges unknown or stale (${age}s), fail conservative"
else
  if   [ "$n5" -ge 90 ] || [ "$n7" -ge 85 ]; then rung="L3"; reason="5h=${n5}% 7d=${n7}%"
  elif [ "$n5" -ge 75 ] || [ "$n7" -ge 65 ]; then rung="L2"; reason="5h=${n5}% 7d=${n7}%"
  elif [ "$n5" -ge 50 ] || [ "$n7" -ge 40 ]; then rung="L1"; reason="5h=${n5}% 7d=${n7}%"
  else rung="L0"; reason="5h=${n5}% 7d=${n7}%"
  fi
fi
echo "RUNG ${rung} ${reason}"

#!/bin/bash
# Which statusline input fields does the INSTALLED Claude Code know about?
# Greps the compiled binary for the key names this script reads. A zero next to a key
# means the installed version will never send it, so the field will (correctly) stay
# omitted. Useful when a machine runs an older Claude Code than the one this was
# written against (2.1.257).
B=""
for c in "$HOME/.local/share/claude/current" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$(command -v claude 2>/dev/null)"; do
  [ -n "$c" ] && [ -e "$c" ] && { B=$(readlink -f "$c" 2>/dev/null || echo "$c"); break; }
done
[ -n "$B" ] || { echo "claude binary not found" >&2; exit 1; }
echo "binary: $B"
claude --version 2>/dev/null
for k in prompt_cache expires_at hit_ratio expected_rebuilds miss_recache_tokens recache_tokens_if_cold \
         caching_observed last_miss_at utilization used_percentage resets_at overage spend_limit \
         used_percentage total_lines_added total_duration_ms total_api_duration_ms \
         context_window_size current_usage exceeds_200k_tokens session_name output_style \
         added_dirs original_branch review_state transcript_path refreshInterval subagentStatusLine; do
  n=$(LC_ALL=C grep -a -o -- "\"$k\"" "$B" 2>/dev/null | wc -l | tr -d ' ')
  printf '  %-26s %s\n' "$k" "$n"
done

# ~/.config/claude-statusline/config.sh
# Plain bash, sourced by statusline.sh on every render. Everything here is optional.
# Copy this file there (install.sh does it once) and edit.

# Seat label: what the statusline prints next to the account, and the <seat> part of
# quota-<seat>.json. Argument is the resolved CLAUDE_CONFIG_DIR. The default derives it
# from the directory name (~/.claude -> "default", ~/.claude-max20x -> "max20x").
# Example for a machine with two seats:
# seat_label() {
#   case "$1" in
#     *".claude-max20x") printf 'M2' ;;
#     *)                 printf 'M4' ;;
#   esac
# }

# Where quota-<seat>.json (and the legacy quota.json) are written for other tools to
# read. Default: $SL_CACHE_DIR (~/.cache/claude-statusline).
# SL_QUOTA_DIR="$HOME/.claude/torch-agy"

# Section toggles (1 = show when data exists, 0 = never)
# SL_SHOW_CLAUDE_QUOTA=1     claude 5h / 7d / spend bars
# SL_SHOW_CODEX=1            codex 5h / 7d bars from ~/.codex rollouts
# SL_SHOW_DELEGATION=1       "today: claude N · codex N · agy N runs"
# SL_SHOW_MCP=1              mcp cfg / live / DOWN
# SL_SHOW_CTX_TOKENS=1       "(80k/200k)" after the context percent
# SL_SHOW_REPO=1             owner/repo when it differs from the directory name
# SL_SHOW_VERSION=0          Claude Code version on line 1

# Thresholds
# SL_CTX_WARN=80             context percent that turns orange (red is always 90)
# SL_TTL_WARN_S=900          cache TTL seconds left that turns orange
# SL_NARROW_COLS=100         terminal width below which dim extras are dropped

# Paths
# SL_CACHE_DIR="$HOME/.cache/claude-statusline"
# SL_LEGACY_LIB="$HOME/.claude/limit-sentinel"     second place to look for lib helpers
# SL_FRUGAL="$HOME/.claude/frugal/bin/statusline.py"  optional savings badge; omitted if absent

#!/bin/bash
# Install claude-statusline into one or more Claude Code config homes.
#
#   ./install.sh                          -> ~/.claude
#   ./install.sh ~/.claude ~/.claude-max20x   (one link per CLAUDE_CONFIG_DIR home)
#
# What it does, per home:
#   1. backs up an existing statusline.sh to statusline.sh.bak-<stamp> (unless it is
#      already a symlink into this repo)
#   2. symlinks <home>/statusline.sh -> <repo>/statusline.sh, so every home runs ONE
#      file and none can drift
#   3. checks settings.json and PRINTS the snippet to add if statusLine is missing or
#      points elsewhere. It never edits settings.json: that file is yours, and Claude
#      Code refuses to let an agent modify it anyway.
# Once: writes ~/.config/claude-statusline/config.sh from config.example.sh if absent.
# Then renders the demo fixture through the installed link so you see it works.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
homes=("$@"); [ ${#homes[@]} -eq 0 ] && homes=("$HOME/.claude")

for dep in bash jq python3 perl; do
  command -v "$dep" >/dev/null 2>&1 || echo "warning: $dep not found; some fields will be omitted"
done

cfg="$HOME/.config/claude-statusline/config.sh"
if [ ! -e "$cfg" ]; then
  mkdir -p "${cfg%/*}"
  cp "$HERE/config.example.sh" "$cfg"
  echo "wrote $cfg (edit seat labels there)"
fi

for h in "${homes[@]}"; do
  h="${h%/}"
  [ -d "$h" ] || { echo "skip $h: not a directory"; continue; }
  target="$h/statusline.sh"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$HERE/statusline.sh" ]; then
    echo "$target already links here"
  else
    [ -e "$target" ] && { mv "$target" "$target.bak-$STAMP"; echo "backed up $target -> $target.bak-$STAMP"; }
    ln -s "$HERE/statusline.sh" "$target"
    echo "linked $target -> $HERE/statusline.sh"
  fi
  settings="$h/settings.json"
  want="bash $target"
  have=$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)
  case "$have" in
    "$want"|"bash ~/${target#$HOME/}"|"$target"|"~/${target#$HOME/}") : ;;
    *)
      echo
      echo "ADD to $settings (statusLine.command is currently '${have:-unset}'):"
      cat <<JSON
  "statusLine": {
    "type": "command",
    "command": "bash ~/${target#$HOME/}",
    "refreshInterval": 30
  }
JSON
      ;;
  esac
  ri=$(jq -r '.statusLine.refreshInterval // ""' "$settings" 2>/dev/null)
  [ -z "$ri" ] && echo "tip: add \"refreshInterval\": 30 to statusLine in $settings so countdowns tick while idle"
done

echo
echo "demo render through the first home:"
CLAUDE_CONFIG_DIR="${homes[0]%/}" bash "${homes[0]%/}/statusline.sh" --demo

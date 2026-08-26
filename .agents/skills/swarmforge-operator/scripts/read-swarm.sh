#!/usr/bin/env bash
# read-swarm.sh — report the three-state (IDLE/BUSY/UNKNOWN) classification of
# every recorded role's tmux pane, always alongside its last non-empty output
# line so a human can check the machine's read against the raw evidence.
#
# Exit codes / STATUS line:
#   0 READ   2 USAGE   3 STOPPED   5 ERROR
# Contract details live in ../SKILL.md (verb: read swarm). Report verb (issue
# #15, CONTEXT.md "## Operator verbs"): never send-keys, never mutate tmux
# state — only list-sessions and capture-pane.
#
# Usage: read-swarm.sh --root <project-root> \
#   [--target user@host] [--key <path>] [--local]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' LOCAL=0

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || { sed -n '2,13p' "$0"; exit 2; }

SESSIONS=$(read_file .swarmforge/sessions.tsv) \
  || die STOPPED "$ROOT/.swarmforge/sessions.tsv missing — swarm not running" 3
SOCK=$(read_file .swarmforge/tmux-socket) \
  || die STOPPED "$ROOT/.swarmforge/tmux-socket missing — swarm not running" 3
SOCK=${SOCK%$'\n'}

# runtime gate: socket must actually answer, same as open-swarm.sh/wake-role.sh
tmux_remote list-sessions >/dev/null 2>&1 \
  || die STOPPED "socket $SOCK has no tmux server — swarm not running" 3

# ---------- classification ----------
# BUSY_RE/IDLE_RE/classify() live in lib-wake-talk.sh (issue #11): stop
# swarm's preflight needs the exact same three-state judgment this script
# uses, so the marker sets and the function moved to the file both scripts
# already source, instead of staying here as a copy that could drift. Issue
# #15's boundary — do not enumerate every backend's error state; unmatched
# text, including a blank pane, is UNKNOWN — is documented there now.

printf 'STATUS=READ\n'
while IFS=$'\t' read -r _index role session _display _agent; do
  [ -n "$role" ] || continue
  classify_pane "$session"
  if [ -n "$PANE_LINE" ]; then
    printf '%-16s %-7s | %s\n' "$role" "$PANE_STATE" "$PANE_LINE"
  else
    printf '%-16s %-7s | (blank pane)\n' "$role" "$PANE_STATE"
  fi
done <<< "$SESSIONS"

exit 0

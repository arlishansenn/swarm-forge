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

# ---------- classification: two small, high-confidence marker sets ----------
# Issue #15's boundary: do not try to enumerate every backend's error states.
# A line that doesn't confidently match one of these is UNKNOWN, including a
# blank pane — the old two-state rule's "empty prompt = idle" is exactly the
# silent misread this ticket exists to stop.
#
# BUSY: the "esc to interrupt" hint tied to codex's interruptible-work banner
# ("Working (44s • esc to interrupt)"), or the "<participle> for Ns" shape of
# claude's spinner line ("Baked for 13s", "Cogitated for 28s"). The spinner
# glyph itself is skipped as a marker — unicode chrome a font/terminal may not
# round-trip byte-for-byte; the text shape after it is the stable part.
# IDLE: a bare prompt character with nothing else on the line (claude's empty
# input line), or the literal placeholder text inviting input ("Ask Codex to
# do anything").
BUSY_RE='esc to interrupt|[A-Za-z]+(ed|ing) for [0-9]+s'
IDLE_RE='^(❯|>)[[:space:]]*$|Ask .* to do anything'

classify() { # $1 = last non-empty pane line ("" for a blank pane)
  if [ -z "$1" ]; then echo UNKNOWN
  elif printf '%s' "$1" | grep -qE "$BUSY_RE"; then echo BUSY
  elif printf '%s' "$1" | grep -qE "$IDLE_RE"; then echo IDLE
  else echo UNKNOWN
  fi
}

printf 'STATUS=READ\n'
while IFS=$'\t' read -r _index role session _display _agent; do
  [ -n "$role" ] || continue
  LINE=$(tmux_remote capture-pane -p -t "$session" -S -12 2>/dev/null \
    | grep -v '^$' | tail -1 || true)
  STATE=$(classify "$LINE")
  if [ -n "$LINE" ]; then
    printf '%-16s %-7s | %s\n' "$role" "$STATE" "$LINE"
  else
    printf '%-16s %-7s | (blank pane)\n' "$role" "$STATE"
  fi
done <<< "$SESSIONS"

exit 0

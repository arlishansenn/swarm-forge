#!/usr/bin/env bash
# wake-role.sh — send ready_for_next.sh to a role's session and verify the
# submit key actually landed, instead of trusting a stale backend guess.
#
# Exit codes / STATUS line:
#   0 WOKEN   2 USAGE   3 STOPPED   5 ERROR
# Contract details live in ../SKILL.md (verb: wake role). Backend is never a
# CLI argument — always resolved from sessions.tsv (issue #14).
#
# Usage: wake-role.sh --root <project-root> --role <name> \
#   [--target user@host] [--key <path>] [--local]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' ROLE='' LOCAL=0

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --role) ROLE=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) sed -n '2,11p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] && [ -n "$ROLE" ] || { sed -n '2,11p' "$0"; exit 2; }

SESSIONS=$(read_file .swarmforge/sessions.tsv) \
  || die STOPPED "$ROOT/.swarmforge/sessions.tsv missing — swarm not running" 3
SOCK=$(read_file .swarmforge/tmux-socket) \
  || die STOPPED "$ROOT/.swarmforge/tmux-socket missing — swarm not running" 3
SOCK=${SOCK%$'\n'}

# runtime gate: socket must actually answer, same as open-swarm.sh — stale
# files after a reboot look identical to a live swarm otherwise.
tmux_remote list-sessions >/dev/null 2>&1 \
  || die STOPPED "socket $SOCK has no tmux server — swarm not running; refusing to start it" 3

resolve_role "$ROLE" || die ERROR "role '$ROLE' not found in sessions.tsv" 5

send_and_verify "ready_for_next.sh"

printf 'STATUS=WOKEN\nROLE=%s\nSESSION=%s\n' "$ROLE" "$SESSION"

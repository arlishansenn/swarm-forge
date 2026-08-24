#!/usr/bin/env bash
# stop-swarm.sh — stop swarm's preflight (issue #11). Today's `stop swarm`
# was a bare `close-swarm` call: no grace period, no check of role state or
# uncommitted work. This script keeps the same clean-path stop but refuses to
# run it first, reporting what would be interrupted, unless every role reads
# IDLE and every worktree is clean.
#
# Exit codes / STATUS line:
#   0 STOPPED   2 USAGE   3 STOPPED   5 ERROR   6 UNSAFE
# Contract details live in ../SKILL.md (verb: stop swarm).
#
# Usage: stop-swarm.sh --root <project-root> \
#   [--target user@host] [--key <path>] [--local] [--force]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
# The official control checkout's close-swarm on the target host — same
# absolute path SKILL.md's `stop swarm` section has always hardcoded.
# Overridable so tests can point it at a stub instead of a real stop.
CLOSE_SWARM=${CLOSE_SWARM:-/Users/admin/project/swarm-forge/close-swarm}
ROOT='' LOCAL=0 FORCE=0

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --force) FORCE=1; shift ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || { sed -n '2,13p' "$0"; exit 2; }

# do_stop performs exactly what close-swarm has always done — same command
# SKILL.md documents today, local or remote. `|| true` because this script's
# own exit code owes nothing to close-swarm's (it never has: today's verb is
# a bare, unchecked ssh call), only to whether the preflight let it run.
do_stop() {
  if [ "$LOCAL" = 1 ]; then "$CLOSE_SWARM" "$ROOT" || true
  else ssh -i "$KEY" "$TARGET" "$CLOSE_SWARM '$ROOT'" || true; fi
}

# --force skips the preflight gate entirely — no state files read, no tmux
# reached for anything but the stop itself — so it reproduces today's
# behavior exactly, not a "preflight that always says yes".
if [ "$FORCE" = 1 ]; then
  printf 'STATUS=STOPPED\n'
  do_stop
  exit 0
fi

SESSIONS=$(read_file .swarmforge/sessions.tsv) \
  || die STOPPED "$ROOT/.swarmforge/sessions.tsv missing — swarm not running" 3
ROLES=$(read_file .swarmforge/roles.tsv) \
  || die STOPPED "$ROOT/.swarmforge/roles.tsv missing — swarm not running" 3
SOCK=$(read_file .swarmforge/tmux-socket) \
  || die STOPPED "$ROOT/.swarmforge/tmux-socket missing — swarm not running" 3
SOCK=${SOCK%$'\n'}

# runtime gate: socket must actually answer, same as read-swarm.sh — nothing
# to preflight against a swarm that isn't running.
tmux_remote list-sessions >/dev/null 2>&1 \
  || die STOPPED "socket $SOCK has no tmux server — swarm not running" 3

# ---------- BUSY/UNKNOWN roles: identical read to `read swarm` ----------
BUSY_LIST='' UNKNOWN_LIST=''
while IFS=$'\t' read -r _index role session _display _agent; do
  [ -n "$role" ] || continue
  LINE=$(tmux_remote capture-pane -p -t "$session" -S -12 2>/dev/null \
    | grep -v '^$' | tail -1 || true)
  STATE=$(classify "$LINE")
  case $STATE in
    BUSY) BUSY_LIST="$BUSY_LIST $role" ;;
    UNKNOWN) UNKNOWN_LIST="$UNKNOWN_LIST $role" ;;
  esac
done <<< "$SESSIONS"

# ---------- DIRTY worktrees: git status per roles.tsv path, deduped ----------
# master/none rows both resolve to the project root itself (swarmforge.bb's
# special-worktree? rule), so more than one role can share a path — check it
# once, not once per role sharing it.
DIRTY_LINES='' SEEN=''
while IFS=$'\t' read -r _role _wtname wtpath _session _display _agent _recv; do
  [ -n "$wtpath" ] || continue
  case " $SEEN " in *" $wtpath "*) continue ;; esac
  SEEN="$SEEN $wtpath"
  if OUT=$(git_status "$wtpath" 2>/dev/null); then
    if [ -n "$OUT" ]; then
      N=$(printf '%s\n' "$OUT" | grep -c .)
      DIRTY_LINES="${DIRTY_LINES}DIRTY=$wtpath ($N files)"$'\n'
    fi
  else
    # can't verify cleanliness at all (unreadable path, not a git repo, ssh
    # hiccup) — preflight is conservative: unknown counts as unsafe, same
    # stance as an UNKNOWN role, never silently treated as clean.
    DIRTY_LINES="${DIRTY_LINES}DIRTY=$wtpath (status unavailable)"$'\n'
  fi
done <<< "$ROLES"

if [ -n "$BUSY_LIST$UNKNOWN_LIST$DIRTY_LINES" ]; then
  printf 'STATUS=UNSAFE\nPREFLIGHT\n'
  for r in $BUSY_LIST; do printf 'BUSY=%s\n' "$r"; done
  for r in $UNKNOWN_LIST; do printf 'UNKNOWN=%s\n' "$r"; done
  printf '%s' "$DIRTY_LINES"
  exit 6
fi

printf 'STATUS=STOPPED\n'
do_stop
exit 0

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
#   [--target user@host] [--key <path>] [--local] [--force] \
#   [--close-swarm <path-on-target>]
#
# THE STOP IS CHECKED (issue #82). close-swarm runs ON THE TARGET, but its
# path defaulted to the operator's own machine, so on any target whose home
# is not /Users/admin the command simply did not exist — and a `|| true`
# swallowed that, printing STATUS=STOPPED and exiting 0 with every tmux
# session still alive. Reproduced live against a Linux target: exit 0,
# STATUS=STOPPED, six sessions untouched. A stop that did not happen is now
# 5 ERROR carrying close-swarm's own stderr, and STATUS=STOPPED is printed
# only after the stop returns 0. --close-swarm names the path for a target
# that is not the operator machine; CLOSE_SWARM in the environment still
# works and the flag wins over it.
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
    --close-swarm) CLOSE_SWARM=${2:-}; shift 2 ;;
    *) sed -n '2,25p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || { sed -n '2,25p' "$0"; exit 2; }
[ -n "$CLOSE_SWARM" ] || { sed -n '2,25p' "$0"; exit 2; }

# remote_sh — runs a script-built snippet on the target, local or remote.
# Same rule as everywhere else in this skill: the snippet is assembled only
# from %q-quoted values, never from hand-interpolated free text.
remote_sh() { # $1 = snippet
  if [ "$LOCAL" = 1 ]; then bash -c "$1"
  else ssh -n -i "$KEY" "$TARGET" "$1"; fi
}

# do_stop runs close-swarm on the target and REPORTS WHETHER IT WORKED.
# stdout is captured so the STATUS line still comes first; stderr is captured
# so a failure can carry the reason instead of vanishing (issue #82).
STOP_OUT='' STOP_ERR=''
do_stop() {
  local errfile rc=0
  errfile=$(mktemp "${TMPDIR:-/tmp}/sf-stop-swarm.XXXXXX")
  STOP_OUT=$(remote_sh "$(printf '%q' "$CLOSE_SWARM") $(printf '%q' "$ROOT")" 2>"$errfile") || rc=$?
  STOP_ERR=$(cat "$errfile"); rm -f "$errfile"
  return "$rc"
}

# close-swarm stops the tmux sessions and nothing else — it has no idea the
# dashboard exists. A pack_web left running means a later start on a fixed
# port gives one $ROOT two live pack_web processes, which is exactly the
# squatting case `dashboard`'s port-ownership check has to refuse. Stopped
# here rather than in close-swarm so that script's semantics stay untouched.
stop_pack_web() {
  local pidfile out
  pidfile=$(printf '%q' "$ROOT/.swarmforge/pack_web.pid")
  out=$(remote_sh "p=$pidfile; if [ -s \"\$p\" ]; then kill \"\$(cat \"\$p\")\" 2>/dev/null; rm -f \"\$p\"; echo stopped; else echo absent; fi" 2>/dev/null) || out=unknown
  printf 'PACK_WEB=%s\n' "${out:-unknown}"
}

# The one place STATUS=STOPPED may be printed. Reaching it means close-swarm
# returned 0; anything else is 5 ERROR naming what to fix.
stop_and_report() {
  if ! do_stop; then
    die ERROR "$(printf 'close-swarm failed on %s and the swarm was NOT stopped.\n%s\ntried: %s\nOn a target that is not the operator machine, close-swarm lives somewhere else — pass --close-swarm <path-on-target>.' \
      "$([ "$LOCAL" = 1 ] && echo 'this machine' || echo "$TARGET")" \
      "${STOP_ERR:-(no stderr)}" "$CLOSE_SWARM")" 5
  fi
  printf 'STATUS=STOPPED\n'
  [ -z "$STOP_OUT" ] || printf '%s\n' "$STOP_OUT"
  stop_pack_web
}

# --force skips the preflight gate entirely — no state files read, no tmux
# reached for anything but the stop itself — so it reproduces today's
# behavior exactly, not a "preflight that always says yes".
if [ "$FORCE" = 1 ]; then
  stop_and_report
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
  classify_pane "$session"
  case $PANE_STATE in
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

stop_and_report
exit 0

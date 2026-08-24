#!/usr/bin/env bash
# start-swarm.sh — start swarm's launch verb (issue #26), the deliberate
# counterpart to `open swarm` (issue #10): open now correctly refuses to
# auto-start a stopped swarm, but until this script existed there was no
# verb for "a human decided to start it" either — only a manual ssh +
# `nohup ./swarm &`, which is exactly how the #10 incident's terminal
# backend got auto-detected with no real terminal window behind it and the
# window watchdog killed the whole swarm within seconds. That failure mode
# has reproduced twice under manual operation; this script exists so it
# cannot reproduce a third time via this verb.
#
# Exit codes / STATUS line:
#   0 STARTED   2 USAGE   4 DRIFT   5 ERROR   6 UNSAFE
# Contract details live in ../SKILL.md (verb: start swarm).
#
# Usage: start-swarm.sh --root <project-root> --terminal <value> \
#   [--target user@host] [--key <path>] [--local] [--force]
#
# issue #29: before launch, this script also acquires a project-scoped lock
# (excluding a concurrent `update SwarmForge scripts`) and checks the
# managed project's installed swarmforge/scripts against its own identity
# manifest. --force overrides BOTH of those (steals a held lock, skips the
# drift check) — it never touches the already-running check above, which
# has no override.
#
# --terminal is REQUIRED, not an optional env passthrough: unlike --force on
# stop-swarm.sh (which waives a state check a human can knowingly override),
# --terminal is a required choice like --root itself — the #10/#26 incident
# is exactly what happens when a human is allowed to skip choosing it.
# Accepted values match SWARMFORGE_TERMINAL's canonical backends, plus
# `auto`: "I know automatic detection exists and I am explicitly opting
# into it" — auto does NOT get forwarded to SWARMFORGE_TERMINAL literally
# (swarmforge.bb's normalize-terminal-backend does not understand the
# literal string "auto"); it means this script does not export
# SWARMFORGE_TERMINAL at all, letting detect-terminal-backend's own
# osascript/wt.exe fallback chain run exactly as it does today.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' TERMINAL='' LOCAL=0 FORCE=0

# Canonical --terminal value set: the basenames of
# swarmforge/scripts/terminal-adapters/*.sh (today: ghostty, iterm2, none,
# terminal-app, windows-terminal — five files; the issue text that spawned
# this script named only four, missing ghostty), plus this script's own
# `auto` sentinel. Hardcoded here rather than derived by listing that
# directory at run time: the directory that matters is the MANAGED
# PROJECT's own copy (remote or local target), so deriving it would cost a
# real round trip (ssh ls, or a local stat) on every invocation just to
# rebuild a set that changes only when someone adds a new adapter file —
# rare enough that updating this list by hand is the cheaper default.
# Trade-off, named rather than picked silently: a new adapter file added
# upstream needs this list edited too, or --terminal rejects a legitimate
# value until then; listing the directory would stay correct automatically
# but adds that round trip to every single invocation.
TERMINAL_VALUES='ghostty iterm2 none terminal-app windows-terminal auto'

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --terminal) TERMINAL=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --force) FORCE=1; shift ;;
    *) sed -n '2,36p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || { sed -n '2,36p' "$0"; exit 2; }
[ -n "$TERMINAL" ] || { sed -n '2,36p' "$0"; exit 2; }
case " $TERMINAL_VALUES " in
  *" $TERMINAL "*) ;;
  *) sed -n '2,36p' "$0"; exit 2 ;;
esac

# Overridable so tests can point the launch at a stub instead of a real
# `./swarm`/swarmforge.bb pipeline — same trick as stop-swarm.sh's
# CLOSE_SWARM. Depends on ROOT, so it's resolved after arg parsing.
SWARM_LAUNCHER=${SWARM_LAUNCHER:-$ROOT/swarm}
LOG=.swarmforge/start-swarm.log

# ---------- preflight: already running? (inverse of stop-swarm's liveness
# gate) A swarm that already answers on its socket is real state that a
# second launch would break — a second daemon, a second tmux session
# colliding with the first — so this is UNSAFE (6), the same class
# stop-swarm's BUSY/DIRTY gate uses, not DRIFT (4): recorded state and real
# state agree here, there's just nothing left to do. A stale tmux-socket
# file with no live server behind it (the watchdog-kill aftermath open-swarm
# already knows how to name) is NOT "already running" — that's exactly the
# stopped state this verb exists to start back up. ----------
if SOCK=$(read_file .swarmforge/tmux-socket 2>/dev/null); then
  SOCK=${SOCK%$'\n'}
  if tmux_remote list-sessions >/dev/null 2>&1; then
    die UNSAFE "socket $SOCK already has a live tmux server — swarm already running; refusing to start a second one" 6
  fi
fi

# ---------- lock: exclude a concurrent update (issue #29) ----------
if ! acquire_lock start; then
  if [ "$FORCE" != 1 ]; then
    die UNSAFE "project lock held by '$LOCK_HOLDER' — wait, or re-run with --force to break a lock left by a dead process" 6
  fi
  # --force: the operator's explicit statement that the reported holder is
  # not actually active — steal the lock (remove, then re-acquire fresh)
  # rather than refuse. This is the only way a held lock is ever cleared
  # without its original holder exiting cleanly.
  release_lock
  acquire_lock start || die ERROR \
    "failed to acquire project lock at $ROOT/.swarmforge/update-lock even after --force cleared it" 5
fi
# Covers every exit path from here on (STARTED/0, ERROR/5, any die) — the
# lock stays held through the rest of this script (drift check, launch,
# readiness poll) and is released exactly once, here, never by a manual
# release_lock call elsewhere in this file.
trap release_lock EXIT

# ---------- drift: installed scripts vs their own manifest (issue #29) ----------
if [ "$FORCE" != 1 ]; then
  INSTALLED_DIGEST=$(remote_scripts_digest "$ROOT/swarmforge/scripts")
  if ! MANIFEST_DIGEST=$(read_manifest) || [ "$MANIFEST_DIGEST" != "$INSTALLED_DIGEST" ]; then
    die DRIFT "installed SwarmForge scripts do not match $ROOT/.swarmforge/scripts-manifest (or it's missing) — run update SwarmForge scripts first, or re-run with --force to launch anyway" 4
  fi
fi

# ---------- launch: detached, local or remote (issue #26 core fix) ----------
# `auto` never reaches SWARMFORGE_TERMINAL as a literal value (see header);
# every other accepted value is already swarmforge.bb's own canonical form,
# so it passes through unchanged.
LAUNCH_ARGV=("$SWARM_LAUNCHER")
[ "$TERMINAL" = auto ] || LAUNCH_ARGV=(env "SWARMFORGE_TERMINAL=$TERMINAL" "$SWARM_LAUNCHER")

run_detached "$ROOT/$LOG" "${LAUNCH_ARGV[@]}"

# ---------- readiness: poll runtime files, never trust "the command ran" —
# same tmux-socket-then-list-sessions pattern as open-swarm's/stop-swarm's
# runtime gate, not log-text matching (wording drifts, files don't).
# Budget: a fresh launch does real work before the socket exists at all —
# writing role prompts, starting the handoff daemon, then creating one tmux
# session per role with SWARMFORGE_AGENT_START_DELAY_MS (default 1500ms)
# between each — a six-pack alone burns ~7.5s on start delays before its
# last session exists, on top of the file/daemon setup before that. 60
# tries at 1s is generous headroom above open-dashboard's 20-try/0.5s
# tunnel-handshake budget, which waits on a single TCP handshake, not a
# multi-process launch. Overridable so tests don't sit through it.
READY_TRIES=${SF_START_READY_TRIES:-60}
READY_INTERVAL=${SF_START_READY_INTERVAL:-1}
READY=0
for _ in $(seq 1 "$READY_TRIES"); do
  if SOCK=$(read_file .swarmforge/tmux-socket 2>/dev/null); then
    SOCK=${SOCK%$'\n'}
    if tmux_remote list-sessions >/dev/null 2>&1; then READY=1; break; fi
  fi
  sleep "$READY_INTERVAL"
done

# Launch failure (./swarm exited non-zero) and a launch that simply never
# becomes ready both surface the same way here, by design: the launch is
# intentionally detached (issue #26's whole point — see run_detached), so
# this script never waits on or inspects the launcher's own exit code; the
# runtime files are the only source of truth it trusts, same as every other
# verb in this skill.
[ "$READY" = 1 ] || die ERROR \
  "$ROOT/.swarmforge/tmux-socket never came up (or its tmux server never answered) within ${READY_TRIES}x${READY_INTERVAL}s — check $ROOT/$LOG" 5

printf 'STATUS=STARTED\nROOT=%s\nSOCK=%s\nTERMINAL=%s\n' "$ROOT" "$SOCK" "$TERMINAL"
exit 0

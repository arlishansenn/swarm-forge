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
#   [--target user@host] [--key <path>] [--local] [--force] \
#   [--dashboard-port <N>]
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
#
# --dashboard-port <N> (issue #78) is forwarded as SWARMFORGE_DASHBOARD_PORT,
# which pack_web binds instead of asking the kernel for a random one. A random
# port cannot be published on a tailnet, because there is no stable URL to
# publish; a fixed one gives `dashboard --tailnet` an address that survives a
# restart. Omitted, nothing is exported and pack_web behaves exactly as before.
# Only the SHAPE is validated (digits): which ports a host hands out is that
# host's own convention, and a range check here would be noise in anyone
# else's fork.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' TERMINAL='' LOCAL=0 FORCE=0 DASHBOARD_PORT=''

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

# Verb contract: a scripted verb prints STATUS=<WORD> as its first line —
# same pattern onboard-project.sh's usage_error() uses (issue #29 review
# round 4 finding).
usage() { printf 'STATUS=USAGE\n'; sed -n '2,46p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --terminal) TERMINAL=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --force) FORCE=1; shift ;;
    --dashboard-port) DASHBOARD_PORT=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$ROOT" ] || usage
[ -n "$TERMINAL" ] || usage
case " $TERMINAL_VALUES " in
  *" $TERMINAL "*) ;;
  *) usage ;;
esac
if [ -n "$DASHBOARD_PORT" ]; then
  case $DASHBOARD_PORT in *[!0-9]*) usage ;; esac
fi

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
# `|| LOCK_RC=$?` rather than a bare call: acquire_lock reports contention (1)
# and a filesystem failure (2) through its exit status, and under `set -e` a
# bare non-zero call would abort the script before the status could be read.
LOCK_RC=0; acquire_lock start || LOCK_RC=$?
if [ "$LOCK_RC" = 2 ]; then
  die ERROR "cannot create $ROOT/.swarmforge to take the project lock — check the path and its permissions" 5
fi
if [ "$LOCK_RC" != 0 ]; then
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

# ---------- snapshot state: fresh / managed / incomplete (issues #29, #35) ----------
# Three states, told apart by which of the two identity artifacts exist. They
# are checked BEFORE any launch, and — for the managed case — before the
# launcher's own sync-worktree-scripts! mirroring can propagate the top-level
# tree into role worktrees. Issue #29's per-role fidelity check only proves a
# role's copy matches the top-level source; it cannot catch a top-level tree
# that is already corrupt, because the mirror trivially matches whatever it
# just copied from. Catching it here is the only place that helps.
#
# 1. FRESH    — snapshot and manifest both absent. This is a project that was
#               onboarded and left stopped: the Pack's own launcher owns
#               first-run bootstrap, so hand off to it instead of refusing.
#               Fresh does NOT mean "ignore a mismatch"; it is the single
#               exact state where both artifacts are absent.
# 2. MANAGED  — both present. Verify the digest before launching.
# 3. INCOMPLETE — exactly one present. A torn install or an interrupted
#               bootstrap. Never guess which side is right: DRIFT/4 and make
#               the operator run `update SwarmForge scripts` or recover.
# 4. PROJECT_OWNED — the managed project version-controls swarmforge/scripts
#               itself (issue #88). All three states above assume the operator
#               installed that tree, so the manifest describes it. When the
#               project owns it, there is nothing for the manifest to be right
#               about: a project that rolls its own tree back to its committed
#               version would DRIFT on every launch, and `--force` would become
#               the routine way to start it — the same always-on gate issue #58
#               had to fix, and the same one issue #87 is about.
#
#               Derived from git rather than declared in a file, on purpose.
#               A declaration is a fourth artifact that can be stale, forgotten
#               on a new clone, or disagree with reality; `git ls-files` cannot.
#               It is also the exact predicate `update SwarmForge scripts` uses
#               to refuse (8 OWNED), so the two verbs cannot form different
#               opinions about who owns the tree. The cost, named rather than
#               hidden: after `update --overwrite-tracked` the tree is both
#               tracked AND operator-installed, and this check will call it
#               project-owned and skip the digest comparison. That is the
#               deliberate trade — an artifact that can lie is worse than a
#               predicate that is occasionally too generous.
SNAPSHOT_PRESENT=0
run_remote_test() { # $1 = test expression body
  if [ "$LOCAL" = 1 ]; then bash -c "$1"; else ssh -n -i "$KEY" "$TARGET" "$1"; fi
}
run_remote_test "test -d $(printf '%q' "$ROOT/swarmforge/scripts")" 2>/dev/null && SNAPSHOT_PRESENT=1
MANIFEST_PRESENT=0
run_remote_test "test -f $(printf '%q' "$ROOT/.swarmforge/scripts-manifest")" 2>/dev/null && MANIFEST_PRESENT=1

PROJECT_OWNED=0
[ -z "$(git_tracked "$ROOT" swarmforge/scripts)" ] || PROJECT_OWNED=1

FRESH_BOOTSTRAP=0
if [ "$FORCE" != 1 ] && [ "$PROJECT_OWNED" != 1 ]; then
  if [ "$SNAPSHOT_PRESENT" = 0 ] && [ "$MANIFEST_PRESENT" = 0 ]; then
    FRESH_BOOTSTRAP=1
  elif [ "$SNAPSHOT_PRESENT" = 1 ] && [ "$MANIFEST_PRESENT" = 1 ]; then
    INSTALLED_DIGEST=$(remote_scripts_digest "$ROOT/swarmforge/scripts")
    if ! MANIFEST_DIGEST=$(read_manifest) || [ "$MANIFEST_DIGEST" != "$INSTALLED_DIGEST" ]; then
      die DRIFT "installed SwarmForge scripts do not match $ROOT/.swarmforge/scripts-manifest — run update SwarmForge scripts first, or re-run with --force to launch anyway" 4
    fi
  elif [ "$SNAPSHOT_PRESENT" = 1 ]; then
    die DRIFT "$ROOT/swarmforge/scripts exists but $ROOT/.swarmforge/scripts-manifest does not — an interrupted install; run update SwarmForge scripts, or re-run with --force to launch anyway" 4
  else
    die DRIFT "$ROOT/.swarmforge/scripts-manifest exists but $ROOT/swarmforge/scripts does not — an interrupted install; run update SwarmForge scripts, or re-run with --force to launch anyway" 4
  fi
fi

# ---------- launch: detached, local or remote (issue #26 core fix) ----------
# `auto` never reaches SWARMFORGE_TERMINAL as a literal value (see header);
# every other accepted value is already swarmforge.bb's own canonical form,
# so it passes through unchanged.
# Accumulated, not assigned (issue #78). The previous shape was a two-way
# choice — plain launcher, or `env SWARMFORGE_TERMINAL=... launcher` — and a
# second variable written the same way would have overwritten the first
# instead of joining it. There is exactly one `env` prefix, built once, from
# however many variables are actually set.
LAUNCH_ENV=()
[ "$TERMINAL" = auto ] || LAUNCH_ENV+=("SWARMFORGE_TERMINAL=$TERMINAL")
[ -z "$DASHBOARD_PORT" ] || LAUNCH_ENV+=("SWARMFORGE_DASHBOARD_PORT=$DASHBOARD_PORT")
LAUNCH_ARGV=("$SWARM_LAUNCHER")
[ ${#LAUNCH_ENV[@]} -eq 0 ] || LAUNCH_ARGV=(env "${LAUNCH_ENV[@]}" "$SWARM_LAUNCHER")

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
if [ "$READY" != 1 ]; then
  # On a fresh bootstrap the lock stays HELD past this timeout (issue #35).
  # The readiness budget is sized for launching an already-installed
  # snapshot; a first-run bootstrap also downloads one, which is an
  # unbounded network operation. Timing out here does not mean the launcher
  # stopped — it may still be writing the snapshot. Releasing the lock would
  # let a retried `start swarm`, or a concurrent `update SwarmForge
  # scripts`, become a second writer against that in-progress install. So
  # the trap is disarmed and clearing the lock becomes an explicit operator
  # --force, the same "operator-judged, never inferred" convention issue #29
  # set for lock contention generally.
  if [ "$FRESH_BOOTSTRAP" = 1 ]; then
    trap - EXIT
    die ERROR "first-run bootstrap did not become ready within ${READY_TRIES}x${READY_INTERVAL}s. The snapshot download may still be running, so the project lock is left HELD deliberately — check $ROOT/$LOG, then re-run with --force once you have confirmed nothing is still writing" 5
  fi
  die ERROR \
    "$ROOT/.swarmforge/tmux-socket never came up (or its tmux server never answered) within ${READY_TRIES}x${READY_INTERVAL}s — check $ROOT/$LOG" 5
fi

# SNAPSHOT says which of the two worlds this launch was in, because the
# answer changes what a DRIFT would have meant — and a project-owned tree is
# never drift-checked at all.
printf 'STATUS=STARTED\nROOT=%s\nSOCK=%s\nTERMINAL=%s\nSNAPSHOT=%s\n' \
  "$ROOT" "$SOCK" "$TERMINAL" \
  "$([ "$PROJECT_OWNED" = 1 ] && echo project-owned || echo operator-managed)"
exit 0

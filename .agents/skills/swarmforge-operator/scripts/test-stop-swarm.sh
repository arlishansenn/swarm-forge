#!/usr/bin/env bash
# test-stop-swarm.sh — end-to-end checks for stop-swarm.sh against a stubbed
# tmux/git/close-swarm. Run: bash scripts/test-stop-swarm.sh. Exits non-zero
# on any failure. Tests run --local (same convention as test-wake-talk.sh and
# test-read-swarm.sh), so ssh is never invoked and never stubbed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
STOP=$HERE/stop-swarm.sh
WORK=$(mktemp -d /tmp/sf-stop-swarm-test.XXXXXX)
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub tmux (same shape as test-read-swarm.sh: capture-pane keys
# off -t <session> and returns that session's own fixture file) ----------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
log() { printf 'tmux %s\n' "$*" >> "$STUB/calls.log"; }
log "$@"
[ -f "$STUB/live" ] || exit 1
shift 2  # drop -S <sock>
CMD=$1; shift
case $CMD in
  list-sessions) exit 0 ;;
  capture-pane)
    sess=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-t" ] && sess=$2
      shift
    done
    cat "$STUB/panes/$sess.txt" 2>/dev/null || true
    exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/tmux"

# ---------- stub git: `git -C <path> status --porcelain`, fixture keyed by
# the worktree path itself (mirrored as a directory under $STUB/git) ----------
cat > "$WORK/bin/git" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
log() { printf 'git %s\n' "$*" >> "$STUB/calls.log"; }
log "$@"
path=""
while [ $# -gt 0 ]; do
  case $1 in
    -C) path=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat "$STUB/git$path/status.txt" 2>/dev/null || true
exit 0
EOF
chmod +x "$WORK/bin/git"

# ---------- stub close-swarm: logs invocation, never runs the real thing ----
cat > "$WORK/bin/close-swarm" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'close-swarm %s\n' "$*" >> "$STUB/calls.log"
exit 0
EOF
chmod +x "$WORK/bin/close-swarm"

export STUB=$WORK/stub
reset_stub() {
  rm -rf "$STUB"; mkdir -p "$STUB/panes" "$STUB/git"; : > "$STUB/calls.log"
}

set_pane() { printf '%s\n' "$2" > "$STUB/panes/$1.txt"; }  # set_pane <session> <last-line>
set_status() {  # set_status <worktree-path> <porcelain-lines...>
  local path=$1; shift
  mkdir -p "$STUB/git$path"
  printf '%s\n' "$@" > "$STUB/git$path/status.txt"
}
clean_status() { mkdir -p "$STUB/git$1"; : > "$STUB/git$1/status.txt"; }  # clean_status <path>

# two roles, two worktrees — every scenario proves the preflight walks both
# sessions.tsv and roles.tsv independently, not just a single lucky row
ROOT=$WORK/fixtures/twopack
WT_CODER=$ROOT/.worktrees/coder
WT_CLEANER=$ROOT/.worktrees/cleaner
mkdir -p "$ROOT/.swarmforge"
printf '1\tcoder\tswarmforge-coder\tCoder\tcodex\n2\tcleaner\tswarmforge-cleaner\tCleaner\tclaude\n' \
  > "$ROOT/.swarmforge/sessions.tsv"
printf 'coder\tcoder\t%s\tswarmforge-coder\tCoder\tcodex\ttask\n' "$WT_CODER" \
  > "$ROOT/.swarmforge/roles.tsv"
printf 'cleaner\tcleaner\t%s\tswarmforge-cleaner\tCleaner\tclaude\ttask\n' "$WT_CLEANER" \
  >> "$ROOT/.swarmforge/roles.tsv"
printf '/tmp/sf-stop-swarm.sock\n' > "$ROOT/.swarmforge/tmux-socket"

run() {  # run [extra args...]
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB CLOSE_SWARM="$WORK/bin/close-swarm" \
    bash "$STOP" --local --root "$ROOT" "$@" 2>&1)
  RC=$?
}
close_swarm_called() { grep -q '^close-swarm ' "$STUB/calls.log"; }
kill_session_called() { grep -q 'kill-session' "$STUB/calls.log"; }

# an all-clean baseline every scenario starts from, then dirties one thing
all_clean() {
  reset_stub; touch "$STUB/live"
  set_pane swarmforge-coder   '❯'
  set_pane swarmforge-cleaner '❯'
  clean_status "$WT_CODER"
  clean_status "$WT_CLEANER"
}

echo "== RED/GREEN suite for stop-swarm.sh =="

if [ ! -f "$STOP" ]; then
  echo "script missing — RED confirmed, all cases fail"; exit 1
fi

# 1. BUSY role blocks: exit 6, UNSAFE, PREFLIGHT report names the role, and
#    neither kill-session nor close-swarm ever runs
all_clean
set_pane swarmforge-coder 'Working (44s • esc to interrupt)'
run
check "busy exit" 6 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=UNSAFE$' \
  && ok "busy status is UNSAFE" || bad "busy status is UNSAFE" "$OUT"
printf '%s\n' "$OUT" | grep -q '^PREFLIGHT$' \
  && ok "busy output has PREFLIGHT header" || bad "busy output has PREFLIGHT header" "$OUT"
printf '%s\n' "$OUT" | grep -q '^BUSY=coder$' \
  && ok "busy line names coder" || bad "busy line names coder" "$OUT"
! close_swarm_called && ok "busy: close-swarm never called" || bad "busy: close-swarm never called" "$(cat "$STUB/calls.log")"
! kill_session_called && ok "busy: kill-session never called" || bad "busy: kill-session never called" "$(cat "$STUB/calls.log")"

# 2. UNKNOWN role blocks the same way (blank pane — the three-state read's
#    conservative default, not IDLE)
all_clean
set_pane swarmforge-cleaner ''
run
check "unknown exit" 6 "$RC"
printf '%s\n' "$OUT" | grep -q '^UNKNOWN=cleaner$' \
  && ok "unknown line names cleaner" || bad "unknown line names cleaner" "$OUT"
! close_swarm_called && ok "unknown: close-swarm never called" || bad "unknown: close-swarm never called" "$(cat "$STUB/calls.log")"
! kill_session_called && ok "unknown: kill-session never called" || bad "unknown: kill-session never called" "$(cat "$STUB/calls.log")"

# 3. DIRTY worktree blocks the same way, with a file count
all_clean
set_status "$WT_CLEANER" ' M a.txt' ' M b.txt' '?? c.txt'
run
check "dirty exit" 6 "$RC"
printf '%s\n' "$OUT" | grep -q "^DIRTY=$WT_CLEANER (3 files)\$" \
  && ok "dirty line names worktree and file count" || bad "dirty line names worktree and file count" "$OUT"
! close_swarm_called && ok "dirty: close-swarm never called" || bad "dirty: close-swarm never called" "$(cat "$STUB/calls.log")"
! kill_session_called && ok "dirty: kill-session never called" || bad "dirty: kill-session never called" "$(cat "$STUB/calls.log")"

# 4. --force bypasses the gate entirely, even with busy+dirty present, and
#    actually stops (close-swarm called, no PREFLIGHT report at all)
all_clean
set_pane swarmforge-coder 'Working (44s • esc to interrupt)'
set_status "$WT_CLEANER" ' M a.txt'
run --force
check "force exit" 0 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=STOPPED$' \
  && ok "force status is STOPPED" || bad "force status is STOPPED" "$OUT"
! printf '%s\n' "$OUT" | grep -q '^PREFLIGHT$' \
  && ok "force skips PREFLIGHT report" || bad "force skips PREFLIGHT report" "$OUT"
close_swarm_called && ok "force: close-swarm called" || bad "force: close-swarm called" "$(cat "$STUB/calls.log")"

# 5. all-clean stops normally: exit 0, STATUS=STOPPED, close-swarm called
all_clean
run
check "clean exit" 0 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=STOPPED$' \
  && ok "clean status is STOPPED" || bad "clean status is STOPPED" "$OUT"
close_swarm_called && ok "clean: close-swarm called" || bad "clean: close-swarm called" "$(cat "$STUB/calls.log")"

# 6. dead socket (swarm not running) → exit 3, never treated as unsafe or as
#    a clean stop; close-swarm never called
reset_stub  # no "live" flag
run
check "no-server exit" 3 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=STOPPED$' \
  && ok "no-server status is STOPPED" || bad "no-server status is STOPPED" "$OUT"
! close_swarm_called && ok "no-server: close-swarm never called" || bad "no-server: close-swarm never called" "$(cat "$STUB/calls.log")"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

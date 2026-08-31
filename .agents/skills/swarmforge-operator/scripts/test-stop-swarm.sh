#!/usr/bin/env bash
# test-stop-swarm.sh — end-to-end checks for stop-swarm.sh against a stubbed
# tmux/git/close-swarm. Run: bash scripts/test-stop-swarm.sh. Exits non-zero
# on any failure. Local-mode cases run --local (same convention as
# test-wake-talk.sh and test-read-swarm.sh), so ssh is never invoked there.
# Remote-mode cases below (issue #36) add a stub ssh that actually simulates
# real ssh's own stdin-forwarding behavior — see test-read-swarm.sh's stub
# comment for why a naive argv-logging stub would not catch this bug.
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

# ---------- stub ssh (issue #36) — see test-read-swarm.sh for why this must
# actually drain its own stdin when invoked without -n, not just log argv
# and run the command ----------
cat > "$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'ssh %s\n' "$*" >> "$STUB/calls.log"
has_n=0
for a in "$@"; do [ "$a" = "-n" ] && has_n=1; done
[ "$has_n" = 1 ] || cat >/dev/null
cmd=${*: -1}
bash -c "$cmd"
EOF
chmod +x "$WORK/bin/ssh"

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
run_cs() {  # run_cs <close-swarm-path> [extra args...]
  local cs=$1; shift
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB CLOSE_SWARM="$cs" \
    bash "$STOP" --local --root "$ROOT" "$@" 2>&1)
  RC=$?
}
# a close-swarm that fails the way a real one does when it cannot do its job
cat > "$WORK/bin/close-swarm-fails" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'close-swarm-fails %s\n' "$*" >> "$STUB/calls.log"
echo "no tmux server on that socket" >&2
exit 1
EOF
chmod +x "$WORK/bin/close-swarm-fails"

close_swarm_called() { grep -q '^close-swarm ' "$STUB/calls.log"; }
kill_session_called() { grep -q 'kill-session' "$STUB/calls.log"; }

# ---------- remote-mode fixture: 3 roles, 3 distinct worktrees (issue #36 —
# a second/later role or worktree silently skipped by the SESSIONS or ROLES
# loop is a real safety-gate bypass, not just a report gap: stop swarm must
# never let close-swarm run when a later row was actually BUSY/UNKNOWN/DIRTY)
ROOT3=$WORK/fixtures/threepack
WT3_CODER=$ROOT3/.worktrees/coder
WT3_CLEANER=$ROOT3/.worktrees/cleaner
WT3_REVIEWER=$ROOT3/.worktrees/reviewer
mkdir -p "$ROOT3/.swarmforge"
printf '1\tcoder\tswarmforge-coder\tCoder\tcodex\n2\tcleaner\tswarmforge-cleaner\tCleaner\tclaude\n3\treviewer\tswarmforge-reviewer\tReviewer\tclaude\n' \
  > "$ROOT3/.swarmforge/sessions.tsv"
printf 'coder\tcoder\t%s\tswarmforge-coder\tCoder\tcodex\ttask\n' "$WT3_CODER" \
  > "$ROOT3/.swarmforge/roles.tsv"
printf 'cleaner\tcleaner\t%s\tswarmforge-cleaner\tCleaner\tclaude\ttask\n' "$WT3_CLEANER" \
  >> "$ROOT3/.swarmforge/roles.tsv"
printf 'reviewer\treviewer\t%s\tswarmforge-reviewer\tReviewer\tclaude\ttask\n' "$WT3_REVIEWER" \
  >> "$ROOT3/.swarmforge/roles.tsv"
printf '/tmp/sf-stop-swarm-remote.sock\n' > "$ROOT3/.swarmforge/tmux-socket"

run_remote() {  # run_remote [extra args...]
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB CLOSE_SWARM="$WORK/bin/close-swarm" \
    bash "$STOP" --target test-target --key /dev/null --root "$ROOT3" "$@" 2>&1)
  RC=$?
}
all_clean3() {
  reset_stub; touch "$STUB/live"
  set_pane swarmforge-coder    '❯'
  set_pane swarmforge-cleaner  '❯'
  set_pane swarmforge-reviewer '❯'
  clean_status "$WT3_CODER"
  clean_status "$WT3_CLEANER"
  clean_status "$WT3_REVIEWER"
}

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

# 7. remote mode, SECOND (not first) role BUSY (issue #36): the SESSIONS
#    loop must still reach cleaner's row even though coder's own tmux_remote
#    call runs first — a truncated loop would silently report all-clean and
#    let close-swarm run.
all_clean3
set_pane swarmforge-cleaner 'Working (44s • esc to interrupt)'
run_remote
check "remote second-busy exit" 6 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=UNSAFE$' \
  && ok "remote second-busy status is UNSAFE" || bad "remote second-busy status is UNSAFE" "$OUT"
printf '%s\n' "$OUT" | grep -q '^BUSY=cleaner$' \
  && ok "remote second-busy line names cleaner" || bad "remote second-busy line names cleaner" "$OUT"
! close_swarm_called && ok "remote second-busy: close-swarm never called" \
  || bad "remote second-busy: close-swarm never called" "$(cat "$STUB/calls.log")"

# 8. remote mode, SECOND role UNKNOWN (blank pane) — same gate, same reason
all_clean3
set_pane swarmforge-cleaner ''
run_remote
check "remote second-unknown exit" 6 "$RC"
printf '%s\n' "$OUT" | grep -q '^UNKNOWN=cleaner$' \
  && ok "remote second-unknown line names cleaner" || bad "remote second-unknown line names cleaner" "$OUT"
! close_swarm_called && ok "remote second-unknown: close-swarm never called" \
  || bad "remote second-unknown: close-swarm never called" "$(cat "$STUB/calls.log")"

# 9. remote mode, SECOND (not first) distinct worktree DIRTY (issue #36):
#    the ROLES loop's git_status call must still reach cleaner's worktree.
all_clean3
set_status "$WT3_CLEANER" ' M a.txt'
run_remote
check "remote second-dirty exit" 6 "$RC"
printf '%s\n' "$OUT" | grep -q "^DIRTY=$WT3_CLEANER (1 files)\$" \
  && ok "remote second-dirty line names cleaner's worktree" || bad "remote second-dirty line names cleaner's worktree" "$OUT"
! close_swarm_called && ok "remote second-dirty: close-swarm never called" \
  || bad "remote second-dirty: close-swarm never called" "$(cat "$STUB/calls.log")"

# 10. remote mode, all-clean across 3 roles/worktrees still stops normally
all_clean3
run_remote
check "remote clean exit" 0 "$RC"
close_swarm_called && ok "remote clean: close-swarm called" || bad "remote clean: close-swarm called" "$(cat "$STUB/calls.log")"

# ---------- issue #58: Grok panes must reach a verdict, not UNKNOWN ----------
# stop swarm shares read swarm's classification. With the footer as the last
# non-empty line, every Grok role read UNKNOWN, so the preflight refused every
# stop as UNSAFE/6 and --force became the only way to stop a swarm at all — a
# safety gate that always fires is a safety gate nobody reads.

# 11. an all-idle Grok swarm stops normally, no --force.
all_clean
set_pane swarmforge-coder 'Worked for 2m56s / minimal · /help
❯
Grok 4.6 (high) · always-approve · 93K / 500K (19%) · ctrl+o transcript'
set_pane swarmforge-cleaner 'Worked for 1m02s / minimal · /help
❯
Grok 4.6 (high) · always-approve · 51K / 500K (10%) · ctrl+o transcript'
run
check "grok all-idle exit" 0 "$RC"
close_swarm_called && ok "grok all-idle: close-swarm called without --force" \
  || bad "grok all-idle: close-swarm called without --force" "$(cat "$STUB/calls.log")"

# 12. and a busy Grok role still blocks it. The gate has to keep working in
#     the direction that matters — the spinner sits above the prompt, so a
#     reader that stops at the input line would call this role idle and stop
#     it mid-request.
all_clean
set_pane swarmforge-coder '⠙ Waiting for response… 0.0s … 48s ⇣74.6k
❯
Grok 4.6 (high) · always-approve · 74K / 500K (15%) · ctrl+o transcript'
run
check "grok busy blocks exit" 6 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=UNSAFE$' \
  && ok "grok busy blocks: UNSAFE" || bad "grok busy blocks: UNSAFE" "$OUT"
close_swarm_called && bad "grok busy blocks: close-swarm must not run" "$(cat "$STUB/calls.log")" \
  || ok "grok busy blocks: close-swarm never ran"

# ---------- issue #82: a stop that did not happen must not report STOPPED ----

# 13. close-swarm exits non-zero: STATUS=ERROR/5, its stderr carried through,
#     and STATUS=STOPPED nowhere in the report. `|| true` made this exit 0
#     with STATUS=STOPPED while the swarm kept running — this case is the one
#     that must go red against that version.
all_clean
run_cs "$WORK/bin/close-swarm-fails"
check "close-swarm failure exit" 5 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=ERROR$' \
  && ok "close-swarm failure status is ERROR" || bad "close-swarm failure status is ERROR" "$OUT"
printf '%s\n' "$OUT" | grep -q 'STATUS=STOPPED' \
  && bad "close-swarm failure never claims STOPPED" "$OUT" \
  || ok "close-swarm failure never claims STOPPED"
printf '%s\n' "$OUT" | grep -q 'no tmux server on that socket' \
  && ok "close-swarm failure carries its stderr" || bad "close-swarm failure carries its stderr" "$OUT"

# 14. the same on the --force path. --force waives the preflight, never the
#     question of whether the stop actually ran.
all_clean
run_cs "$WORK/bin/close-swarm-fails" --force
check "force close-swarm failure exit" 5 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=ERROR$' \
  && ok "force close-swarm failure status is ERROR" || bad "force close-swarm failure status is ERROR" "$OUT"
printf '%s\n' "$OUT" | grep -q 'STATUS=STOPPED' \
  && bad "force close-swarm failure never claims STOPPED" "$OUT" \
  || ok "force close-swarm failure never claims STOPPED"

# 15. the live #82 shape: the configured close-swarm does not exist on the
#     target at all. The report must say so and name the way out, because the
#     default path only exists on the operator's own machine.
all_clean
run_cs /nonexistent/dir/close-swarm
check "missing close-swarm exit" 5 "$RC"
printf '%s\n' "$OUT" | grep -q 'STATUS=STOPPED' \
  && bad "missing close-swarm never claims STOPPED" "$OUT" \
  || ok "missing close-swarm never claims STOPPED"
printf '%s\n' "$OUT" | grep -qF '/nonexistent/dir/close-swarm' \
  && ok "missing close-swarm names the path it tried" || bad "missing close-swarm names the path it tried" "$OUT"
printf '%s\n' "$OUT" | grep -q -- '--close-swarm' \
  && ok "missing close-swarm names --close-swarm as the way out" \
  || bad "missing close-swarm names --close-swarm" "$OUT"

# 16. --close-swarm <path> selects the stopper, and beats the environment.
all_clean
OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB CLOSE_SWARM=/nonexistent/dir/close-swarm \
  bash "$STOP" --local --root "$ROOT" --close-swarm "$WORK/bin/close-swarm" 2>&1)
RC=$?
check "--close-swarm exit" 0 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=STOPPED$' \
  && ok "--close-swarm status is STOPPED" || bad "--close-swarm status is STOPPED" "$OUT"
close_swarm_called && ok "--close-swarm beats CLOSE_SWARM in the environment" \
  || bad "--close-swarm beats the environment" "$(cat "$STUB/calls.log")"

# 17. pack_web does not outlive the stop. close-swarm only knows about tmux,
#     so a surviving pack_web plus a later start on a fixed port gives one
#     $ROOT two live dashboards — the squatting case `dashboard`'s ownership
#     check exists to refuse. Uses a real process, not a stub: `kill` is a
#     shell builtin and cannot be shadowed on PATH.
all_clean
sleep 300 &
PW_PID=$!
printf '%s\n' "$PW_PID" > "$ROOT/.swarmforge/pack_web.pid"
run
check "pack_web case exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^PACK_WEB=stopped$' \
  && ok "pack_web reported stopped" || bad "pack_web reported stopped" "$OUT"
sleep 0.3
kill -0 "$PW_PID" 2>/dev/null \
  && { bad "pack_web process actually died" "pid $PW_PID still alive"; kill "$PW_PID" 2>/dev/null; } \
  || ok "pack_web process actually died"
[ -f "$ROOT/.swarmforge/pack_web.pid" ] \
  && bad "pack_web.pid removed" "still there" || ok "pack_web.pid removed"

# 18. no pid file at all is not an error — plenty of swarms never had one.
all_clean
rm -f "$ROOT/.swarmforge/pack_web.pid"
run
check "no pack_web.pid exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^PACK_WEB=absent$' \
  && ok "no pack_web.pid reports absent" || bad "no pack_web.pid reports absent" "$OUT"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

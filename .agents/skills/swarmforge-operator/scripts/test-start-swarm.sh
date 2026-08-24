#!/usr/bin/env bash
# test-start-swarm.sh — end-to-end checks for start-swarm.sh against a
# stubbed tmux/ssh and a fake `./swarm` launcher. Run:
# bash scripts/test-start-swarm.sh. Exits non-zero on any failure.
#
# The write-safety-adjacent risk this script exists to prove is real
# process detachment, not argv shape: a test that only asserts the recorded
# launch command contains "nohup"/"&" proves nothing about whether the
# launched swarm actually survives its launching shell/ssh connection going
# away — that is exactly the #10/#26 incident. The detachment tests below
# (T8 local, T9 remote) instead exercise real process semantics: the fake
# launcher writes its own PID and sleeps past the point start-swarm.sh has
# already returned control, and the test then (a) measures that
# start-swarm.sh's own run took less wall time than the launcher's sleep —
# proving it did not block on the launcher's lifetime — and (b) for the
# local case, sends the launcher's process a real SIGHUP once it is
# confirmed running (the exact signal an ssh session/terminal closing would
# deliver) and confirms it still finishes and writes its marker file
# afterward — proving nohup's protection actually held, not just that the
# word "nohup" appears in a logged command string.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
START=$HERE/start-swarm.sh
WORK=$(mktemp -d /tmp/sf-start-swarm-test.XXXXXX)
# Sibling test-*.sh files are inconsistent here (test-stop-swarm.sh/
# test-open-swarm.sh/test-wake-talk.sh/test-read-swarm.sh/test-accept-work.sh
# leave $WORK behind entirely; test-onboard-project.sh does an unconditional
# `rm -rf "$WORK"` as its own last line) — neither is a real "clean up even
# on early exit" convention, so a trap is used here instead: this script
# already has an early `exit 1` path (missing start-swarm.sh) that a
# bottom-of-file rm would never reach.
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub tmux: same shape as test-stop-swarm.sh's — a "live" flag
# file under $STUB gates list-sessions, so tests control liveness without a
# real tmux server anywhere ----------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'tmux %s\n' "$*" >> "$STUB/calls.log"
[ -f "$STUB/live" ] || exit 1
shift 2  # drop -S <sock>
[ "$1" = list-sessions ] && exit 0
exit 1
EOF
chmod +x "$WORK/bin/tmux"

# ---------- stub ssh: unlike the fixture-dispatching ssh stubs in
# test-open-dashboard.sh, this one actually runs the remote command string
# locally (`bash -c "$last_arg"`) instead of pattern-matching and returning
# canned output. That is deliberate: start-swarm.sh's remote launch is one
# non-interactive ssh invocation whose whole command string is `cd ROOT &&
# nohup CMD >LOG 2>&1 &` — executing it for real (against the stub tmux and
# the fake launcher already on PATH) is what lets T9 exercise genuine
# nohup/background process semantics across the "ssh" boundary, the same
# thing T8 proves for the local path. ----------
cat > "$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'ssh %s\n' "$*" >> "$STUB/calls.log"
cmd=${*: -1}
bash -c "$cmd"
EOF
chmod +x "$WORK/bin/ssh"

export STUB=$WORK/stub
reset_stub() { rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls.log"; }

ROOT=$WORK/fixtures/proj
mkdir -p "$ROOT/.swarmforge"

# ---------- issue #29 fixtures: drift/lock cases need a real scripts_digest
# over a fixture tree to write a MATCHING manifest. Chosen over shelling out
# to start-swarm.sh's own digest step (there's no way to observe an
# intermediate value from outside the script, only its final STATUS line)
# — sourcing lib-wake-talk.sh directly in a subshell is the less awkward
# option given how Task A implemented this: scripts_digest is LOCAL-only
# and takes just a directory arg, no ROOT/TARGET/KEY machinery needed to
# call it standalone. ----------
compute_digest() { # $1 = dir
  ( LOCAL=1
    . "$HERE/lib-wake-talk.sh"
    scripts_digest "$1" )
}
# Fresh scripts tree + matching manifest, shared by every case in this
# file: seeded once below so cases 1-10 (predating issue #29, exercising
# unrelated behavior) sail through the new drift preflight unchanged, and
# reused/overridden explicitly by the issue #29 cases further down. Not
# reset_stub's job (that only clears $STUB) — a separate reset so a case
# can start from a known .swarmforge/swarmforge state.
reset_scripts_fixture() {
  rm -rf "$ROOT/.swarmforge/update-lock" "$ROOT/.swarmforge/scripts-manifest" "$ROOT/swarmforge"
  mkdir -p "$ROOT/swarmforge/scripts"
  printf '#!/bin/sh\necho hi\n' > "$ROOT/swarmforge/scripts/run.sh"
  chmod +x "$ROOT/swarmforge/scripts/run.sh"
  printf 'helper data\n' > "$ROOT/swarmforge/scripts/lib.sh"
}
write_matching_manifest() {
  local d; d=$(compute_digest "$ROOT/swarmforge/scripts")
  printf 'SOURCE_COMMIT=deadbeef\nSOURCE_REPO=unknown\nDIGEST=%s\n' "$d" > "$ROOT/.swarmforge/scripts-manifest"
}
reset_scripts_fixture
write_matching_manifest

# ---------- fake launchers ----------
# slow-launcher: records its own PID immediately (so a test can signal it
# before it finishes), records whether SWARMFORGE_TERMINAL was exported,
# sleeps $SF_TEST_DELAY seconds, then produces the runtime files a real
# `./swarm` would (tmux-socket) and a marker — proof-of-life for "did this
# keep running after its launching process returned".
cat > "$WORK/bin/slow-launcher.sh" <<EOF
#!/usr/bin/env bash
echo "\$\$" > "$STUB/launcher.pid"
if [ -n "\${SWARMFORGE_TERMINAL:-}" ]; then
  printf 'SWARMFORGE_TERMINAL=%s\n' "\$SWARMFORGE_TERMINAL" > "$STUB/launcher.env"
else
  echo NOT_SET > "$STUB/launcher.env"
fi
sleep "\${SF_TEST_DELAY:-2}"
printf '%s\n' "$STUB/fake.sock" > "$ROOT/.swarmforge/tmux-socket"
touch "$STUB/live"
date +%s > "$STUB/marker"
EOF
chmod +x "$WORK/bin/slow-launcher.sh"

# fail-launcher: exits immediately without ever producing runtime files —
# stands in for both "./swarm exited non-zero" and "swarm never became
# ready": start-swarm.sh's own design never inspects the launcher's exit
# code (it's detached, by design — see run_detached), so both failure
# shapes are indistinguishable from outside and both must surface as the
# same timeout-bounded 5 ERROR.
cat > "$WORK/bin/fail-launcher.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WORK/bin/fail-launcher.sh"


# run() redirects to a real FILE rather than capturing through $(...)'s own
# pipe. That is not a style choice: this session found that when the
# launched command is genuinely backgrounded (which is this whole script's
# point), a `$(...)`-captured invocation can block until the background
# child exits — for as long as it keeps running — because the child
# inherits a duplicate of the pipe's write end. A file has no such "wait
# for every writer to close" semantics, so it sidesteps the problem
# entirely instead of relying on every intermediate layer (including the
# stub ssh below) getting fd hygiene exactly right.
OUTFILE=$WORK/out.txt
run() {  # run [extra args...]  (PATH/STUB/SWARM_LAUNCHER/READY_* set by caller env)
  PATH="$WORK/bin:$PATH" STUB=$STUB bash "$START" "$@" > "$OUTFILE" 2>&1
  RC=$?
  OUT=$(cat "$OUTFILE")
}
status_line() { printf '%s\n' "$OUT" | head -1; }
launcher_ran() { [ -f "$STUB/launcher.pid" ] || [ -f "$STUB/marker" ]; }

echo "== RED/GREEN suite for start-swarm.sh =="

if [ ! -f "$START" ]; then
  echo "script missing — RED confirmed, all cases fail"; exit 1
fi

# 1. missing --root -> 2 USAGE, nothing attempted
reset_stub
OUT=$(bash "$START" --local --terminal none 2>&1); RC=$?
check "missing --root exit" 2 "$RC"
! launcher_ran && ok "missing --root: launcher never ran" || bad "missing --root: launcher never ran" "$STUB"

# 2. missing --terminal -> 2 USAGE
reset_stub
OUT=$(bash "$START" --local --root "$ROOT" 2>&1); RC=$?
check "missing --terminal exit" 2 "$RC"
! launcher_ran && ok "missing --terminal: launcher never ran" || bad "missing --terminal: launcher never ran" "$STUB"

# 3. invalid --terminal value -> 2 USAGE (not forwarded, not silently
#    accepted — the whole point of a closed value set)
reset_stub
OUT=$(bash "$START" --local --root "$ROOT" --terminal bogus 2>&1); RC=$?
check "bad --terminal exit" 2 "$RC"

# 4. already running (socket answers) -> 6 UNSAFE, refuses to start a
#    second daemon; launcher never invoked
reset_stub
printf '%s\n' "$STUB/fake.sock" > "$ROOT/.swarmforge/tmux-socket"
touch "$STUB/live"
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh run --local --root "$ROOT" --terminal none
check "already-running exit" 6 "$RC"
[ "$(status_line)" = "STATUS=UNSAFE" ] \
  && ok "already-running status is UNSAFE" || bad "already-running status is UNSAFE" "$OUT"
! launcher_ran && ok "already-running: launcher never invoked (no second daemon)" \
  || bad "already-running: launcher never invoked" "$(cat "$STUB/calls.log")"

# 4b. stale tmux-socket FILE present but dead (no live flag) is the
#     watchdog-kill/stopped state, not "already running" — must proceed to
#     launch normally, not refuse
reset_stub
printf '%s\n' "$STUB/fake.sock" > "$ROOT/.swarmforge/tmux-socket"
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh SF_START_READY_TRIES=10 SF_START_READY_INTERVAL=0.3 SF_TEST_DELAY=0.5 \
  run --local --root "$ROOT" --terminal none
check "stale-socket exit" 0 "$RC"
[ "$(status_line)" = "STATUS=STARTED" ] \
  && ok "stale-socket status is STARTED (proceeded to launch)" || bad "stale-socket status is STARTED" "$OUT"

# 5. happy path: --terminal ghostty actually exports SWARMFORGE_TERMINAL to
#    the launcher; STATUS=STARTED, exit 0, SOCK reported from runtime file
reset_stub
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh SF_START_READY_TRIES=10 SF_START_READY_INTERVAL=0.3 SF_TEST_DELAY=0.5 \
  run --local --root "$ROOT" --terminal ghostty
check "happy exit" 0 "$RC"
[ "$(status_line)" = "STATUS=STARTED" ] \
  && ok "happy status is STARTED" || bad "happy status is STARTED" "$OUT"
printf '%s\n' "$OUT" | grep -q '^SOCK='"$STUB"'/fake.sock$' \
  && ok "happy: SOCK read back from runtime file" || bad "happy: SOCK read back from runtime file" "$OUT"
[ "$(cat "$STUB/launcher.env")" = "SWARMFORGE_TERMINAL=ghostty" ] \
  && ok "happy: SWARMFORGE_TERMINAL=ghostty reached the launcher" \
  || bad "happy: SWARMFORGE_TERMINAL=ghostty reached the launcher" "$(cat "$STUB/launcher.env")"

# 6. --terminal auto: the sentinel is NOT forwarded literally — the
#    launcher must see no SWARMFORGE_TERMINAL at all, letting
#    detect-terminal-backend's own fallback run
reset_stub
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh SF_START_READY_TRIES=10 SF_START_READY_INTERVAL=0.3 SF_TEST_DELAY=0.5 \
  run --local --root "$ROOT" --terminal auto
check "auto exit" 0 "$RC"
[ "$(cat "$STUB/launcher.env")" = NOT_SET ] \
  && ok "auto: SWARMFORGE_TERMINAL never exported to the launcher" \
  || bad "auto: SWARMFORGE_TERMINAL never exported" "$(cat "$STUB/launcher.env")"

# 7. launch failure: launcher exits immediately, never produces runtime
#    files -> readiness never satisfied -> 5 ERROR (bounded by the test's
#    short retry budget, not the script's real 60s default)
reset_stub
SWARM_LAUNCHER=$WORK/bin/fail-launcher.sh SF_START_READY_TRIES=3 SF_START_READY_INTERVAL=0.2 \
  run --local --root "$ROOT" --terminal none
check "launch-failure exit" 5 "$RC"
[ "$(status_line)" = "STATUS=ERROR" ] \
  && ok "launch-failure status is ERROR" || bad "launch-failure status is ERROR" "$OUT"

# 8. DETACHMENT PROOF (local): start-swarm.sh must return control long
#    before the launcher's own sleep elapses (never waits on its lifetime),
#    and the launcher must survive a real SIGHUP sent directly at it after
#    start-swarm.sh has already exited — the same signal a closing
#    ssh session/terminal delivers, and exactly what killed the swarm twice
#    in the real incident when nothing protected the child from it.
reset_stub
DELAY=3
SECONDS=0
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh SF_START_READY_TRIES=2 SF_START_READY_INTERVAL=0.2 SF_TEST_DELAY=$DELAY \
  run --local --root "$ROOT" --terminal none
ELAPSED=$SECONDS
[ "$ELAPSED" -lt "$DELAY" ] \
  && ok "local: start-swarm.sh returned in ${ELAPSED}s, well before the ${DELAY}s launcher sleep" \
  || bad "local: start-swarm.sh returned before launcher sleep" "took ${ELAPSED}s, launcher sleeps ${DELAY}s"
[ -f "$STUB/marker" ] \
  && bad "local: marker premature" "marker already existed right after start-swarm.sh returned — test budget too loose to prove anything" \
  || ok "local: marker does not exist yet (launcher genuinely still running independently)"
[ -s "$STUB/launcher.pid" ] \
  && ok "local: launcher recorded its own PID" || bad "local: launcher recorded its own PID" "no pidfile"
PID=$(cat "$STUB/launcher.pid" 2>/dev/null)
if kill -0 "$PID" 2>/dev/null; then
  ok "local: launcher process is alive right after start-swarm.sh exited (a real orphan, not reaped with its parent)"
  kill -HUP "$PID" 2>/dev/null
  ok "local: sent a real SIGHUP directly at the launcher (what a closing session/terminal delivers)"
else
  bad "local: launcher process alive after start-swarm.sh exited" "pid $PID not found"
fi
for _ in $(seq 1 $((DELAY * 4 + 10))); do [ -f "$STUB/marker" ] && break; sleep 0.25; done
[ -f "$STUB/marker" ] \
  && ok "local: marker appeared after SIGHUP — nohup protected the launcher, detachment is real" \
  || bad "local: marker appeared after SIGHUP" "never appeared — launcher was NOT actually detached"

# 9. DETACHMENT PROOF (remote): same property, crossing the stub ssh
#    boundary — the stub actually execs the remote command string
#    (`cd ROOT && nohup CMD >LOG 2>&1 &`), so this exercises the same real
#    background/nohup semantics as T8, just reached through run_detached's
#    remote branch instead of its local one.
reset_stub
DELAY=3
SECONDS=0
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh SF_START_READY_TRIES=2 SF_START_READY_INTERVAL=0.2 SF_TEST_DELAY=$DELAY \
  run --root "$ROOT" --terminal none --target testhost --key /dev/null
ELAPSED=$SECONDS
[ "$ELAPSED" -lt "$DELAY" ] \
  && ok "remote: start-swarm.sh returned in ${ELAPSED}s, well before the ${DELAY}s launcher sleep" \
  || bad "remote: start-swarm.sh returned before launcher sleep" "took ${ELAPSED}s, launcher sleeps ${DELAY}s"
for _ in $(seq 1 $((DELAY * 4 + 10))); do [ -f "$STUB/marker" ] && break; sleep 0.25; done
[ -f "$STUB/marker" ] \
  && ok "remote: marker appeared after the stub ssh invocation itself had already returned" \
  || bad "remote: marker appeared after ssh returned" "never appeared — remote launch was NOT actually detached"

# 10. REGRESSION (review round 1): T8/T9 above deliberately go through
#     run()'s file-redirected OUTFILE, which sidesteps the exact failure
#     mode of the #26 hang bug this session found and fixed in
#     run_detached — a caller capturing start-swarm.sh's own combined
#     stdout+stderr via REAL command substitution (`$(... 2>&1)`) would
#     block on a leaked fd until the detached launcher itself exited,
#     because the old implementation wrapped the background job in a
#     subshell (`( cd ... && nohup ... & )`). Nothing above this point would
#     catch a future regression that re-wraps run_detached in a subshell.
#     This case exercises that literal seam: a real `$(...)` capture around
#     start-swarm.sh itself, with a short bounded launcher delay, asserting
#     the capture returns promptly rather than waiting out the delay.
reset_stub
DELAY=3
SECONDS=0
CAPTURED=$(PATH="$WORK/bin:$PATH" STUB=$STUB SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh \
  SF_START_READY_TRIES=2 SF_START_READY_INTERVAL=0.2 SF_TEST_DELAY=$DELAY \
  bash "$START" --local --root "$ROOT" --terminal none 2>&1)
ELAPSED=$SECONDS
[ "$ELAPSED" -lt "$DELAY" ] \
  && ok "regression: \$(...)-captured run returned in ${ELAPSED}s, well before the ${DELAY}s launcher sleep (run_detached's fd isn't leaked into the child)" \
  || bad "regression: \$(...)-captured run returned before launcher sleep" "took ${ELAPSED}s, launcher sleeps ${DELAY}s -- \$(...) blocked on a leaked fd, the exact #26 hang"
for _ in $(seq 1 $((DELAY * 4 + 10))); do [ -f "$STUB/marker" ] && break; sleep 0.25; done
[ -f "$STUB/marker" ] \
  && ok "regression: marker appeared after the \$(...) capture had already returned — launcher genuinely kept running detached" \
  || bad "regression: marker appeared after capture returned" "never appeared"

# ---------- issue #29: lock + drift preflight, inserted between the
# already-running check and launch ----------

# 11. missing manifest -> STATUS=DRIFT, exit 4, launcher never invoked
reset_stub
reset_scripts_fixture
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh run --local --root "$ROOT" --terminal none
check "missing-manifest exit" 4 "$RC"
[ "$(status_line)" = "STATUS=DRIFT" ] \
  && ok "missing-manifest status is DRIFT" || bad "missing-manifest status is DRIFT" "$OUT"
! launcher_ran && ok "missing-manifest: launcher never invoked" \
  || bad "missing-manifest: launcher never invoked" "$(cat "$STUB/calls.log")"
# 11b (brief case 8): the drift refusal above still released the lock —
# same trap release_lock EXIT path as any other exit.
[ -d "$ROOT/.swarmforge/update-lock" ] \
  && bad "missing-manifest: lock released" "update-lock still exists after a DRIFT refusal" \
  || ok "missing-manifest: lock released after a DRIFT refusal"

# 12. manifest present but DIGEST= doesn't match the installed tree ->
#     STATUS=DRIFT, exit 4, launcher never invoked
reset_stub
reset_scripts_fixture
printf 'SOURCE_COMMIT=deadbeef\nSOURCE_REPO=unknown\nDIGEST=0000000000000000000000000000000000000000000000000000000000000000\n' \
  > "$ROOT/.swarmforge/scripts-manifest"
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh run --local --root "$ROOT" --terminal none
check "digest-mismatch exit" 4 "$RC"
[ "$(status_line)" = "STATUS=DRIFT" ] \
  && ok "digest-mismatch status is DRIFT" || bad "digest-mismatch status is DRIFT" "$OUT"
! launcher_ran && ok "digest-mismatch: launcher never invoked" \
  || bad "digest-mismatch: launcher never invoked" "$(cat "$STUB/calls.log")"

# 13. manifest present and digest genuinely matches -> proceeds to launch
#     normally, STATUS=STARTED
reset_stub
reset_scripts_fixture
write_matching_manifest
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh SF_START_READY_TRIES=10 SF_START_READY_INTERVAL=0.3 SF_TEST_DELAY=0.5 \
  run --local --root "$ROOT" --terminal none
check "digest-match exit" 0 "$RC"
[ "$(status_line)" = "STATUS=STARTED" ] \
  && ok "digest-match status is STARTED" || bad "digest-match status is STARTED" "$OUT"
# 13b (brief case 7): lock released after a clean, --force-free run too,
# not just after a DRIFT refusal.
[ -d "$ROOT/.swarmforge/update-lock" ] \
  && bad "digest-match: lock released" "update-lock still exists after a clean STARTED run" \
  || ok "digest-match: lock released after a clean run"

# 14. --force overrides DRIFT: mismatched manifest AND --force -> proceeds
#     to launch anyway, STATUS=STARTED
reset_stub
reset_scripts_fixture
printf 'SOURCE_COMMIT=deadbeef\nSOURCE_REPO=unknown\nDIGEST=0000000000000000000000000000000000000000000000000000000000000000\n' \
  > "$ROOT/.swarmforge/scripts-manifest"
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh SF_START_READY_TRIES=10 SF_START_READY_INTERVAL=0.3 SF_TEST_DELAY=0.5 \
  run --local --root "$ROOT" --terminal none --force
check "force-overrides-drift exit" 0 "$RC"
[ "$(status_line)" = "STATUS=STARTED" ] \
  && ok "force-overrides-drift status is STARTED" || bad "force-overrides-drift status is STARTED" "$OUT"

# 15. lock contention: a pre-existing lock held by `update` -> STATUS=UNSAFE,
#     exit 6, message names `update`, launcher never invoked, lock directory
#     still exists afterward (start never touches someone else's lock
#     without --force)
reset_stub
reset_scripts_fixture
write_matching_manifest
mkdir -p "$ROOT/.swarmforge/update-lock"
printf 'update\n' > "$ROOT/.swarmforge/update-lock/holder"
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh run --local --root "$ROOT" --terminal none
check "lock-contention exit" 6 "$RC"
[ "$(status_line)" = "STATUS=UNSAFE" ] \
  && ok "lock-contention status is UNSAFE" || bad "lock-contention status is UNSAFE" "$OUT"
printf '%s' "$OUT" | grep -q "'update'" \
  && ok "lock-contention: message names 'update'" || bad "lock-contention: message names 'update'" "$OUT"
! launcher_ran && ok "lock-contention: launcher never invoked" \
  || bad "lock-contention: launcher never invoked" "$(cat "$STUB/calls.log")"
[ -f "$ROOT/.swarmforge/update-lock/holder" ] \
  && ok "lock-contention: lock directory still exists afterward (untouched)" \
  || bad "lock-contention: lock directory still exists afterward" "lock dir/holder missing"

# 16. --force overrides lock contention: same pre-created lock, --force ->
#     proceeds (lock removed and re-acquired), reaches launch,
#     STATUS=STARTED
reset_stub
reset_scripts_fixture
write_matching_manifest
mkdir -p "$ROOT/.swarmforge/update-lock"
printf 'update\n' > "$ROOT/.swarmforge/update-lock/holder"
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh SF_START_READY_TRIES=10 SF_START_READY_INTERVAL=0.3 SF_TEST_DELAY=0.5 \
  run --local --root "$ROOT" --terminal none --force
check "force-overrides-lock exit" 0 "$RC"
[ "$(status_line)" = "STATUS=STARTED" ] \
  && ok "force-overrides-lock status is STARTED" || bad "force-overrides-lock status is STARTED" "$OUT"

# 17. already-running still takes priority and still has no override:
#     a live socket AND a mismatched manifest AND --force -> still
#     STATUS=UNSAFE exit 6 for "already running" (not DRIFT, not a launch)
#     — proves --force never reaches the already-running check
reset_stub
reset_scripts_fixture
printf 'SOURCE_COMMIT=deadbeef\nSOURCE_REPO=unknown\nDIGEST=0000000000000000000000000000000000000000000000000000000000000000\n' \
  > "$ROOT/.swarmforge/scripts-manifest"
printf '%s\n' "$STUB/fake.sock" > "$ROOT/.swarmforge/tmux-socket"
touch "$STUB/live"
SWARM_LAUNCHER=$WORK/bin/slow-launcher.sh run --local --root "$ROOT" --terminal none --force
check "already-running-beats-force exit" 6 "$RC"
[ "$(status_line)" = "STATUS=UNSAFE" ] \
  && ok "already-running-beats-force status is UNSAFE (not DRIFT)" \
  || bad "already-running-beats-force status is UNSAFE" "$OUT"
! launcher_ran && ok "already-running-beats-force: launcher never invoked" \
  || bad "already-running-beats-force: launcher never invoked" "$(cat "$STUB/calls.log")"

# 18. REGRESSION (review round 2): scripts_digest must be immune to a
#     trailing slash on its directory argument. The documented invariant is
#     that only the tree's relative-path/content/executable-bit shape
#     drives the digest — never how the caller happened to spell the path.
#     Before this fix, `rel=${f#"$dir"/}` effectively became a
#     double-slash strip when $dir already ended in `/`, so it silently
#     failed to match find's single-slash output and the whole absolute
#     path leaked into the digest line unstripped — start-swarm.sh's own
#     call site never trips this (never passes a trailing slash), but
#     compute_digest above is exactly the reusable primitive a future
#     caller (e.g. `update SwarmForge scripts`, issue #29) is expected to
#     call with differently-built paths, some of which may concatenate a
#     trailing slash in. Proves the SAME tree digests identically with and
#     without one.
D_NO_SLASH=$(compute_digest "$ROOT/swarmforge/scripts")
D_SLASH=$(compute_digest "$ROOT/swarmforge/scripts/")
check "trailing-slash: same tree digests identically with/without a trailing slash" "$D_NO_SLASH" "$D_SLASH"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

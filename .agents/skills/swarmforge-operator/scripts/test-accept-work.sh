#!/usr/bin/env bash
# test-accept-work.sh — end-to-end checks for accept-work.sh against a
# stubbed git (issue #17). Run: bash scripts/test-accept-work.sh. Exits
# non-zero on any failure. Tests run --local (same convention as
# test-stop-swarm.sh), so ssh is never invoked and never stubbed; find/sed
# run for real against fixture files under a temp ROOT. Only `git` is
# stubbed, for the merge-base --is-ancestor exclusion check.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ACCEPT=$HERE/accept-work.sh
WORK=$(mktemp -d /tmp/sf-accept-work-test.XXXXXX)
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub git: accept-work.sh only ever calls
# `git -C <ROOT> merge-base --is-ancestor <commit> origin/main` — mirror the
# real command's exit-code contract (0 = ancestor/shipped, 1 = not) off a
# fixture list of "shipped" commits, so the test never touches a real repo.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'git %s\n' "$*" >> "$STUB/calls.log"
commit="" prev=""
for a in "$@"; do
  [ "$prev" = "--is-ancestor" ] && commit=$a
  prev=$a
done
grep -qxF "$commit" "$STUB/shipped-commits" 2>/dev/null && exit 0 || exit 1
EOF
chmod +x "$WORK/bin/git"

export STUB=$WORK/stub
reset_stub() { rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls.log"; : > "$STUB/shipped-commits"; }
ship() { printf '%s\n' "$1" >> "$STUB/shipped-commits"; }  # ship <commit> — marks it already on origin/main

ROOT=$WORK/fixtures/twopack
now=$(date -u +%s)
# ts <seconds-ago> — ISO8601 UTC, GNU date first then BSD -j (macOS) fallback,
# same two-path conversion accept-work.sh itself uses for the reverse direction.
ts() {
  local ep=$(( now - $1 ))
  date -u -d "@$ep" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -j -f %s "$ep" +%Y-%m-%dT%H:%M:%SZ
}

reset_fixture() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT/.swarmforge/handoffs/inbox/completed" \
           "$ROOT/.swarmforge/handoffs/inbox/new" \
           "$ROOT/.swarmforge/handoffs/inbox/in_process"
}

# mk_completed <worktree|-> <filename> <task> <commit> <age-seconds>
mk_completed() {
  local dir=$ROOT/.swarmforge/handoffs/inbox/completed
  [ "$1" = - ] || { dir=$ROOT/.worktrees/$1/.swarmforge/handoffs/inbox/completed; mkdir -p "$dir"; }
  cat > "$dir/$2" <<EOF
id: x
task: $3
commit: $4
completed_at: $(ts "$5")

body
EOF
}
# mk_new <worktree|-> <filename> <task> <age-seconds>
mk_new() {
  local dir=$ROOT/.swarmforge/handoffs/inbox/new
  [ "$1" = - ] || { dir=$ROOT/.worktrees/$1/.swarmforge/handoffs/inbox/new; mkdir -p "$dir"; }
  cat > "$dir/$2" <<EOF
id: x
task: $3
enqueued_at: $(ts "$4")

body
EOF
}
# mk_inprocess <worktree|-> <filename> <task> <age-seconds>
mk_inprocess() {
  local dir=$ROOT/.swarmforge/handoffs/inbox/in_process
  [ "$1" = - ] || { dir=$ROOT/.worktrees/$1/.swarmforge/handoffs/inbox/in_process; mkdir -p "$dir"; }
  cat > "$dir/$2" <<EOF
id: x
task: $3
dequeued_at: $(ts "$4")

body
EOF
}

run() {
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB bash "$ACCEPT" --local --root "$ROOT" 2>&1)
  RC=$?
}

# checksum every file under every inbox/ tree in the fixture — used to assert
# accept-work.sh never writes, moves, or deletes a handoff file.
inbox_checksum() {
  find "$ROOT" -path '*/handoffs/inbox/*' -type f -print0 \
    | sort -z | xargs -0 cksum 2>/dev/null
}

echo "== RED/GREEN suite for accept-work.sh =="

if [ ! -f "$ACCEPT" ]; then
  echo "script missing — RED confirmed, all cases fail"; exit 1
fi

# 1. clean run: nothing in new/in_process/completed anywhere -> STATUS=REPORTED,
#    no WARN=, exit 0. This is the "genuinely no work finished yet" case the
#    issue says must read differently from a stuck chain.
reset_fixture; reset_stub
run
check "clean exit" 0 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=REPORTED$' \
  && ok "clean status is REPORTED" || bad "clean status is REPORTED" "$OUT"
! printf '%s\n' "$OUT" | grep -q '^WARN=' \
  && ok "clean: no WARN" || bad "clean: no WARN" "$OUT"

# 2. a FRESH inbox/new file (enqueued seconds ago) must not WARN — presence
#    alone is not "stuck"; a healthy chain routinely has a file sit briefly
#    between delivery and pickup (handoffd's own retry ladder doesn't even
#    send its first re-wake until 5s have passed).
reset_fixture; reset_stub
mk_new cleaner 01_fresh.handoff task-fresh 5
run
check "fresh new exit" 0 "$RC"
! printf '%s\n' "$OUT" | grep -q '^WARN=' \
  && ok "fresh inbox/new: no WARN" || bad "fresh inbox/new: no WARN" "$OUT"

# 3. THREE stale inbox/new files in one worktree -> WARN= with the count and
#    the worktree name, exit still 0 (a stuck chain is information the verb
#    successfully reported, not a verb failure).
reset_fixture; reset_stub
mk_new cleaner 01_stale.handoff task-a 4000
mk_new cleaner 02_stale.handoff task-b 4000
mk_new cleaner 03_stale.handoff task-c 4000
run
check "stale new exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^WARN=3 handoffs are stuck in inbox/new in cleaner ' \
  && ok "stale inbox/new: WARN names count and worktree" \
  || bad "stale inbox/new: WARN names count and worktree" "$OUT"

# 4. a stale inbox/in_process file (claimed but not finishing) -> its own
#    WARN=, distinct wording from inbox/new, exit 0.
reset_fixture; reset_stub
mk_inprocess coder 01_stuck.handoff task-d 3600
run
check "stale in_process exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^WARN=1 handoffs are stuck in inbox/in_process in coder ' \
  && ok "stale inbox/in_process: WARN names count and worktree" \
  || bad "stale inbox/in_process: WARN names count and worktree" "$OUT"
# an in-progress task well under the (much longer) in_process threshold must
# not WARN, even though it would already be "stale" by inbox/new's threshold —
# ordinary task duration must not trip this one.
reset_fixture; reset_stub
mk_inprocess coder 01_working.handoff task-e 600
run
! printf '%s\n' "$OUT" | grep -q '^WARN=' \
  && ok "in-progress inbox/in_process: no WARN" || bad "in-progress inbox/in_process: no WARN" "$OUT"

# 5. pre-existing exclusion: a completed handoff whose commit is already on
#    origin/main must not be reported again; a sibling not-yet-shipped
#    completed handoff still is. This is the manual logic being ported, not
#    new behavior.
reset_fixture; reset_stub
ship aaaaaaaaaa
mk_completed - 00_shipped.handoff task-shipped aaaaaaaaaa 100
mk_completed - 00_unshipped.handoff task-unshipped bbbbbbbbbb 50
run
check "exclusion exit" 0 "$RC"
! printf '%s\n' "$OUT" | grep -q 'task: task-shipped' \
  && ok "already-shipped commit excluded" || bad "already-shipped commit excluded" "$OUT"
printf '%s\n' "$OUT" | grep -q 'task: task-unshipped' \
  && ok "not-yet-shipped commit still reported" || bad "not-yet-shipped commit still reported" "$OUT"
printf '%s\n' "$OUT" | grep -q 'commit: bbbbbbbbbb' \
  && ok "unshipped report carries its commit" || bad "unshipped report carries its commit" "$OUT"

# 6. terminal-handoff dedup: two completed files for the same task (a chain
#    hop, then the terminal one) -> only the newest is reported.
reset_fixture; reset_stub
mk_completed - 00_20260101T000000Z_from_a.handoff task-x aaaaaaaaaa 200
mk_completed - 00_20260102T000000Z_from_b.handoff task-x bbbbbbbbbb 100
run
N=$(printf '%s\n' "$OUT" | grep -c '^task: task-x$')
check "dedup keeps exactly one entry" 1 "$N"
printf '%s\n' "$OUT" | grep -q 'commit: bbbbbbbbbb' \
  && ok "dedup keeps the newest hop" || bad "dedup keeps the newest hop" "$OUT"

# 7. never writes: a fixture combining every kind of file (completed, stale
#    new, stale in_process) is checksummed before and after two runs; every
#    file must be byte-for-byte and file-for-file unchanged.
reset_fixture; reset_stub
mk_completed - 00_a.handoff task-a aaaaaaaaaa 100
mk_new cleaner 01_stale.handoff task-b 4000
mk_new cleaner 02_fresh.handoff task-c 5
mk_inprocess coder 01_stuck.handoff task-d 3600
BEFORE=$(inbox_checksum)
run; run
AFTER=$(inbox_checksum)
check "no writes under inbox/ across two runs" "$BEFORE" "$AFTER"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

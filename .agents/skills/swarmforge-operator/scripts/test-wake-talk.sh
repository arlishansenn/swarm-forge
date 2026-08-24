#!/usr/bin/env bash
# test-wake-talk.sh — end-to-end checks for wake-role.sh/talk-role.sh against
# a stubbed tmux. Run: bash scripts/test-wake-talk.sh. Exits non-zero on any
# failure. Tests run --local, matching test-open-swarm.sh's convention, so
# ssh is never invoked and never stubbed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WAKE=$HERE/wake-role.sh
TALK=$HERE/talk-role.sh
WORK=$(mktemp -d /tmp/sf-wake-talk-test.XXXXXX)
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub tmux ----------
# State lives in $STUB: calls.log records every invocation's argv (so tests
# can assert the submit key is never the symbolic C-m/C-j); pane.txt is the
# simulated input line/pane content; a missing "live" flag simulates a
# socket with no tmux server (exit 3 gate); a missing "consume" flag makes
# the -H submit call a no-op, simulating a submit key that never lands.
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
  send-keys)
    shift 2  # drop -t <session>
    case $1 in
      -l) printf '%s' "$2" >> "$STUB/pane.txt" ;;
      -H) [ -f "$STUB/consume" ] && : > "$STUB/pane.txt" ;;
    esac
    exit 0 ;;
  capture-pane) cat "$STUB/pane.txt" 2>/dev/null || true; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/tmux"
export STUB=$WORK/stub

reset_stub() { rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls.log"; : > "$STUB/pane.txt"; }

mk_fixture() { # mk_fixture <name> <role> <session> <agent>
  local root=$WORK/fixtures/$1
  mkdir -p "$root/.swarmforge"
  printf '1\t%s\t%s\t%s Display\t%s\n' "$2" "$3" "$2" "$4" > "$root/.swarmforge/sessions.tsv"
  printf '/tmp/sf-wake-talk-%s.sock\n' "$1" > "$root/.swarmforge/tmux-socket"
}

mk_fixture claude coder swarmforge-coder claude
mk_fixture grok coder swarmforge-coder grok

# fast, deterministic polling for tests — same override trick as
# handoffd.bb's SWARMFORGE_WAKE_RETRY_MS.
export SF_ARRIVAL_TRIES=3 SF_ARRIVAL_INTERVAL=0.01
export SF_CONSUME_TRIES=3 SF_CONSUME_INTERVAL=0.01

run_wake() { # run_wake <fixture>
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB bash "$WAKE" --local \
    --root "$WORK/fixtures/$1" --role coder 2>&1)
  RC=$?
}
run_talk() { # run_talk <fixture> <message>
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB bash "$TALK" --local \
    --root "$WORK/fixtures/$1" --role coder --message "$2" 2>&1)
  RC=$?
}
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

echo "== RED/GREEN suite for wake-role.sh / talk-role.sh =="

if [ ! -f "$WAKE" ] || [ ! -f "$TALK" ]; then
  echo "scripts missing — RED confirmed, all cases fail"; exit 1
fi

# 1. submit succeeds (claude backend: CSI-u Enter) → exit 0
reset_stub; touch "$STUB/live" "$STUB/consume"
run_wake claude
check "wake success exit" 0 "$RC"
check "wake success status" WOKEN "$(val STATUS)"
grep -q "send-keys -t swarmforge-coder -H 1b 5b 31 33 75" "$STUB/calls.log" \
  && ok "wake used CSI-u submit for claude" || bad "wake used CSI-u submit for claude" "not found in calls.log"

# 2. talk succeeds (grok backend: raw CR) → exit 0
reset_stub; touch "$STUB/live" "$STUB/consume"
run_talk grok "do the thing"
check "talk success exit" 0 "$RC"
check "talk success status" SENT "$(val STATUS)"
grep -q "send-keys -t swarmforge-coder -H 0d" "$STUB/calls.log" \
  && ok "talk used raw CR submit for grok" || bad "talk used raw CR submit for grok" "not found in calls.log"

# 3. text delivered but never consumed (submit key swallowed) → exit 5, mentions backend
reset_stub; touch "$STUB/live"  # no "consume" flag: -H never clears the pane
run_wake claude
check "unconsumed exit" 5 "$RC"
printf '%s\n' "$OUT" | grep -q "backend (claude)" \
  && ok "unconsumed message names the backend" || bad "unconsumed message names the backend" "$OUT"

# 4. role not in sessions.tsv → exit 5
reset_stub; touch "$STUB/live" "$STUB/consume"
OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB bash "$WAKE" --local \
  --root "$WORK/fixtures/claude" --role ghost 2>&1); RC=$?
check "unknown role exit" 5 "$RC"

# 5. socket has no tmux server → exit 3
reset_stub  # no "live" flag
run_wake claude
check "no-server exit" 3 "$RC"

# 6. never uses symbolic C-m/C-j to submit, across every case above
! grep -Eq '(^| )(C-m|C-j)( |$)' "$STUB/calls.log" \
  && ok "no symbolic C-m/C-j anywhere in this run's calls" || bad "no symbolic C-m/C-j" "found in calls.log"
reset_stub; touch "$STUB/live" "$STUB/consume"
run_wake claude; run_talk grok "hello"
! grep -Eq '(^| )(C-m|C-j)( |$)' "$STUB/calls.log" \
  && ok "no symbolic C-m/C-j across wake+talk success runs" || bad "no symbolic C-m/C-j across wake+talk success runs" "found in calls.log"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

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
#
# When "consume" IS set, a "retain" flag picks which of the two real
# redraw shapes issue #28 found backends actually use:
#   - no "retain": pane.txt is wiped to empty — claude/codex observed
#     behavior, the input line clears with no duplicate left behind.
#   - "retain" set: pane.txt keeps the already-typed text and gets a new
#     line appended below it (a busy marker, matching the "Thinking…" line
#     from the issue's real Grok transcript) — Grok's observed behavior,
#     where the submitted text moves into persisted history instead of
#     being erased. This is the case the old whole-pane pane_has check
#     mistook for "never submitted".
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
      -H)
        if [ -f "$STUB/consume" ]; then
          if [ -f "$STUB/retain" ]; then
            printf '\nThinking…\n' >> "$STUB/pane.txt"
          else
            : > "$STUB/pane.txt"
          fi
        fi
        ;;
    esac
    exit 0 ;;
  capture-pane)
    cat "$STUB/pane.txt" 2>/dev/null || true
    # "footer" flag (issue #58): Grok draws a static line BELOW the prompt that
    # never contains the input and never changes on submit. Rendered here, in
    # capture-pane, because that is where it exists — it is chrome the pane
    # paints, not something send-keys ever writes into pane.txt.
    if [ -f "$STUB/footer" ]; then
      printf '\n%s\n' 'Grok 4.6 (high) · always-approve · 93K / 500K (19%) · ctrl+o transcript'
    fi
    exit 0 ;;
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

# 1. submit succeeds, input line clears to blank (claude/codex observed
#    behavior; CSI-u Enter for claude) → exit 0
reset_stub; touch "$STUB/live" "$STUB/consume"
run_wake claude
check "wake success exit (blank-on-consume)" 0 "$RC"
check "wake success status (blank-on-consume)" WOKEN "$(val STATUS)"
grep -q "send-keys -t swarmforge-coder -H 1b 5b 31 33 75" "$STUB/calls.log" \
  && ok "wake used CSI-u submit for claude" || bad "wake used CSI-u submit for claude" "not found in calls.log"

# 1b. same blank-on-consume redraw, through talk-role.sh — both verbs share
#     send_and_verify, so both must accept it.
reset_stub; touch "$STUB/live" "$STUB/consume"
run_talk claude "do the thing"
check "talk success exit (blank-on-consume)" 0 "$RC"
check "talk success status (blank-on-consume)" SENT "$(val STATUS)"

# 2. submit succeeds, but the pane RETAINS the submitted text in transcript
#    history and redraws a busy line below it instead of clearing (issue
#    #28: Grok's real behavior on podsum) → still exit 0. This is the
#    fixture that proves the CONSUME check no longer depends on the text
#    disappearing from the whole pane, only from the last non-empty line.
reset_stub; touch "$STUB/live" "$STUB/consume" "$STUB/retain"
run_talk grok "do the thing"
check "talk success exit (retain-history-on-consume)" 0 "$RC"
check "talk success status (retain-history-on-consume)" SENT "$(val STATUS)"
grep -q "send-keys -t swarmforge-coder -H 0d" "$STUB/calls.log" \
  && ok "talk used raw CR submit for grok" || bad "talk used raw CR submit for grok" "not found in calls.log"
grep -qF "do the thing" "$STUB/pane.txt" \
  && ok "retain-history fixture actually kept the text in pane.txt" \
  || bad "retain-history fixture actually kept the text in pane.txt" "$(cat "$STUB/pane.txt")"

# 2b. same retain-history redraw, through wake-role.sh (acceptance
#     criterion: wake role must also treat retained history as success).
reset_stub; touch "$STUB/live" "$STUB/consume" "$STUB/retain"
run_wake grok
check "wake success exit (retain-history-on-consume)" 0 "$RC"
check "wake success status (retain-history-on-consume)" WOKEN "$(val STATUS)"

# 3. text delivered but never consumed (submit key swallowed) → exit 5,
#    mentions backend. "retain" is irrelevant here since -H never even
#    fires without "consume" — kept unset to match the no-op path exactly.
reset_stub; touch "$STUB/live"  # no "consume" flag: -H never touches the pane
run_wake claude
check "unconsumed exit" 5 "$RC"
printf '%s\n' "$OUT" | grep -q "backend (claude)" \
  && ok "unconsumed message names the backend" || bad "unconsumed message names the backend" "$OUT"

# 3b. same swallowed-key case for grok — the backend actually named in the
#     issue's real reproduction — proving the new last-line check doesn't
#     overcorrect into never reporting a genuine failure.
reset_stub; touch "$STUB/live"
run_talk grok "do the thing"
check "unconsumed exit (grok)" 5 "$RC"
printf '%s\n' "$OUT" | grep -q "backend (grok)" \
  && ok "unconsumed message names the backend (grok)" || bad "unconsumed message names the backend (grok)" "$OUT"

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

# ---------- issue #58: a static footer below the input line ----------

# 7. THE RED CASE. Submit key never lands, so the text is still sitting in the
#    input line — but a footer is drawn below it, so the text is no longer the
#    pane's physically last line. Before this fix the consumption check read
#    that footer, found no match, and returned success on its FIRST poll:
#    talk role printed STATUS=SENT and exited 0 over a dispatch that was never
#    submitted. A lost talk role is a lost dispatch, and verifying the submit
#    is the entire reason these two scripts exist (issue #14).
reset_stub; touch "$STUB/live" "$STUB/footer"   # no "consume": -H is a no-op
run_talk grok "do the thing"
check "footer + unsubmitted exit" 5 "$RC"
check "footer + unsubmitted status" ERROR "$(val STATUS)"
printf '%s\n' "$OUT" | grep -q "backend (grok)" \
  && ok "footer + unsubmitted names the backend" \
  || bad "footer + unsubmitted names the backend" "$OUT"

# 7b. same through wake-role.sh — both verbs share send_and_verify.
reset_stub; touch "$STUB/live" "$STUB/footer"
run_wake grok
check "footer + unsubmitted exit (wake)" 5 "$RC"

# 8. footer present and the submit DID land: the input line clears, only the
#    footer is left. Must be success — stripping the footer must not leave the
#    check unable to tell "consumed" from "never sent".
reset_stub; touch "$STUB/live" "$STUB/footer" "$STUB/consume"
run_talk grok "do the thing"
check "footer + consumed exit" 0 "$RC"
check "footer + consumed status" SENT "$(val STATUS)"

# 9. footer present AND the text is retained in transcript history with a busy
#    line below it — issue #28's shape as it actually looks on a real Grok
#    pane, footer included. Still success: history above the input line is not
#    an unconsumed message. This is the case that fails if the fix reaches
#    further up the pane instead of just skipping the footer.
reset_stub; touch "$STUB/live" "$STUB/footer" "$STUB/consume" "$STUB/retain"
run_talk grok "do the thing"
check "footer + retained-history exit" 0 "$RC"
check "footer + retained-history status" SENT "$(val STATUS)"
grep -qF "do the thing" "$STUB/pane.txt" \
  && ok "footer + retained-history fixture really kept the text" \
  || bad "footer + retained-history fixture really kept the text" "$(cat "$STUB/pane.txt")"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

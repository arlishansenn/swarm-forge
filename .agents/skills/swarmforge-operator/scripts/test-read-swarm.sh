#!/usr/bin/env bash
# test-read-swarm.sh — end-to-end checks for read-swarm.sh against a stubbed
# tmux. Run: bash scripts/test-read-swarm.sh. Exits non-zero on any failure.
# Local-mode cases run --local (same convention as test-wake-talk.sh), so ssh
# is never invoked there. A remote-mode case (issue #36) below adds a stub
# ssh that actually simulates real ssh's own stdin-forwarding behavior.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
READ=$HERE/read-swarm.sh
WORK=$(mktemp -d /tmp/sf-read-swarm-test.XXXXXX)
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub tmux ----------
# Unlike test-wake-talk.sh's single shared pane.txt, read-swarm.sh reads
# multiple sessions in one run, so capture-pane here keys off the -t
# <session> argument and returns that session's own fixture file — letting
# one test case give two roles different pane content and check both.
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

# ---------- stub ssh (issue #36) ----------
# A naive stub that just logs argv and runs the shipped command (the
# pre-existing test-start-swarm.sh pattern) does NOT reproduce this bug: the
# bug is in real ssh's OWN stdin-forwarding behavior, not in whatever command
# ssh happens to run — tmux capture-pane never reads stdin itself, so a stub
# that skips straight to running the command would pass against the broken
# code too. Real ssh, run non-interactively without -n, still drains and
# forwards whatever is on its own stdin to the remote side even though the
# remote command never asks for it; since the ssh process inherits whatever
# fd 0 the calling shell has open at that moment, an ssh call made from
# inside a `while read ... done <<< "$SESSIONS"` loop drains that loop's own
# here-string on its first invocation, and every subsequent `read -r` in
# that same loop then hits EOF. This stub reproduces exactly that: without
# -n anywhere in argv, it drains its own stdin (`cat >/dev/null`) before
# running the command; with -n, it skips the drain, matching the documented
# behavior "-n: Redirects stdin from /dev/null".
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

reset_stub() { rm -rf "$STUB"; mkdir -p "$STUB/panes"; : > "$STUB/calls.log"; }

# two roles per fixture so every scenario proves independent per-role output,
# not just a single lucky match
ROOT=$WORK/fixtures/twopack
mkdir -p "$ROOT/.swarmforge"
printf '1\tcoder\tswarmforge-coder\tCoder\tcodex\n2\tcleaner\tswarmforge-cleaner\tCleaner\tclaude\n' \
  > "$ROOT/.swarmforge/sessions.tsv"
printf '/tmp/sf-read-swarm.sock\n' > "$ROOT/.swarmforge/tmux-socket"

set_pane() { printf '%s\n' "$2" > "$STUB/panes/$1.txt"; }  # set_pane <session> <last-line>

run() {
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB bash "$READ" --local --root "$ROOT" 2>&1)
  RC=$?
}
role_line() { printf '%s\n' "$OUT" | awk -v r="$1" '$1==r'; }  # role_line <role>

# ---------- remote-mode fixture: 3 sessions, not 2 (issue #36's own
# acceptance criteria: "防止只修成恰好读取两项" — a fix that happens to
# survive exactly two rows but not N would slip through a 2-row test) -------
ROOT3=$WORK/fixtures/threepack
mkdir -p "$ROOT3/.swarmforge"
printf '1\tcoder\tswarmforge-coder\tCoder\tcodex\n2\tcleaner\tswarmforge-cleaner\tCleaner\tclaude\n3\treviewer\tswarmforge-reviewer\tReviewer\tclaude\n' \
  > "$ROOT3/.swarmforge/sessions.tsv"
printf '/tmp/sf-read-swarm-remote.sock\n' > "$ROOT3/.swarmforge/tmux-socket"

run_remote() {
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB \
    bash "$READ" --target test-target --key /dev/null --root "$ROOT3" 2>&1)
  RC=$?
}

echo "== RED/GREEN suite for read-swarm.sh =="

if [ ! -f "$READ" ]; then
  echo "script missing — RED confirmed, all cases fail"; exit 1
fi

# 1. explicit idle text (codex placeholder, claude bare prompt) → IDLE, both
#    roles carry their own pane text
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder   '› Ask Codex to do anything'
set_pane swarmforge-cleaner '❯'
run
check "idle exit" 0 "$RC"
check "idle status" READ "$(printf '%s\n' "$OUT" | head -1 | sed -n 's/^STATUS=//p')"
printf '%s\n' "$(role_line coder)"   | grep -q 'IDLE.*Ask Codex to do anything' \
  && ok "coder idle carries pane text"   || bad "coder idle carries pane text" "$(role_line coder)"
printf '%s\n' "$(role_line cleaner)" | grep -qE 'IDLE.*❯' \
  && ok "cleaner idle carries pane text" || bad "cleaner idle carries pane text" "$(role_line cleaner)"

# 2. explicit busy text (codex "esc to interrupt", claude spinner shape) → BUSY
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder   'Working (44s • esc to interrupt)'
set_pane swarmforge-cleaner '✳ Baked for 13s'
run
check "busy exit" 0 "$RC"
printf '%s\n' "$(role_line coder)"   | grep -q 'BUSY.*Working (44s' \
  && ok "coder busy carries pane text"   || bad "coder busy carries pane text" "$(role_line coder)"
printf '%s\n' "$(role_line cleaner)" | grep -q 'BUSY.*Baked for 13s' \
  && ok "cleaner busy carries pane text" || bad "cleaner busy carries pane text" "$(role_line cleaner)"

# 3. blank pane → UNKNOWN, never IDLE (the whole point of this ticket), and
#    still carries a note in place of pane output
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder   ''
set_pane swarmforge-cleaner ''
run
check "blank exit" 0 "$RC"
printf '%s\n' "$(role_line coder)" | grep -q 'UNKNOWN' \
  && ok "blank pane classifies UNKNOWN, not IDLE" || bad "blank pane classifies UNKNOWN, not IDLE" "$(role_line coder)"
printf '%s\n' "$(role_line coder)" | grep -qi 'blank pane' \
  && ok "blank pane still carries an output note"   || bad "blank pane still carries an output note" "$(role_line coder)"
printf '%s\n' "$(role_line cleaner)" | grep -qi 'blank pane' \
  && ok "second role's blank pane also carries a note" || bad "second role's blank pane also carries a note" "$(role_line cleaner)"

# 4. unrecognized error text → UNKNOWN, raw text still attached (no guessing
#    at agent-specific error states, per the issue's boundary)
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder   '⚠ rate limit reached, retrying in 43s'
set_pane swarmforge-cleaner 'Error: connection reset by peer'
run
check "unrecognized-error exit" 0 "$RC"
printf '%s\n' "$(role_line coder)" | grep -q 'UNKNOWN.*rate limit reached' \
  && ok "coder error text classifies UNKNOWN with pane text"   || bad "coder error text classifies UNKNOWN with pane text" "$(role_line coder)"
printf '%s\n' "$(role_line cleaner)" | grep -q 'UNKNOWN.*connection reset by peer' \
  && ok "cleaner error text classifies UNKNOWN with pane text" || bad "cleaner error text classifies UNKNOWN with pane text" "$(role_line cleaner)"

# 5. socket has no tmux server → exit 3, never mistaken for idle/busy output
reset_stub  # no "live" flag
run
check "no-server exit" 3 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=STOPPED$' \
  && ok "no-server status is STOPPED" || bad "no-server status is STOPPED" "$OUT"

# 6. never sends keys — read swarm is a report verb (CONTEXT.md), it must
#    call only list-sessions/capture-pane
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder   'Working (5s • esc to interrupt)'
set_pane swarmforge-cleaner '❯'
run
! grep -q 'send-keys' "$STUB/calls.log" \
  && ok "read swarm never calls send-keys" || bad "read swarm never calls send-keys" "$(cat "$STUB/calls.log")"

# 7. remote mode, 3+ sessions (issue #36): a caller ssh's own default
#    stdin-forwarding must not drain the loop's here-string and truncate the
#    report — every role must appear, in sessions.tsv order.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder    '❯'
set_pane swarmforge-cleaner  '❯'
set_pane swarmforge-reviewer '❯'
run_remote
check "remote 3-role exit" 0 "$RC"
for r in coder cleaner reviewer; do
  [ -n "$(role_line "$r")" ] \
    && ok "remote: role $r present in report" || bad "remote: role $r present in report" "$OUT"
done
ORDER=$(printf '%s\n' "$OUT" | awk '$1=="coder"||$1=="cleaner"||$1=="reviewer"{print $1}' | tr '\n' ' ')
check "remote 3-role order matches sessions.tsv" "coder cleaner reviewer " "$ORDER"

# ---------- issue #58: Grok renders a static footer BELOW the prompt ----------
# Both fixtures are the real shapes captured off podsum, verbatim. What makes
# them worth encoding is that the physically last non-empty line is the SAME
# footer in both, while the roles are in opposite states — so any reader that
# ends at `tail -1` cannot tell them apart, and reported UNKNOWN for every
# Grok role. `stop swarm` shares this judgment, which turned its safety gate
# into a formality that always needed --force.

# 8. idle Grok pane: content above the prompt, footer below it → IDLE.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder 'Worked for 2m56s / minimal · /help
❯
Grok 4.6 (high) · always-approve · 93K / 500K (19%) · ctrl+o transcript'
run
check "grok idle exit" 0 "$RC"
printf '%s\n' "$(role_line coder)" | grep -q 'IDLE' \
  && ok "grok idle pane classifies IDLE, not UNKNOWN" \
  || bad "grok idle pane classifies IDLE, not UNKNOWN" "$(role_line coder)"
printf '%s\n' "$(role_line coder)" | grep -qv 'ctrl+o transcript' \
  && ok "grok idle report names the deciding line, not the footer" \
  || bad "grok idle report names the deciding line, not the footer" "$(role_line coder)"

# 9. busy Grok pane: the spinner sits ABOVE the prompt, which is still drawn
#    empty, with the footer below both. Reading upward and stopping at the
#    first classifiable line would find the empty prompt and report IDLE on a
#    role that is mid-request — BUSY has to win over IDLE within the window.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder '⠙ Waiting for response… 0.0s … 48s ⇣74.6k
❯
Grok 4.6 (high) · always-approve · 74K / 500K (15%) · ctrl+o transcript'
run
check "grok busy exit" 0 "$RC"
printf '%s\n' "$(role_line coder)" | grep -q 'BUSY' \
  && ok "grok busy pane classifies BUSY, not IDLE" \
  || bad "grok busy pane classifies BUSY, not IDLE" "$(role_line coder)"

# 10. the two shapes above share their last non-empty line. This asserts the
#     premise directly, so a future reader cannot mistake cases 8 and 9 for
#     two unrelated fixtures that happen to differ.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder '⠙ Waiting for response… 0.0s … 48s ⇣74.6k
❯
Grok 4.6 (high) · always-approve · 74K / 500K (15%) · ctrl+o transcript'
set_pane swarmforge-cleaner 'Worked for 2m56s / minimal · /help
❯
Grok 4.6 (high) · always-approve · 93K / 500K (19%) · ctrl+o transcript'
run
printf '%s\n' "$(role_line coder)"   | grep -q 'BUSY' \
  && printf '%s\n' "$(role_line cleaner)" | grep -q 'IDLE' \
  && ok "two Grok roles with the same last line classify differently" \
  || bad "two Grok roles with the same last line classify differently" "$OUT"

# 11. a footer with nothing above it is still not a state. UNKNOWN must not
#     become IDLE just because the footer was skipped and the window emptied.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder 'Grok 4.6 (high) · always-approve · 93K / 500K (19%) · ctrl+o transcript'
run
check "footer-only exit" 0 "$RC"
printf '%s\n' "$(role_line coder)" | grep -q 'UNKNOWN' \
  && ok "footer-only pane stays UNKNOWN" \
  || bad "footer-only pane stays UNKNOWN" "$(role_line coder)"

# 12. the footer pattern only ever strips TRAILING lines. The same string
#     inside transcript history is content, and must not shift which line is
#     read as the input line.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder 'someone pasted ctrl+o transcript into the chat
❯
Grok 4.6 (high) · always-approve · 93K / 500K (19%) · ctrl+o transcript'
run
printf '%s\n' "$(role_line coder)" | grep -q 'IDLE' \
  && ok "footer text quoted in history does not shift the input line" \
  || bad "footer text quoted in history does not shift the input line" "$(role_line coder)"

# ---------- issue #92: Grok's spinner has more than one wording ----------
# `Waiting for response…` was in BUSY_RE; `Thinking…` and `Responding…` were
# not, and neither matches the other two alternatives — no `esc to interrupt`,
# and `Thinking… 1.4s` has no ` for ` so the `<participle> for Ns` shape misses
# it. Nothing matched BUSY, the empty prompt right below matched IDLE, and a
# role mid-request read IDLE. Seen live on coder2's pi-governance: six roles
# all reported IDLE while specifier was `Responding…` and coder was
# `Thinking…`.
#
# This one points the WRONG WAY compared with issue #58. That one made every
# Grok role read UNKNOWN — annoying, but safe. This one reads IDLE, and
# `stop swarm` shares the judgment: a green preflight, a kill-session, and no
# warning that live work was interrupted.

# 10. a Grok role that is Thinking… is BUSY, not IDLE.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder '⠦ Thinking… 1.4s                                        1m46s ⇣93.2k
❯
Grok 4.6 (high) · always-approve · 93K / 500K (19%) · ctrl+o transcript'
set_pane swarmforge-cleaner '❯'
run
check "grok thinking exit" 0 "$RC"
printf '%s\n' "$(role_line coder)" | grep -q 'BUSY' \
  && ok "Thinking… reads BUSY" || bad "Thinking… reads BUSY" "$(role_line coder)"

# 11. and so is Responding….
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder '⠧ Responding… 5.7s
❯
Grok 4.6 (high) · always-approve · 97K / 500K (20%) · ctrl+o transcript'
set_pane swarmforge-cleaner '❯'
run
printf '%s\n' "$(role_line coder)" | grep -q 'BUSY' \
  && ok "Responding… reads BUSY" || bad "Responding… reads BUSY" "$(role_line coder)"

# 12. the footer has more than one shape too. With something queued it gains
#     `· 1 queued · /queue` and LOSES the trailing `transcript`, so a footer
#     pattern that required that word stopped dropping it — and the dropped
#     line is what the classifier's window depends on. Same failure as #58,
#     reached by a different route.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder '⠦ Thinking… 1.4s
❯
Grok 4.6 (high) · always-approve · 97K / 500K (20%) · 1 queued · /queue · ctrl+o'
set_pane swarmforge-cleaner '❯'
run
printf '%s\n' "$(role_line coder)" | grep -q 'BUSY' \
  && ok "queued-footer variant still reaches the spinner line" \
  || bad "queued-footer variant still reaches the spinner line" "$(role_line coder)"

# 13. an idle Grok role under the queued-footer variant is still IDLE — the
#     widened footer pattern must not turn every Grok role BUSY instead.
reset_stub; touch "$STUB/live"
set_pane swarmforge-coder 'Worked for 2m56s / minimal · /help
❯
Grok 4.6 (high) · always-approve · 97K / 500K (20%) · 1 queued · /queue · ctrl+o'
set_pane swarmforge-cleaner '❯'
run
printf '%s\n' "$(role_line coder)" | grep -q 'IDLE' \
  && ok "queued-footer idle pane still reads IDLE" \
  || bad "queued-footer idle pane still reads IDLE" "$(role_line coder)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

# lib-wake-talk.sh — send-then-verify logic shared by wake-role.sh and
# talk-role.sh (issue #14: a mismatched backend must fail loudly, not send
# keys into the void). read-swarm.sh (issue #15) also sources this file, but
# only for the die/read_file/tmux_remote plumbing — it never calls
# resolve_role or send_and_verify, since a report verb never sends keys.
# Sourced, never executed directly.
#
# Callers must set ROOT, TARGET, KEY, LOCAL before sourcing, and SOCK after
# resolving it. Provides: die, read_file, tmux_remote, resolve_role,
# send_and_verify.

die() { printf 'STATUS=%s\n%s\n' "$1" "$2"; exit "${3:-5}"; }

read_file() { # $1 = path under ROOT
  if [ "$LOCAL" = 1 ]; then cat "$ROOT/$1"
  else ssh -i "$KEY" "$TARGET" "cat '$ROOT/$1'"; fi
}

# Runs tmux on the target with argv passed through untouched, never a
# hand-built remote string. LOCAL execs tmux directly (no shell in the
# middle, so nothing needs escaping). Remote mode still has to cross an ssh
# exec, which joins its trailing arguments into one string for the remote
# shell to reparse — so each argument is %q-quoted before joining, which is
# what actually stops free text (talk role's message) from breaking out,
# rather than hoping raw argv survives the hop unquoted.
tmux_remote() {
  if [ "$LOCAL" = 1 ]; then
    tmux -S "$SOCK" "$@"
  else
    local cmd a
    cmd=$(printf '%q' tmux)$(printf ' %q' -S "$SOCK" "$@")
    ssh -i "$KEY" "$TARGET" "$cmd"
  fi
}

# Looks up $1 in sessions.tsv (columns: index, role, session, display,
# agent). Sets SESSION/AGENT on success; returns 1 if the role has no row —
# never accepts backend from the caller, sessions.tsv is the only source.
resolve_role() {
  local row
  row=$(printf '%s\n' "$SESSIONS" | awk -F'\t' -v r="$1" '$2 == r {print $3"\t"$5; exit}')
  [ -n "$row" ] || return 1
  SESSION=${row%%$'\t'*}
  AGENT=${row#*$'\t'}
}

# Timeout budgets (overridable for tests, same trick as handoffd.bb's
# SWARMFORGE_WAKE_RETRY_MS): arrival is typing landing in the input line,
# which is near-instant once the pane exists, so a few seconds covers normal
# jitter. Consumption is the submit key actually being processed — an agent
# mid-thought can leave keystrokes queued in the terminal buffer for longer,
# so that budget runs three times as long.
ARRIVAL_TRIES=${SF_ARRIVAL_TRIES:-10}
ARRIVAL_INTERVAL=${SF_ARRIVAL_INTERVAL:-0.3}
CONSUME_TRIES=${SF_CONSUME_TRIES:-20}
CONSUME_INTERVAL=${SF_CONSUME_INTERVAL:-0.5}

pane_has() { tmux_remote capture-pane -p -t "$SESSION" | grep -qF -- "$1"; }

# Type $1, confirm it arrived, submit with the backend's own key encoding
# (never symbolic C-m/C-j — see submit-keys in handoffd.bb), then confirm
# the input line no longer holds it. Dies ERROR/5 on either failure to wait.
send_and_verify() {
  local text=$1 i
  tmux_remote send-keys -t "$SESSION" -l "$text"
  for ((i = 0; i < ARRIVAL_TRIES; i++)); do
    pane_has "$text" && break
    sleep "$ARRIVAL_INTERVAL"
  done
  pane_has "$text" || die ERROR \
    "text never appeared in $SESSION's input line; check the tmux session is alive" 5

  if [ "$AGENT" = claude ]; then
    tmux_remote send-keys -t "$SESSION" -H 1b 5b 31 33 75
  else
    tmux_remote send-keys -t "$SESSION" -H 0d
  fi

  for ((i = 0; i < CONSUME_TRIES; i++)); do
    pane_has "$text" || return 0
    sleep "$CONSUME_INTERVAL"
  done
  die ERROR \
    "text reached $SESSION's input line but was never submitted — check sessions.tsv's backend ($AGENT) against the agent actually running in that session" 5
}

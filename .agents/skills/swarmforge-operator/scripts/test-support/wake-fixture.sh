#!/usr/bin/env bash
# Shared wake/talk runtime; no host or real role is accessed.
setup_real() {
  FIXTURE=$(mktemp -d "$WORK/role.XXXXXX")
  case "$VERB" in
    wake-role) REAL_MESSAGE='ready_for_next.sh' ;;
    talk-role) REAL_MESSAGE='please inspect "two files" without $(touch unwanted) *' ;;
    *) return 1 ;;
  esac
  REAL_ROOT="$FIXTURE/forge/projects/demo with spaces"
  mkdir -p "$REAL_ROOT/.swarmforge" "$FIXTURE/bin" "$FIXTURE/stub"
  : > "$FIXTURE/forge/swarm"
  : > "$FIXTURE/stub/pane.txt"
  : > "$FIXTURE/stub/calls.log"
  printf '1\tcoder\tswarmforge-coder\tCoder Display\tgrok\n' > "$REAL_ROOT/.swarmforge/sessions.tsv"
  printf '%s\n' "$FIXTURE/socket" > "$REAL_ROOT/.swarmforge/tmux-socket"
  # Grok's observed redraw (issue #28 + #58): submitted text stays in history,
  # a busy line lands below it, and a footer without the word "transcript"
  # (the queued shape from issue #92) is painted under the input line.
  cat > "$FIXTURE/bin/tmux" <<'SH'
#!/usr/bin/env bash
# Every accepted shape is spelled out: a call this stub merely tolerates is a
# production change the assertions below would never see.
STUB=${WAKE_FIXTURE:?}/stub
SESSION=swarmforge-coder
reject() { printf 'tmux %s\n' "$*" >> "$WAKE_FIXTURE/blocked"; exit 97; }
printf 'tmux %s\n' "$*" >> "$STUB/calls.log"
[ $# -ge 3 ] && [ "$1" = -S ] && [ "$2" = "${WAKE_FIXTURE}/socket" ] || reject "$@"
shift 2
case $1 in
  list-sessions) [ $# = 1 ] || reject "$@"; exit 0 ;;
  send-keys)
    [ $# = 5 ] && [ "$2" = -t ] && [ "$3" = "$SESSION" ] || reject "$@"
    case $4 in
      -l)
        printf '%s' "$5" > "$STUB/typed.txt"
        printf '%s' "$5" >> "$STUB/pane.txt"
        ;;
      -H)
        [ "$5" = 0d ] || reject "$@"
        if [ ! -f "$STUB/no-consume" ]; then
          printf '\nWaiting for response…\n' >> "$STUB/pane.txt"
        fi
        ;;
      *) reject "$@" ;;
    esac
    exit 0 ;;
  capture-pane)
    { [ $# = 4 ] || { [ $# = 6 ] && [ "$5" = -S ] && [ "$6" = -12 ]; }; } || reject "$@"
    [ "$2" = -p ] && [ "$3" = -t ] && [ "$4" = "$SESSION" ] || reject "$@"
    # One small write: grep -q can close the pipe after it sees the input.
    capture=$(cat "$STUB/pane.txt")
    printf '%s\n%s\n' "$capture" 'Grok 4.6 (high) · 93K / 500K (19%) · ctrl+o · 1 queued · /queue'
    exit 0 ;;
esac
reject "$@"
SH
  local cmd
  for cmd in ssh curl cmux gh git tailscale; do
    printf '#!/bin/bash\nprintf "%%s\\n" "$(basename "$0")" >> "$WAKE_FIXTURE/blocked"\nexit 97\n' > "$FIXTURE/bin/$cmd"
  done
  chmod +x "$FIXTURE/bin/"*
  # Same override trick the existing wake/talk suite uses: real budgets would
  # make every poll a real sleep.
  REAL_ENV=("PATH=$FIXTURE/bin:$PATH" "WAKE_FIXTURE=$FIXTURE"
    SF_ARRIVAL_TRIES=3 SF_ARRIVAL_INTERVAL=0.01
    SF_CONSUME_TRIES=3 SF_CONSUME_INTERVAL=0.01)
  REAL_ARGS=(--root "$REAL_ROOT" --role coder --local)
  if [ "$VERB" = talk-role ]; then REAL_ARGS+=(--message "$REAL_MESSAGE"); fi
}
assert_real() {
  check 'role reported' coder "$(field ROLE)"
  check 'session comes from sessions.tsv' swarmforge-coder "$(field SESSION)"
  printf '%s' "$REAL_MESSAGE" > "$FIXTURE/expected-text"
  check 'message bytes reached the resolved session' yes \
    "$(cmp -s "$FIXTURE/expected-text" "$FIXTURE/stub/typed.txt" && echo yes || echo no)"
  check 'submitted text remains in history' yes \
    "$(grep -qF -- "$REAL_MESSAGE" "$FIXTURE/stub/pane.txt" && echo yes || echo no)"
  check 'submitted with the backend key from sessions.tsv' yes \
    "$(grep -qF 'send-keys -t swarmforge-coder -H 0d' "$FIXTURE/stub/calls.log" && echo yes || echo no)"
  check 'no symbolic submit key' yes \
    "$(grep -Eq '(^| )(C-m|C-j)( |$)' "$FIXTURE/stub/calls.log" && echo no || echo yes)"
  check 'runtime gate ran before typing' yes \
    "$(awk '/list-sessions/ && !g {g = NR} /send-keys .* -l / && !t {t = NR}
        END {print (g && t && g < t) ? "yes" : "no"}' "$FIXTURE/stub/calls.log")"
  check 'no fake result' no "$(grep -q '^ADAPTER=fake$' "$WORK/err" && echo yes || echo no)"

  # A successful redraw alone cannot prove that the queued footer is skipped.
  : > "$FIXTURE/stub/pane.txt"
  : > "$FIXTURE/stub/no-consume"
  local rc=0
  env "${REAL_ENV[@]}" SF_ADAPTER=real "$ENTRY" "${REAL_ARGS[@]}" \
    > "$FIXTURE/unconsumed.out" 2> "$FIXTURE/unconsumed.err" || rc=$?
  check 'queued footer cannot hide unconsumed input' 5 "$rc"
  check 'unconsumed input status' STATUS=ERROR "$(head -1 "$FIXTURE/unconsumed.out")"
  check 'failure is submission, not arrival' yes \
    "$(grep -qF 'but was never submitted' "$FIXTURE/unconsumed.out" && echo yes || echo no)"
  check 'no unexpected external operation' yes "$([ ! -e "$FIXTURE/blocked" ] && echo yes || echo no)"
}
cleanup_real() { :; }

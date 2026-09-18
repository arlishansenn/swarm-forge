#!/usr/bin/env bash
# Shared contract assertions; real adapters run only in local fixtures.
set -u
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sf-verb-test.XXXXXX")
cleanup() {
  if declare -F cleanup_real >/dev/null; then cleanup_real; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
PASS=0 FAIL=0
REAL_STATE=pending
ENTRY="$HERE/verb-$VERB"

check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
  fi
}
run_entry() {
  RC=0
  "$@" > "$WORK/out" 2> "$WORK/err" || RC=$?
}
field() {
  awk -v key="$1" 'index($0,key "=")==1 {print substr($0,length(key)+2); exit}
    index($0,key ": ")==1 {print substr($0,length(key)+3); exit}' "$WORK/out"
}
assert_contract() {
  check 'success exit' 0 "$RC"
  check 'first stdout line' "STATUS=$EXPECTED_STATUS" "$(head -n 1 "$WORK/out")"
  local key value
  for key in $FIELDS; do
    value=$(field "$key")
    check "$key present" yes "$([ -n "$value" ] && echo yes || echo no)"
  done
  if [ "$VERB" = open-swarm ]; then
    value=$(field ATTACHED)
    check 'at least one session attached' yes "$([[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ] && echo yes || echo no)"
    check 'no failed attachments' 0 "$(field FAILED)"
  fi
}

if [ ! -x "$ENTRY" ]; then
  check 'verb entry is executable' yes no
  printf 'PASS=%s FAIL=%s real=pending\n' "$PASS" "$FAIL"
  exit 1
fi
# Real integration fixtures are added one verb at a time, never run against a host by accident.
case ${SF_ADAPTER-fake} in
  fake) ;;
  real) declare -F setup_real >/dev/null || { printf 'real fixture pending for %s\n' "$VERB" >&2; exit 2; } ;;
  *) printf 'test adapter must be fake or real\n' >&2; exit 2 ;;
esac

mkdir -p "$WORK/bin"
export BLOCKED_CALLS="$WORK/blocked"
for cmd in ssh cmux tmux curl git gh; do
  printf '#!/bin/bash\nprintf "called\\n" >> "$BLOCKED_CALLS"\nexit 97\n' > "$WORK/bin/$cmd"
  chmod +x "$WORK/bin/$cmd"
done
ROOT="$WORK/missing root"
run_entry env PATH="$WORK/bin:$PATH" SF_ADAPTER=fake "$ENTRY" --root "$ROOT" --local
assert_contract
check 'fake is explicit on stderr' ADAPTER=fake "$(cat "$WORK/err")"
check 'root stays absent' yes "$([ ! -e "$ROOT" ] && echo yes || echo no)"
check 'no external calls' yes "$([ ! -e "$BLOCKED_CALLS" ] && echo yes || echo no)"
cp "$WORK/out" "$WORK/fixed-output"
run_entry env PATH="$WORK/bin:$PATH" SF_ADAPTER=fake "$ENTRY" --root "$WORK/another missing root"
check 'fixed sample exit' 0 "$RC"
check 'sample does not depend on arguments' yes "$(cmp -s "$WORK/fixed-output" "$WORK/out" && echo yes || echo no)"
if declare -F setup_real >/dev/null; then
  setup_real || exit 1
  run_entry env "${REAL_ENV[@]}" SF_ADAPTER=real "$ENTRY" "${REAL_ARGS[@]}"
  assert_contract
  assert_real
  cleanup_real
  REAL_STATE=tested
fi
if [ "${DEFAULT_ADAPTER:-fake}" = real ]; then
  setup_real || exit 1
  run_entry env -u SF_ADAPTER "${REAL_ENV[@]}" "$ENTRY" "${REAL_ARGS[@]}"
  assert_contract
  assert_real
  cleanup_real
else
  run_entry env -u SF_ADAPTER PATH="$WORK/bin:$PATH" "$ENTRY" --root "$ROOT"
  assert_contract
  check 'skeleton defaults to fake' ADAPTER=fake "$(cat "$WORK/err")"
fi

# A copy keeps failure and pass-through probes away from installed adapters.
COPY="$WORK/copied scripts"
mkdir -p "$COPY/fakes"
cp "$ENTRY" "$COPY/verb-$VERB"
cp "$HERE/fakes/$VERB.sh" "$COPY/fakes/$VERB.sh"
ENTRY="$COPY/verb-$VERB"
run_entry env SF_ADAPTER='fake;exit 0' "$ENTRY"
check 'unknown adapter exit' 2 "$RC"
check 'unknown adapter status' STATUS=USAGE "$(head -n 1 "$WORK/out")"
check 'unknown adapter did not call fake' '' "$(cat "$WORK/err")"
run_entry env SF_ADAPTER= "$ENTRY"
check 'empty selector is not the default' 2 "$RC"
check 'empty selector status' STATUS=USAGE "$(head -n 1 "$WORK/out")"
run_entry env SF_ADAPTER=real "$ENTRY"
check 'missing real exit' 5 "$RC"
check 'missing real status' STATUS=ERROR "$(head -n 1 "$WORK/out")"
check 'missing real did not fall back' '' "$(cat "$WORK/err")"

export RECEIVED_ARGS="$WORK/received-args"
cat > "$COPY/$REAL_SCRIPT" <<'SH'
#!/bin/bash
printf '%s\0' "$@" > "$RECEIVED_ARGS"
printf 'STATUS=ERROR\nprobe output\n'
printf 'probe stderr\n' >&2
exit 23
SH
chmod -x "$COPY/$REAL_SCRIPT"
run_entry env SF_ADAPTER=real "$ENTRY"
check 'non-executable real exit' 5 "$RC"
check 'non-executable real status' STATUS=ERROR "$(head -n 1 "$WORK/out")"
check 'non-executable real not invoked' yes "$([ ! -e "$RECEIVED_ARGS" ] && echo yes || echo no)"
chmod +x "$COPY/$REAL_SCRIPT"
ARGS=(--root 'a root with spaces' '' '*' '--message' $'line one\nline two' '$(touch unwanted)')
printf '%s\0' "${ARGS[@]}" > "$WORK/expected-args"
printf 'STATUS=ERROR\nprobe output\n' > "$WORK/expected-out"
printf 'probe stderr\n' > "$WORK/expected-err"
run_entry env SF_ADAPTER=real "$ENTRY" "${ARGS[@]}"
check 'real exit is preserved' 23 "$RC"
check 'argv boundaries preserved' yes "$(cmp -s "$WORK/expected-args" "$RECEIVED_ARGS" && echo yes || echo no)"
check 'stdout bytes preserved' yes "$(cmp -s "$WORK/expected-out" "$WORK/out" && echo yes || echo no)"
check 'stderr bytes preserved, no fake fallback' yes "$(cmp -s "$WORK/expected-err" "$WORK/err" && echo yes || echo no)"
rm "$COPY/fakes/$VERB.sh"
run_entry env SF_ADAPTER=fake "$ENTRY"
check 'missing fake exit' 5 "$RC"
check 'missing fake status' STATUS=ERROR "$(head -n 1 "$WORK/out")"

printf 'PASS=%s FAIL=%s real=%s\n' "$PASS" "$FAIL" "$REAL_STATE"
[ "$FAIL" -eq 0 ]

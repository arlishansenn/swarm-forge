#!/usr/bin/env bash
# Real local git transport; gh is a recorder, never a GitHub client.
setup_real() {
  FIXTURE=$(mktemp -d "$WORK/ship.XXXXXX")
  REAL_ROOT="$FIXTURE/forge/projects/demo"
  mkdir -p "$REAL_ROOT" "$FIXTURE/bin" "$FIXTURE/home"
  : > "$FIXTURE/forge/swarm"
  # Keep the fixture independent of user hooks, signing and URL rewrites.
  # -u first: git -C cannot override an inherited GIT_DIR, so a caller with one
  # set would send this fixture's init/commit into their own repository.
  REAL_ENV=(-u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE
    "HOME=$FIXTURE/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    GIT_CONFIG_COUNT=0 GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0
    GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
    "PATH=$FIXTURE/bin:$PATH" "SHIP_FIXTURE=$FIXTURE")
  env "${REAL_ENV[@]}" git init --quiet --bare "$FIXTURE/origin.git" || return 1
  env "${REAL_ENV[@]}" git -C "$REAL_ROOT" init --quiet || return 1
  env "${REAL_ENV[@]}" git -C "$REAL_ROOT" remote add origin "$FIXTURE/origin.git" || return 1
  printf '/.swarmforge/\n/.worktrees/\n' > "$REAL_ROOT/.gitignore"
  printf 'base\n' > "$REAL_ROOT/product.txt"
  env "${REAL_ENV[@]}" git -C "$REAL_ROOT" add . || return 1
  env "${REAL_ENV[@]}" git -C "$REAL_ROOT" -c commit.gpgsign=false commit --quiet -m base || return 1
  env "${REAL_ENV[@]}" git -C "$REAL_ROOT" branch -M main || return 1
  env "${REAL_ENV[@]}" git -C "$REAL_ROOT" push --quiet origin main || return 1
  printf 'delivered work\n' >> "$REAL_ROOT/product.txt"
  env "${REAL_ENV[@]}" git -C "$REAL_ROOT" add product.txt || return 1
  env "${REAL_ENV[@]}" git -C "$REAL_ROOT" -c commit.gpgsign=false commit --quiet -m work || return 1
  SHIP_COMMIT=$(env "${REAL_ENV[@]}" git -C "$REAL_ROOT" rev-parse HEAD) || return 1
  mkdir -p "$REAL_ROOT/.swarmforge/board" "$REAL_ROOT/.swarmforge/handoffs/inbox/completed"
  printf 'coder\tmaster\t%s\tsession\tCoder\tcodex\tpush\n' "$REAL_ROOT" > "$REAL_ROOT/.swarmforge/roles.tsv"
  printf 'delivered-task\tdone\t2026-09-18T00:00:00Z\t2026-09-18T00:00:00Z\tdelivered-task\t0\tutility\n' > "$REAL_ROOT/.swarmforge/board/tasks.tsv"
  cat > "$REAL_ROOT/.swarmforge/handoffs/inbox/completed/delivery.handoff" <<EOF
id: delivery
from: cleaner
to: coder
type: git_handoff
task: delivered-task
commit: $SHIP_COMMIT
completed_at: 2026-09-18T00:00:00Z
non-forwarding: true

Delivered work.
EOF
  printf 'Changes verified in an isolated fixture.\n' > "$FIXTURE/body.md"
  cat > "$FIXTURE/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
p = Path(os.environ['SHIP_FIXTURE'])
args = sys.argv[1:]
with (p / 'gh.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
if args[:2] == ['pr', 'list']:
    sys.exit(0)
if args[:2] == ['pr', 'create']:
    (p / 'created.json').write_text(json.dumps(args))
    print('https://example.invalid/fixture/pull/7')
    sys.exit(0)
sys.exit(97)
PY
  for cmd in ssh curl cmux tmux tailscale; do
    printf '#!/bin/bash\nprintf "blocked\\n" >> "$SHIP_FIXTURE/blocked"\nexit 97\n' > "$FIXTURE/bin/$cmd"
  done
  chmod +x "$FIXTURE/bin/"*
  REAL_ARGS=(--root "$REAL_ROOT" --local --base main --branch feat/fixture-ship --issue 42 --body-file "$FIXTURE/body.md")
}
assert_real() {
  check 'published URL comes from gh' https://example.invalid/fixture/pull/7 "$(field url)"
  check 'push diagnostics retained on stderr' yes "$(grep -Fq "$FIXTURE/origin.git" "$WORK/err" && echo yes || echo no)"
  check 'local origin received delivered commit' "$SHIP_COMMIT" "$(env "${REAL_ENV[@]}" git --git-dir="$FIXTURE/origin.git" rev-parse --verify refs/heads/feat/fixture-ship 2>/dev/null)"
  check 'working checkout stayed on main' main "$(env "${REAL_ENV[@]}" git -C "$REAL_ROOT" branch --show-current)"
  local verified
  verified=$(python3 - "$FIXTURE" <<'PY'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1])
f = p / 'gh.jsonl'
calls = [json.loads(line) for line in f.read_text().splitlines()] if f.exists() else []
creates = [args for args in calls if args[:2] == ['pr', 'create']]
valid = False
if len(creates) == 1:
    args = creates[0]
    def value(key):
        return args[args.index(key) + 1] if key in args else ''
    body = value('--body')
    valid = (value('--head') == 'feat/fixture-ship' and value('--base') == 'main'
             and 'Changes verified in an isolated fixture.' in body
             and 'Closes #42' in body and 'delivered-task' in body)
print('yes' if valid else 'no')
PY
)
  check 'one PR create carries prose, issue and delivery' yes "$verified"
  check 'no fake result' no "$(grep -q '^ADAPTER=fake$' "$WORK/err" && echo yes || echo no)"
  check 'no external operation' yes "$([ ! -e "$FIXTURE/blocked" ] && echo yes || echo no)"
}
cleanup_real() { :; }

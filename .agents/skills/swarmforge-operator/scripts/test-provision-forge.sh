#!/usr/bin/env bash
# test-provision-forge.sh — checks for provision-forge.sh (issue #144).
# Run: bash scripts/test-provision-forge.sh. Exits non-zero on any failure.
#
# Two things here are real rather than stubbed, on purpose:
#
# - The DASHBOARD is a real HTTP server (python3, below), so the POST path
#   exercises real curl, real JSON and real status codes. A curl stub would
#   have let a malformed body or a misparsed status code pass, and the body
#   shape is precisely what the production pack_web endpoint contracts on.
# - start-swarm.sh is invoked for REAL, against the stub tmux and a fake
#   launcher (the same SWARM_LAUNCHER seam test-start-swarm.sh uses). The
#   delegation is the point of the verb; asserting on an argv string would
#   prove nothing about it.
#
# Only the network is faked: the helper comes from a file:// URL pointing at a
# fake get-swarm-forge, which is also what lets a test decide what an
# "installed" tree contains (this fork's markers, or upstream's lack of them).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PROVISION=$HERE/provision-forge.sh
[ -x "$PROVISION" ] || { echo "missing $PROVISION"; exit 1; }
WORK=$(mktemp -d /tmp/sf-provision-forge-test.XXXXXX)
trap 'cleanup' EXIT
PASS=0 FAIL=0
SERVER_PID=''

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub tmux: a flag file gates list-sessions, so a test controls
# liveness with no tmux server anywhere. Same shape as test-start-swarm.sh's.
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
export PATH=$WORK/bin:$PATH
export STUB=$WORK/stub

# ---------- fake launcher: what start-swarm.sh detaches. Writes the runtime
# files a real `./swarm` would, so the readiness polls in BOTH scripts have
# something true to observe, and records that it ran at all — which is how the
# source-check test proves the launcher was never reached.
cat > "$WORK/fakeswarm" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
ROOT=${FAKE_ROOT:?}
echo launched >> "$STUB/launched"
mkdir -p "$ROOT/.swarmforge"
printf '%s\n' "$STUB/sock" > "$ROOT/.swarmforge/tmux-socket"
touch "$STUB/live"
[ -n "${FAKE_DASHBOARD_URL:-}" ] && printf '%s\n' "$FAKE_DASHBOARD_URL" > "$ROOT/.swarmforge/dashboard-url"
exit 0
EOF
chmod +x "$WORK/fakeswarm"

# ---------- fake get-swarm-forge, reached over file:// ----------
# $FAKE_INSTALL_MODE decides what lands: a fork tree, an upstream tree (no
# markers), or a failure part-way through.
cat > "$WORK/get-swarm-forge-fake" <<'EOF'
#!/usr/bin/env bash
set -eu
STUB=${STUB:?}
echo "$1" >> "$STUB/installs"
mkdir -p swarmforge/scripts projects packs/two-pack
printf 'reconcile-once! placeholder\n' > swarmforge/scripts/handoffd.bb
printf 'roles.tsv placeholder\n' > swarmforge/scripts/handoff_lib.bb
case ${FAKE_INSTALL_MODE:-fork} in
  upstream)
    printf 'in-process-dir placeholder\n' > swarmforge/scripts/handoffd.bb
    printf 'cwd placeholder\n' > swarmforge/scripts/handoff_lib.bb ;;
  fail) exit 7 ;;
esac
printf '#!/bin/sh\nexit 0\n' > swarm
chmod +x swarm
# The real get-swarm-forge ends with a line like this. Reproduced because it
# is exactly what used to land ahead of the verb's own STATUS= line.
echo "SwarmForge forge installed from $1. Run ./swarm to start the dashboard."
EOF
chmod +x "$WORK/get-swarm-forge-fake"

export SWARMFORGE_HELPER_URL="file://$WORK/get-swarm-forge-fake"
# Keep both readiness budgets short: neither script's real budget is under
# test here, only what it does when the budget runs out.
export SF_START_READY_TRIES=20 SF_START_READY_INTERVAL=0.2
export SF_DASH_TRIES=6 SF_DASH_INTERVAL=0.2

compute_digest() { ( LOCAL=1; . "$HERE/lib-wake-talk.sh"; scripts_digest "$1" ) ; }

# ---------- a real dashboard ----------
cat > "$WORK/dash.py" <<'EOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("DASH_MODE", "ok")
RECORD = os.environ["DASH_RECORD"]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        with open(RECORD, "a") as f:
            f.write(self.path + " " + raw.decode() + "\n")
        if MODE == "conflict":
            code, body = 409, {"error": "Project already exists: demo"}
        elif MODE == "boom":
            code, body = 500, {"error": "kaboom"}
        else:
            body = json.loads(raw)
            code, body = 200, {"ok": True, "name": body.get("name"), "path": "/x"}
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

start_dash() { # $1 = mode
  DASH_PORT=$(free_port)
  DASH_RECORD=$WORK/posts.log
  : > "$DASH_RECORD"
  DASH_MODE=$1 DASH_RECORD=$DASH_RECORD python3 "$WORK/dash.py" "$DASH_PORT" &
  SERVER_PID=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$DASH_PORT/" && return 0
    sleep 0.1
  done
  echo "dashboard stub never came up"; exit 1
}
stop_dash() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=''; }

N=0
# Sets $R rather than echoing it: `R=$(fresh_root)` would run the counter in a
# subshell, so every case would silently share one root and inherit the
# previous case's install, manifest and projects/.
fresh_root() {
  N=$((N+1))
  R=$WORK/roots/r$N
}
reset_stub() { rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls.log"; }

run_provision() { # $@ = args; combined output in $OUT, stdout alone in $SOUT,
                  # exit code in $RC. Kept separate because the verb contract
                  # is about what reaches stdout FIRST, and merging streams
                  # would hide a helper's chatter jumping the STATUS= line.
  local out=$WORK/out.$$ err=$WORK/err.$$
  RC=0
  "$PROVISION" "$@" >"$out" 2>"$err" || RC=$?
  SOUT=$(cat "$out")
  OUT=$(cat "$out" "$err"); rm -f "$out" "$err"
}
status_of() { printf '%s\n' "$1" | head -1; }

echo "== usage =="
reset_stub
fresh_root
run_provision --forge project-manager --dashboard-port 7799 --local
check "no --root exits 2" 2 "$RC"
check "no --root says USAGE" "STATUS=USAGE" "$(status_of "$OUT")"

run_provision --root "$R" --dashboard-port 7799 --local
check "no --forge exits 2" 2 "$RC"

run_provision --root "$R" --forge nope --dashboard-port 7799 --local
check "bad --forge exits 2" 2 "$RC"

run_provision --root "$R" --forge project-manager --local
check "no --dashboard-port exits 2" 2 "$RC"

run_provision --root "$R" --forge project-manager --dashboard-port 77x9 --local
check "non-numeric --dashboard-port exits 2" 2 "$RC"

run_provision --root "$R" --forge project-manager --dashboard-port 7799 --terminal nope --local
check "bad --terminal exits 2" 2 "$RC"

run_provision --root "$R" --forge project-manager --dashboard-port 7799 --project demo --local
check "--project without --pack exits 2" 2 "$RC"

# A lieutenant forge has one project template, so --pack is not required there.
# Pointed at an occupied root so the run is stopped by the stage-1 guard rather
# than by validation: exit 6 proves the arguments were accepted AND that
# nothing was installed while proving it.
mkdir -p "$WORK/roots/occupied"; printf 'x\n' > "$WORK/roots/occupied/f"
run_provision --root "$WORK/roots/occupied" --forge lieutenant --dashboard-port 7799 --project demo --local
check "lieutenant needs no --pack" 6 "$RC"

run_provision --root "$R" --forge project-manager --dashboard-port 7799 --project 'de mo' --pack two-pack --local
check "--project with a space exits 2" 2 "$RC"

run_provision --root "$R/it's" --forge project-manager --dashboard-port 7799 --local
check "--root with a quote exits 2" 2 "$RC"

run_provision --root relative/path --forge project-manager --dashboard-port 7799 --local
check "relative --root exits 2" 2 "$RC"

check "no usage case ever installed anything" "" "$(cat "$STUB/installs" 2>/dev/null)"

echo "== source self-certification =="
reset_stub
fresh_root
FAKE_INSTALL_MODE=upstream FAKE_ROOT=$R SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port 7799 --local
check "upstream tree exits 5" 5 "$RC"
check "upstream tree says ERROR" "STATUS=ERROR" "$(status_of "$OUT")"
check "launcher was never called" "" "$(cat "$STUB/launched" 2>/dev/null)"
check "no manifest written for an unproven tree" "" "$(cat "$R/.swarmforge/scripts-manifest" 2>/dev/null)"

echo "== install failure =="
reset_stub
fresh_root
FAKE_INSTALL_MODE=fail FAKE_ROOT=$R SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port 7799 --local
check "failed install exits 5" 5 "$RC"
check "failed install writes no manifest" "" "$(cat "$R/.swarmforge/scripts-manifest" 2>/dev/null)"
check "failed install never launched" "" "$(cat "$STUB/launched" 2>/dev/null)"

echo "== occupied root =="
reset_stub
fresh_root; mkdir -p "$R"; printf 'mine\n' > "$R/notes.txt"
FAKE_ROOT=$R SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port 7799 --local
check "occupied root exits 6" 6 "$RC"
check "occupied root says UNSAFE" "STATUS=UNSAFE" "$(status_of "$OUT")"
check "occupied root untouched" "mine" "$(cat "$R/notes.txt")"
check "occupied root never installed" "" "$(cat "$STUB/installs" 2>/dev/null)"

echo "== happy path, no project =="
reset_stub
start_dash ok
fresh_root
FAKE_ROOT=$R FAKE_DASHBOARD_URL="http://127.0.0.1:$DASH_PORT/" SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port "$DASH_PORT" --local
check "stops at step 3 with exit 0" 0 "$RC"
check "reports PROVISIONED" "STATUS=PROVISIONED" "$(status_of "$OUT")"
check "reports the dashboard URL" "URL=http://127.0.0.1:$DASH_PORT/" "$(printf '%s\n' "$OUT" | grep '^URL=')"
check "no project was created" "" "$(cat "$WORK/posts.log")"
check "installed exactly once" "1" "$(grep -c . "$STUB/installs")"
MDIGEST=$(sed -n 's/^DIGEST=//p' "$R/.swarmforge/scripts-manifest" 2>/dev/null)
check "manifest digest matches the installed tree" "$(compute_digest "$R/swarmforge/scripts")" "$MDIGEST"
# The installer is chatty and its line used to reach stdout first.
check "STATUS is the first line of stdout" "STATUS=PROVISIONED" "$(status_of "$SOUT")"
check "manifest ends with a newline" "" \
  "$(tail -c1 "$R/.swarmforge/scripts-manifest" | tr -d '\n')"
FIRST_ROOT=$R

echo "== resume: already installed, already running =="
# Same root, same command. The swarm is still "live" from the run above.
run_provision --root "$FIRST_ROOT" --forge project-manager --dashboard-port "$DASH_PORT" --local
check "second run exits 0" 0 "$RC"
check "still installed exactly once" "1" "$(grep -c . "$STUB/installs")"
check "second run warns about the skipped install" 1 \
  "$(printf '%s\n' "$OUT" | grep -c '^WARN=.*install skipped')"
check "second run warns about the skipped start" 1 \
  "$(printf '%s\n' "$OUT" | grep -c '^WARN=.*start skipped')"

echo "== resume: installed, manifest missing, not running =="
reset_stub
fresh_root
mkdir -p "$R"
( cd "$R" && STUB=$STUB FAKE_INSTALL_MODE=fork "$WORK/get-swarm-forge-fake" project-manager )
rm -f "$R/.swarmforge/scripts-manifest"
: > "$STUB/installs"
FAKE_ROOT=$R FAKE_DASHBOARD_URL="http://127.0.0.1:$DASH_PORT/" SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port "$DASH_PORT" --local
check "backfill run exits 0" 0 "$RC"
check "backfill did not re-download" "" "$(cat "$STUB/installs")"
check "backfill wrote a matching manifest" "$(compute_digest "$R/swarmforge/scripts")" \
  "$(sed -n 's/^DIGEST=//p' "$R/.swarmforge/scripts-manifest")"
check "backfill launched the swarm" 1 "$(grep -c . "$STUB/launched")"

echo "== project creation =="
reset_stub
fresh_root
FAKE_ROOT=$R FAKE_DASHBOARD_URL="http://127.0.0.1:$DASH_PORT/" SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port "$DASH_PORT" \
  --project demo --pack two-pack --mission 'ship it' --local
check "creating a project exits 0" 0 "$RC"
check "reports the project" "PROJECT=demo" "$(printf '%s\n' "$OUT" | grep '^PROJECT=')"
POSTED=$(cat "$WORK/posts.log")
check "posted to /api/projects once" 1 "$(grep -c '^/api/projects ' "$WORK/posts.log")"
check "posted name" "demo" "$(printf '%s' "$POSTED" | sed 's#^/api/projects ##' | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
check "posted pack" "two-pack" "$(printf '%s' "$POSTED" | sed 's#^/api/projects ##' | python3 -c 'import json,sys; print(json.load(sys.stdin)["pack"])')"
check "posted mission" "ship it" "$(printf '%s' "$POSTED" | sed 's#^/api/projects ##' | python3 -c 'import json,sys; print(json.load(sys.stdin)["mission"])')"

echo "== project name already taken =="
reset_stub
mkdir -p "$R/projects/demo"
: > "$WORK/posts.log"
FAKE_ROOT=$R FAKE_DASHBOARD_URL="http://127.0.0.1:$DASH_PORT/" SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port "$DASH_PORT" \
  --project demo --pack two-pack --local
check "existing project exits 6" 6 "$RC"
check "existing project says UNSAFE" "STATUS=UNSAFE" "$(status_of "$OUT")"
check "existing project issued no POST" "" "$(cat "$WORK/posts.log")"
stop_dash

echo "== dashboard never answers =="
reset_stub
fresh_root
DEAD_PORT=$(free_port)
FAKE_ROOT=$R FAKE_DASHBOARD_URL="http://127.0.0.1:$DEAD_PORT/" SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port "$DEAD_PORT" \
  --project demo --pack two-pack --local
check "unreachable dashboard exits 5" 5 "$RC"
check "unreachable dashboard says ERROR" "STATUS=ERROR" "$(status_of "$OUT")"
check "unreachable dashboard names the uncreated project" 1 \
  "$(printf '%s\n' "$OUT" | grep -c "NOT created")"
check "no project directory was created" "" "$(ls "$R/projects" 2>/dev/null)"

echo "== dashboard rejects with 409 =="
reset_stub
start_dash conflict
fresh_root
FAKE_ROOT=$R FAKE_DASHBOARD_URL="http://127.0.0.1:$DASH_PORT/" SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port "$DASH_PORT" \
  --project demo --pack two-pack --local
check "409 exits 6" 6 "$RC"
check "409 says UNSAFE" "STATUS=UNSAFE" "$(status_of "$OUT")"
stop_dash

echo "== dashboard rejects with 500 =="
reset_stub
start_dash boom
fresh_root
FAKE_ROOT=$R FAKE_DASHBOARD_URL="http://127.0.0.1:$DASH_PORT/" SWARM_LAUNCHER=$WORK/fakeswarm \
  run_provision --root "$R" --forge project-manager --dashboard-port "$DASH_PORT" \
  --project demo --pack two-pack --local
check "500 exits 5" 5 "$RC"
check "500 quotes what the server said" 1 "$(printf '%s\n' "$OUT" | grep -c 'kaboom')"
stop_dash

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

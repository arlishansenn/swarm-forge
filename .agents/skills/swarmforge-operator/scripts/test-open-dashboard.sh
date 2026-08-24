#!/usr/bin/env bash
# test-open-dashboard.sh — end-to-end checks for open-dashboard.sh against a
# stubbed cmux/ssh/curl. Run: bash scripts/test-open-dashboard.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/open-dashboard.sh
WORK=$(mktemp -d /tmp/sf-dash-test.XXXXXX)
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stubs ----------
mkdir -p "$WORK/bin" "$WORK/fixtures"
cat > "$WORK/bin/cmux" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
log() { printf '%s\n' "$*" >> "$STUB/calls.log"; }
CMD=$1; shift
log "cmux $CMD $*"
case $CMD in
ping) echo PONG;;
rpc)
  METHOD=$1; ARGS=${2:-}
  case $METHOD in
  window.list) python3 -c 'import json;print(json.dumps({"windows":json.load(open("'$STUB'/state.json"))["windows"]}))';;
  workspace.list)
    WID=$(printf '%s' "$ARGS" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("window_id",""))
except Exception: print("")')
    python3 - "$STUB/state.json" "${WID:-}" <<'PY'
import json,sys
state=json.load(open(sys.argv[1])); wid=sys.argv[2]
if not wid: wid=state["windows"][0]["id"]
print(json.dumps({"window_id":wid,"workspaces":
 [w for w in state["workspaces"] if w["window_id"]==wid]}))
PY
;;
  surface.list)
    WSID=$(printf '%s' "$ARGS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["workspace_id"])')
    python3 - "$STUB/state.json" "$WSID" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
print(json.dumps({"surfaces":[s for s in state["surfaces"] if s["workspace_id"]==sys.argv[2]]}))
PY
;;
  *) echo "Error: method_not_found" >&2; exit 1;;
  esac;;
new-workspace)
  # real cmux: plain creation ships one default terminal surface; --layout
  # creates exactly the layout surfaces (browser w/ url, terminal w/ command)
  NAME= DESC= WINDOW= LAYOUT=
  while [ $# -gt 0 ]; do case $1 in
    --name) NAME=$2; shift 2;; --description) DESC=$2; shift 2;;
    --window) WINDOW=$2; shift 2;; --layout) LAYOUT=$2; shift 2;;
    --focus) shift 2;; *) shift;; esac; done
  W=$(( $(cat "$STUB/winnum") + 1 )); echo $W > "$STUB/winnum"
  python3 - "$STUB/state.json" "WSUUID-$W" "workspace:$W" "$WINDOW" "$NAME" "$DESC" "$LAYOUT" "$STUB" <<'PY'
import json,sys
sf,wsid,wsref,win,name,desc,layout,stub=sys.argv[1:9]
state=json.load(open(sf))
state["workspaces"].append({"id":wsid,"ref":wsref,"window_id":win,
 "title":name,"description":desc})
n=100
def add_surface(typ,url=""):
    global n
    n+=1
    state["surfaces"].append({"id":f"SUUID-{n}","ref":f"surface:{n}",
      "workspace_id":wsid,"type":typ,"title":url or f"default-{typ}","url":url})
if layout:
    lay=json.loads(layout)
    surfaces=lay["pane"]["surfaces"] if "pane" in lay else              [s for c in lay.get("children",[]) for s in c["pane"]["surfaces"]]
    for s in surfaces:
        add_surface(s["type"], s.get("url",""))
else:
    add_surface("terminal")
json.dump(state,open(sf,"w"))
PY
  echo "OK workspace:$W $NAME";;
new-surface)
  TYPE= URL= WS=
  while [ $# -gt 0 ]; do case $1 in
    --type) TYPE=$2; shift 2;; --url) URL=$2; shift 2;;
    --workspace) WS=$2; shift 2;; --focus) shift 2;; *) shift;; esac; done
  N=$(( $(cat "$STUB/nextid") + 1 )); echo $N > "$STUB/nextid"
  WSID=$(python3 -c 'import json,sys;s=json.load(open("'$STUB'/state.json"));print(next(w["id"] for w in s["workspaces"] if w["id"]==sys.argv[1] or w["ref"]==sys.argv[1]))' "$WS")
  python3 - "$STUB/state.json" "SUUID-$N" "surface:$N" "$WSID" "$TYPE" "$URL" <<'PY'
import json,sys
sf,sid,sref,wsid,typ,url=sys.argv[1:7]
state=json.load(open(sf))
state["surfaces"].append({"id":sid,"ref":sref,"workspace_id":wsid,
 "type":typ,"title":url,"url":url})
json.dump(state,open(sf,"w"))
PY
  echo "OK surface:$N pane:1 workspace:${WS#workspace:}";;
*) echo "Error: unknown $CMD" >&2; exit 1;;
esac
EOF
chmod +x "$WORK/bin/cmux"

# ssh stub: `cat` reads fixture; `-N -L` is a tunnel. Tunnel succeeds unless
# $STUB/port-occupied-<local> exists (simulates ExitOnForwardFailure). `cat
# .../pack_web.pid` and `ps -wwp` are answered off the real fixture file /
# $PSREG registry — see mk_pid below (issue #18 ownership check).
cat > "$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
if printf '%s\n' "$*" | grep -q "dashboard-url"; then
  cat "${DASHURL_FIXTURE:?}" 2>/dev/null && exit 0
  exit 1
fi
if printf '%s\n' "$*" | grep -q "pack_web.pid"; then
  PIDFILE=$(printf '%s\n' "$*" | sed -n "s/.*cat '\(.*pack_web\.pid\)'.*/\1/p")
  cat "$PIDFILE" 2>/dev/null && exit 0
  exit 1
fi
if printf '%s\n' "$*" | grep -q 'ps -wwp'; then
  PID=$(printf '%s\n' "$*" | sed -n "s/.*ps -wwp '\([0-9]*\)'.*/\1/p")
  LINE=$(sed -n "s/^$PID //p" "${PSREG:?}" 2>/dev/null | tail -1)
  [ -n "$LINE" ] || exit 1
  printf '%s\n' "$LINE"
  exit 0
fi
if printf '%s\n' "$*" | grep -q '\-N'; then
  LOCAL=$(printf '%s\n' "$*" | sed -n 's/.*-L \([0-9]*\):127.0.0.1:[0-9]*.*/\1/p')
  [ -f "$STUB/port-occupied-$LOCAL" ] && { echo "forward failed" >&2; exit 1; }
  : > "$STUB/tunnel-$LOCAL"
  printf '%s\n' "$*" >> "$STUB/tunnels.log"
  exit 0
fi
exit 0
EOF
chmod +x "$WORK/bin/ssh"

# curl stub: 200 iff a tunnel marker exists for the URL's port
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
URL=$(printf '%s\n' "$@" | grep -o 'http://127.0.0.1:[0-9]*' | head -1)
PORT=${URL##*:}
[ -n "$PORT" ] && [ -f "$STUB/tunnel-$PORT" ] && echo 200 || { echo 000; exit 7; }
EOF
chmod +x "$WORK/bin/curl"

reset_stub() {
  rm -rf "$STUB"; mkdir -p "$STUB"
  : > "$STUB/calls.log"; : > "$STUB/tunnels.log"
  echo 100 > "$STUB/nextid"; echo 10 > "$STUB/winnum"
  cat > "$STUB/state.json" <<'J'
{"windows":[{"id":"W1","ref":"window:1","index":0},{"id":"W2","ref":"window:9","index":1}],"workspaces":[],"surfaces":[]}
J
}
export STUB=$WORK/stub
: > "$WORK/ps-registry"
export PSREG=$WORK/ps-registry

mk_fixture() { # <name> <url|->  (- = no file)
  local root=$WORK/fixtures/$1
  mkdir -p "$root/.swarmforge"
  if [ "$2" != - ]; then printf '%s\n' "$2" > "$root/.swarmforge/dashboard-url"; fi
}

# pack_web.pid fixture + fake ps registry entry (issue #18 ownership check).
# Omit the 3rd arg to write a pid file with no matching process (dead pid).
mk_pid() { # <fixture> <pid> [served-root]
  local root=$WORK/fixtures/$1
  mkdir -p "$root/.swarmforge"
  printf '%s\n' "$2" > "$root/.swarmforge/pack_web.pid"
  if [ $# -ge 3 ]; then
    printf '%s bb /path/to/swarmforge/scripts/pack_web.bb --serve %s 54870\n' "$2" "$3" >> "$WORK/ps-registry"
  fi
}

run() { # <fixture> [extra args...]
  local fx=$1; shift
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB PSREG=$PSREG DASHURL_FIXTURE="$WORK/fixtures/$fx/.swarmforge/dashboard-url" \
    bash "$SCRIPT" --root "$WORK/fixtures/$fx" "$@" 2>&1)
  RC=$?
}
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
mutcount() { grep -c 'cmux new-workspace' "$STUB/calls.log" 2>/dev/null || true; }
tunnelcount() { grep -c . "$STUB/tunnels.log" || true; }

echo "== suite for open-dashboard.sh =="
if [ ! -f "$SCRIPT" ]; then echo "script missing — RED confirmed"; exit 1; fi

mk_fixture gov http://127.0.0.1:54870/
mk_pid gov 501 "$WORK/fixtures/gov"    # --serve matches $ROOT: proceed as today
mk_fixture dead -

# issue #18: three port-ownership fixtures, distinct from gov so a bad
# ownership check can't accidentally piggyback on gov's registration.
mk_fixture squat http://127.0.0.1:54871/
mk_pid squat 502 "$WORK/fixtures/other-project"   # --serve names a different root
mk_fixture pidmissing http://127.0.0.1:54872/     # no pack_web.pid written at all
mk_fixture piddead http://127.0.0.1:54873/
mk_pid piddead 909090                              # pid file present, no live process

# 1 stopped: no dashboard-url → exit 3, no cmux, no tunnel
reset_stub
run dead
check "stopped exit" 3 "$RC"
check "stopped status" STOPPED "$(val STATUS)"
check "stopped no cmux" 0 "$(grep -c '^cmux' "$STUB/calls.log" || true)"
check "stopped no tunnel" 0 "$(tunnelcount)"

# 2 happy: tunnel created, workspace + browser surface
reset_stub
run gov
check "happy exit" 0 "$RC"
check "happy status" OPENED "$(val STATUS)"
check "happy tunnel" created "$(val TUNNEL)"
check "happy url" "http://127.0.0.1:54870/" "$(val URL)"
check "happy one ws" 1 "$(mutcount)"
check "happy browser surface" "1" "$(python3 -c 'import json;s=json.load(open("'$STUB'/state.json"));print(sum(1 for x in s["surfaces"] if x["type"]=="browser"))')"
check "happy no terminal surface" "0" "$(python3 -c 'import json;s=json.load(open("'$STUB'/state.json"));print(sum(1 for x in s["surfaces"] if x["type"]=="terminal"))')"
check "happy ws exactly 1 surface" "1" "$(python3 -c 'import json;s=json.load(open("'$STUB'/state.json"));print(sum(1 for x in s["surfaces"] if x["workspace_id"]=="WSUUID-11"))')"
check "happy surface url" "http://127.0.0.1:54870/" "$(python3 -c 'import json;s=json.load(open("'$STUB'/state.json"));print(next(x["url"] for x in s["surfaces"] if x["type"]=="browser"))')"
grep -q -- '-L 54870:127.0.0.1:54870' "$STUB/tunnels.log" \
  && ok "happy tunnel cmd" || bad "happy tunnel cmd" "$(cat "$STUB/tunnels.log")"

# 3 reuse: second run → REUSED, no new ws, no new tunnel
run gov
check "reuse exit" 0 "$RC"
check "reuse status" REUSED "$(val STATUS)"
check "reuse tunnel" reused "$(val TUNNEL)"
check "reuse no extra ws" 1 "$(mutcount)"
check "reuse no extra tunnel" 1 "$(tunnelcount)"

# 4 occupied local port → fallback free port
reset_stub
: > "$STUB/port-occupied-54870"
run gov
check "fallback exit" 0 "$RC"
check "fallback status" OPENED "$(val STATUS)"
FBPORT=$(val URL | grep -o '[0-9]*' | tail -1)
[ -n "$FBPORT" ] && [ "$FBPORT" != 54870 ] \
  && ok "fallback port differs ($FBPORT)" || bad "fallback port" "got [$FBPORT]"
grep -q -- "-L $FBPORT:127.0.0.1:54870" "$STUB/tunnels.log" \
  && ok "fallback tunnel cmd" || bad "fallback tunnel cmd" "missing"

# 5 --window: workspace lands in given window
reset_stub
run gov --window window:9
check "window exit" 0 "$RC"
check "window target" "W2" "$(python3 -c 'import json;s=json.load(open("'$STUB'/state.json"));print(next(w["window_id"] for w in s["workspaces"]))')"

# 6 drift: two matching workspaces → exit 4
reset_stub
run gov >/dev/null
python3 - "$STUB/state.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
s["workspaces"].append({"id":"WSUUID-98","ref":"workspace:98","window_id":"W1",
 "title":"stray","description":"swarmforge-dashboard:gov@100.64.0.4"})
json.dump(s,open(sys.argv[1],"w"))
PY
run gov
check "drift exit" 4 "$RC"
check "drift status" DRIFT "$(val STATUS)"

# 7 reuse without browser surface (pre-fix legacy workspace) → repaired
reset_stub
run gov >/dev/null
python3 - "$STUB/state.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
s["surfaces"]=[x for x in s["surfaces"] if x["type"]!="browser"]
json.dump(s,open(sys.argv[1],"w"))
PY
run gov
check "legacy exit" 0 "$RC"
check "legacy status" REUSED "$(val STATUS)"
check "legacy browser repaired" "1" "$(python3 -c 'import json;s=json.load(open("'$STUB'/state.json"));print(sum(1 for x in s["surfaces"] if x["type"]=="browser"))')"

# 8 port ownership mismatch (issue #18): pack_web.pid's process is alive but
# serves a different root → exit 4 DRIFT, actual root in stdout, no cmux call
reset_stub
run squat
check "squat exit" 4 "$RC"
check "squat status" DRIFT "$(val STATUS)"
printf '%s\n' "$OUT" | grep -qF "$WORK/fixtures/other-project" \
  && ok "squat names actual root" || bad "squat names actual root" "$OUT"
check "squat no cmux" 0 "$(grep -c '^cmux' "$STUB/calls.log" || true)"
check "squat no workspace" 0 "$(mutcount)"

# 9 pack_web.pid missing entirely → exit 3 STOPPED, not 4 (port answers fine)
reset_stub
run pidmissing
check "pid-missing exit" 3 "$RC"
check "pid-missing status" STOPPED "$(val STATUS)"
check "pid-missing no cmux" 0 "$(grep -c '^cmux' "$STUB/calls.log" || true)"

# 10 pack_web.pid present but the process is dead → exit 3 STOPPED, not 4
reset_stub
run piddead
check "pid-dead exit" 3 "$RC"
check "pid-dead status" STOPPED "$(val STATUS)"
check "pid-dead no cmux" 0 "$(grep -c '^cmux' "$STUB/calls.log" || true)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

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
browser)
  SURF= SUB= ARG=
  while [ $# -gt 0 ]; do case $1 in
    --surface) SURF=$2; shift 2;;
    get-url|url) SUB=get-url; shift;;
    goto|navigate) SUB=goto; ARG=$2; shift 2;;
    *) shift;; esac; done
  case $SUB in
    get-url)
      python3 -c 'import json,sys;s=json.load(open("'$STUB'/state.json"));print(next((x["url"] for x in s["surfaces"] if x["id"]==sys.argv[1] or x["ref"]==sys.argv[1]), ""))' "$SURF" ;;
    goto)
      python3 - "$STUB/state.json" "$SURF" "$ARG" <<'PY'
import json,sys
sf,surf,url=sys.argv[1:4]
state=json.load(open(sf))
for x in state["surfaces"]:
    if x["id"]==surf or x["ref"]==surf:
        x["url"]=url
json.dump(state,open(sf,"w"))
PY
      echo OK ;;
    *) echo "Error: unknown browser subcommand" >&2; exit 1;;
  esac;;
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
if printf '%s\n' "$*" | grep -q "tmux-socket"; then
  SF=$(printf '%s\n' "$*" | sed -n "s/.*cat '\(.*tmux-socket\)'.*/\1/p")
  cat "$SF" 2>/dev/null && exit 0
  exit 1
fi
if printf '%s\n' "$*" | grep -q 'list-sessions'; then
  # $STUB/tmux-dead makes the socket file exist with no server behind it —
  # the state a killed swarm leaves, and the one every other verb already
  # refuses to read as "running".
  [ -f "$STUB/tmux-dead" ] && exit 1
  exit 0
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

# curl stub: 200 iff the matching marker exists. Loopback answers off a
# tunnel marker (an ssh forward is up), any other host off a tailnet marker
# (the port is published on the tailnet) — two separate facts, as live.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
URL=$(printf '%s\n' "$@" | grep -o 'http://[0-9.]*:[0-9]*' | head -1)
HOSTPORT=${URL#http://}
HOST=${HOSTPORT%%:*}
PORT=${HOSTPORT##*:}
MARK=tunnel; [ "$HOST" = 127.0.0.1 ] || MARK=tailnet
[ -n "$PORT" ] && [ -f "$STUB/$MARK-$PORT" ] && echo 200 || { echo 000; exit 7; }
EOF
chmod +x "$WORK/bin/curl"

# tailscale stub: exists only so "the verb never runs it" is checkable rather
# than assumed. Publishing a port is a one-time operator action; a verb that
# shelled out to tailscale would be managing serve config it does not own.
cat > "$WORK/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'tailscale %s\n' "$*" >> "$STUB/calls.log"
exit 1
EOF
chmod +x "$WORK/bin/tailscale"

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
  # issue #100: this verb now asks the same liveness question its six siblings
  # ask — read tmux-socket, probe list-sessions. Every fixture here models a
  # RUNNING swarm unless a case says otherwise, so they all get a socket.
  printf '/tmp/sf-dash-test.sock\n' > "$root/.swarmforge/tmux-socket"
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

# 11 --tailnet (issue #78): no ssh tunnel, no tailscale command, and the URL
#    handed to cmux is the tailnet address — the one that also works from a
#    phone, and that does not die when the operator's laptop sleeps.
reset_stub
: > "$STUB/tailnet-54870"
run gov --tailnet
check "tailnet exit" 0 "$RC"
check "tailnet status" OPENED "$(val STATUS)"
check "tailnet tunnel" tailnet "$(val TUNNEL)"
check "tailnet url" "http://100.64.0.4:54870/" "$(val URL)"
check "tailnet built no ssh tunnel" 0 "$(tunnelcount)"
check "tailnet ran no tailscale command" 0 "$(grep -c '^tailscale' "$STUB/calls.log" || true)"
check "tailnet one ws" 1 "$(mutcount)"
check "tailnet surface url" "http://100.64.0.4:54870/" "$(python3 -c 'import json;s=json.load(open("'$STUB'/state.json"));print(next(x["url"] for x in s["surfaces"] if x["type"]=="browser"))')"

# 12 --tailnet on a port nobody published: clean exit that hands the operator
#    the exact command to run. `tailscale serve --bg` survives reboots and
#    down/up on its own, so this really is a one-time action, not a repair
#    the verb should be doing on every call.
reset_stub
run gov --tailnet
check "unpublished exit" 5 "$RC"
check "unpublished status" ERROR "$(val STATUS)"
printf '%s\n' "$OUT" | grep -qF "http://100.64.0.4:54870/" \
  && ok "unpublished names the URL that failed" || bad "unpublished names the URL" "$OUT"
printf '%s\n' "$OUT" | grep -qF "tailscale serve --bg --tcp 54870 tcp://127.0.0.1:54870" \
  && ok "unpublished prints the command to run verbatim" || bad "unpublished prints the command" "$OUT"
check "unpublished no workspace" 0 "$(mutcount)"
check "unpublished no tunnel" 0 "$(tunnelcount)"
check "unpublished no cmux at all" 0 "$(grep -c '^cmux' "$STUB/calls.log" || true)"
check "unpublished ran no tailscale command" 0 "$(grep -c '^tailscale' "$STUB/calls.log" || true)"

# 13 --tailnet does not weaken the issue #18 ownership check: a fixed port is
#    MORE likely to be squatted by another project than a random one was.
reset_stub
: > "$STUB/tailnet-54871"
run squat --tailnet
check "tailnet squat exit" 4 "$RC"
check "tailnet squat status" DRIFT "$(val STATUS)"
printf '%s\n' "$OUT" | grep -qF "$WORK/fixtures/other-project" \
  && ok "tailnet squat names actual root" || bad "tailnet squat names actual root" "$OUT"
check "tailnet squat no workspace" 0 "$(mutcount)"

# 14 --tailnet with --local is a contradiction: there is no target host to
#    reach over the tailnet. Rejected rather than silently ignored.
reset_stub
run gov --tailnet --local
check "tailnet+local exit" 2 "$RC"
check "tailnet+local no cmux" 0 "$(grep -c '^cmux' "$STUB/calls.log" || true)"

# 15 without --tailnet the ssh path is untouched: still a tunnel, still a
#    loopback URL, still no tailscale command.
reset_stub
: > "$STUB/tailnet-54870"
run gov
check "no-flag still tunnels" created "$(val TUNNEL)"
check "no-flag url still loopback" "http://127.0.0.1:54870/" "$(val URL)"
check "no-flag one tunnel" 1 "$(tunnelcount)"

# ---------- issue #100: a stopped swarm must read as STOPPED, not ERROR ------
# `stop swarm` deletes pack_web.pid but leaves dashboard-url behind, so after a
# stop the two inputs this verb reads disagree — and it had no third source to
# break the tie. It checked HTTP reachability FIRST, died 5, and never reached
# the ownership check that would have said 3. Live symptom on podsum: "tunnel
# up but ... did not return 200 in 10s" on one path, and on the other a
# `tailscale serve` command that had already been run.
#
# The deeper problem is that this verb was the only one that never asked "is
# the swarm running" at all — the one judgment its six siblings share. These
# cases pin both halves: the shared gate, and the ordering.

# 11. socket file present, no server behind it → 3, and nothing was touched.
reset_stub
: > "$STUB/tmux-dead"
run gov
check "dead socket exit" 3 "$RC"
check "dead socket status" STOPPED "$(val STATUS)"
check "dead socket: no cmux at all" 0 "$(grep -c '^cmux' "$STUB/calls.log" || true)"
check "dead socket: no tunnel" 0 "$(tunnelcount)"

# 12. same on the --tailnet path — a stopped swarm must not be told its port
#     is unpublished, which is a command the operator may already have run.
reset_stub
: > "$STUB/tmux-dead"
: > "$STUB/tailnet-54870"
run gov --tailnet
check "dead socket + tailnet exit" 3 "$RC"
check "dead socket + tailnet status" STOPPED "$(val STATUS)"
printf '%s\n' "$OUT" | grep -q 'tailscale serve' \
  && bad "dead socket + tailnet: no serve advice" "$OUT" \
  || ok "dead socket + tailnet: no serve advice"

# 13. swarm alive but pack_web gone (the exact shape `stop swarm` leaves):
#     3 on BOTH paths, and the reachability check never runs. Before this
#     change the port answered nothing and the verb died 5.
reset_stub
run pidmissing
check "stopped pack_web exit" 3 "$RC"
check "stopped pack_web status" STOPPED "$(val STATUS)"
check "stopped pack_web: never built a tunnel" 0 "$(tunnelcount)"

reset_stub
run pidmissing --tailnet
check "stopped pack_web + tailnet exit" 3 "$RC"
printf '%s\n' "$OUT" | grep -q 'tailscale serve' \
  && bad "stopped pack_web + tailnet: no serve advice" "$OUT" \
  || ok "stopped pack_web + tailnet: no serve advice"

# 14. pid file present, process gone — same answer on both paths.
reset_stub
run piddead
check "dead pid exit" 3 "$RC"
reset_stub
run piddead --tailnet
check "dead pid + tailnet exit" 3 "$RC"

# 15. the squatting case must still be 4 DRIFT, and must now refuse BEFORE
#     leaving an ssh tunnel behind — the ownership check moved ahead of it.
reset_stub
: > "$STUB/tailnet-54871"
run squat
check "squat still DRIFT" 4 "$RC"
check "squat no longer leaves a tunnel behind" 0 "$(tunnelcount)"

# ---------- issue #99: a reused surface must point at THIS run's URL --------
# `browser_surface()` picks the first surface whose type is "browser" and never
# looks at its url; the reuse path only repaired a MISSING surface. So the
# report printed the new URL while the screen stayed on the previous, dead
# port. Not a rare state: pack_web binds a fresh port on every start unless the
# project uses --dashboard-port, so after one restart the reused surface is
# ALWAYS stale.
#
# Server side was already covered — issue #18 proves the port belongs to this
# project, issue #100 proves the project is running. Nothing proved the screen
# was showing it.

surface_url() {  # surface_url <workspace-uuid>
  python3 -c 'import json,sys;s=json.load(open("'$STUB'/state.json"));print(next((x["url"] for x in s["surfaces"] if x["workspace_id"]==sys.argv[1] and x["type"]=="browser"), ""))' "$1"
}
goto_count() { grep -c 'cmux browser .* goto' "$STUB/calls.log" 2>/dev/null || true; }

# 16. a stale surface is navigated to this run's URL
reset_stub
run gov >/dev/null                       # first run creates the workspace
python3 - "$STUB/state.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
for x in s["surfaces"]:
    if x["type"]=="browser":
        x["url"]="http://127.0.0.1:40645/"   # a previous, dead port
json.dump(s,open(sys.argv[1],"w"))
PY
run gov
check "stale surface exit" 0 "$RC"
check "stale surface status" REUSED "$(val STATUS)"
check "stale surface was navigated" "http://127.0.0.1:54870/" "$(surface_url WSUUID-11)"
check "report URL matches where the surface points" "$(surface_url WSUUID-11)" "$(val URL)"

# 17. a surface already pointing at the right place is left alone. REUSED means
#     do not fiddle; a needless goto is a mutation this verb should not make.
reset_stub
run gov >/dev/null
run gov
check "matching surface exit" 0 "$RC"
check "matching surface status" REUSED "$(val STATUS)"
check "matching surface: no goto" 0 "$(goto_count)"
check "matching surface: no new workspace" 1 "$(mutcount)"
check "matching surface: still points at the URL" "http://127.0.0.1:54870/" "$(surface_url WSUUID-11)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
# test-open-swarm.sh — end-to-end checks for open-swarm.sh against a stubbed
# cmux. Run: bash scripts/test-open-swarm.sh. Exits non-zero on any failure.
# The stub encodes the verified CLI contract (refs, settle-by-description,
# layout commands); it never touches the real cmux app.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/open-swarm.sh
WORK=$(mktemp -d /tmp/sf-open-test.XXXXXX)
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ # check <desc> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub cmux + tmux ----------
mkdir -p "$WORK/bin" "$WORK/screens" "$WORK/fixtures"
cat > "$WORK/bin/cmux" <<'EOF'
#!/usr/bin/env bash
# stub cmux. State: $STUB/state.json (windows+workspaces+surfaces),
# $STUB/calls.log, $STUB/screens/<n>.txt, $STUB/session-map.tsv,
# $STUB/garbage-newws (flag file), $STUB/extra-ws.json (drift injection).
STUB=${STUB:?}
LOG=$STUB/calls.log
log() { printf '%s\n' "$*" >> "$LOG"; }
NEXT=$STUB/nextid
next() { n=$(cat "$NEXT" 2>/dev/null || echo 100); echo $((n+1)) > "$NEXT"; echo "$n"; }
scr() { echo "$STUB/screens/$(printf '%s' "$1" | tr -d 'surface:')".txt; }

CMD=$1; shift
log "cmux $CMD $*"
case $CMD in
ping) echo PONG;;
identify)
  # output shape: caller.window_ref (drop --json; stub always prints json)
  cat <<J
{"caller":{"window_ref":"window:1"},"focused":{"window_ref":"window:1"}}
J
;;
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
if not wid:  # no-args form: caller's window = first window
    wid=state["windows"][0]["id"]
w=next(w for w in state["windows"] if w["id"]==wid)
print(json.dumps({"window_id":wid,"window_ref":w["ref"],
 "workspaces":[ws for ws in state["workspaces"] if ws["window_id"]==wid]}))
PY
;;
  surface.list)
    WSID=$(printf '%s' "$ARGS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["workspace_id"])')
    python3 - "$STUB/state.json" "$WSID" <<'PY'
import json,sys
state=json.load(open(sys.argv[1])); wsid=sys.argv[2]
ss=[s for s in state["surfaces"] if s["workspace_id"]==wsid]
ss.sort(key=lambda s:(int(s["pane_ref"].split(":")[1]),s["index_in_pane"]))
print(json.dumps({"surfaces":ss}))
PY
;;
  *) echo "Error: method_not_found" >&2; exit 1;;
  esac;;
new-workspace)
  NAME= DESC= WINDOW= LAYOUT=
  while [ $# -gt 0 ]; do case $1 in
    --name) NAME=$2; shift 2;; --description) DESC=$2; shift 2;;
    --window) WINDOW=$2; shift 2;; --layout) LAYOUT=$2; shift 2;;
    --focus) shift 2;; *) shift;; esac; done
  W=$(( $(cat "$STUB/winnum" 2>/dev/null || echo 0) + 1 )); echo $W > "$STUB/winnum"
  WSREF=workspace:$W
  WSID=WSUUID-$W
  python3 - "$STUB/state.json" "$WSID" "$WSREF" "$WINDOW" "$NAME" "$DESC" "$LAYOUT" <<'PY'
import json,sys
state_file,wsid,wsref,win,name,desc,layout=sys.argv[1:8]
state=json.load(open(state_file))
ws={"id":wsid,"ref":wsref,"window_id":win,"index":len(state["workspaces"]),
    "title":name,"description":desc}
state["workspaces"].append(ws)
if layout and layout!="null":
    lay=json.loads(layout)
    kids=lay["children"] if "children" in lay else [{"pane":{"surfaces":[lay["pane"]["surfaces"][0]]}}]
    for k,child in enumerate(kids):
        for s in child["pane"]["surfaces"]:
            n=len(state["surfaces"])+101
            state["surfaces"].append({"id":"SUUID-%d"%n,"ref":"surface:%d"%n,
              "workspace_id":wsid,"pane_ref":"pane:%d"%(200+k),"index_in_pane":0,
              "type":"terminal","title":"","cmd":s.get("command","")})
json.dump(state,open(state_file,"w"))
PY
  # execute layout surface commands: successful attach paints a status bar
  python3 - "$STUB/state.json" "$WSID" "$STUB" <<'PY'
import json,sys,os,re
state=json.load(open(sys.argv[1])); wsid=sys.argv[2]; stub=sys.argv[3]
smap={}
for line in open(os.path.join(stub,"session-map.tsv")):
    sess,disp=line.rstrip("\n").split("\t"); smap[sess]=disp
for s in state["surfaces"]:
    if s["workspace_id"]!=wsid: continue
    m=re.search(r"attach -t '?(\S+?)'?$",s.get("cmd",""))
    if m and m.group(1) in smap:
        f=os.path.join(stub,"screens",s["ref"].split(":")[1]+".txt")
        open(f,"a").write("[swarmforg0:%s*] \n"%smap[m.group(1)])
PY
  if [ -f "$STUB/garbage-newws" ]; then echo "garbage output, no ref"; else echo "OK $WSREF $NAME"; fi;;
read-screen)
  S=; LINES=24
  while [ $# -gt 0 ]; do case $1 in
    --surface) S=$2; shift 2;; --lines) LINES=$2; shift 2;; *) shift;; esac; done
  cat "$(scr "$S")" 2>/dev/null || true;;
send)
  S=; T=
  while [ $# -gt 0 ]; do case $1 in
    --surface) S=$2; shift 2;; *) T="$T $1"; shift;; esac; done
  SESS=$(printf '%s' "$T" | grep -o "attach -t '[^']*'" | cut -d"'" -f2)
  DISP=$(awk -F'\t' -v s="$SESS" '$1==s{print $2}' "$STUB/session-map.tsv" 2>/dev/null)
  [ -n "$DISP" ] && printf '[swarmforg0:%s*] \n' "$DISP" >> "$(scr "$S")";;
send-key) ;; # ctrl+u / enter: no-op in stub
*) echo "Error: unknown $CMD" >&2; exit 1;;
esac
EOF
chmod +x "$WORK/bin/cmux"

cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# stub tmux: gate succeeds only when the fixture marks the swarm live
[ -f "${TMUX_STUB_LIVE:-/nonexistent}" ] || exit 1
exit 0
EOF
chmod +x "$WORK/bin/tmux"

# ---------- fixture builder ----------
mk_fixture() { # mk_fixture <name> <live:0|1> <role:display> ...
  local name=$1 live=$2; shift 2
  local root=$WORK/fixtures/$name
  mkdir -p "$root/.swarmforge"
  : > "$root/.swarmforge/sessions.tsv"
  : > "$root/.swarmforge/roles.tsv"
  local i=0 wt
  for rd in "$@"; do
    local role=${rd%%:*} disp=${rd##*:}
    i=$((i+1))
    # first role lives on the master worktree — that row is the intake role
    wt=$role; [ $i -eq 1 ] && wt=master
    printf '%d\t%s\tswarmforge-%s\t%s\tgrok\n' "$i" "$role" "$role" "$disp" >> "$root/.swarmforge/sessions.tsv"
    printf '%s\t%s\t/%s/wt/%s\tswarmforge-%s\t%s\tgrok\tqueue\n' \
      "$role" "$wt" "$root" "$role" "$role" "$disp" >> "$root/.swarmforge/roles.tsv"
  done
  # first role sits on the master worktree
  printf '/tmp/sf-%s.sock\n' "$name" > "$root/.swarmforge/tmux-socket"
  [ "$live" = 1 ] && touch "$root/.swarmforge/live-marker"
}

reset_stub() { # fresh cmux state; caller window:1 (uuid W1)
  rm -rf "$STUB"; mkdir -p "$STUB/screens"
  : > "$STUB/calls.log"; : > "$STUB/session-map.tsv"
  echo 100 > "$STUB/nextid"
  cat > "$STUB/state.json" <<'J'
{"windows":[{"id":"W1","ref":"window:1","index":0}],"workspaces":[],"surfaces":[]}
J
  echo W1 > "$STUB/winnum"
}
export STUB=$WORK/stub

run() { # run <fixture> [extra args...] — returns script output in $OUT
  local fx=$1; shift
  local root=$WORK/fixtures/$fx
  OUT=$(PATH="$WORK/bin:$PATH" TMUX_STUB_LIVE="$root/.swarmforge/live-marker" \
    STUB=$STUB bash "$SCRIPT" --local --root "$root" "$@" 2>&1)
  RC=$?
}
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
mutcount() { grep -c 'cmux new-workspace' "$STUB/calls.log" 2>/dev/null || true; }
no_destructive() { ! grep -Eq 'cmux (close|kill)' "$STUB/calls.log"; }
no_swarm_start() { ! grep -q '\./swarm' "$STUB/calls.log"; }
no_new_window()  { ! grep -q 'cmux new-window' "$STUB/calls.log"; }

map_sessions() { # fixture sessions → stub session-map.tsv
  awk -F'\t' '{print $3"\t"$4}' "$WORK/fixtures/$1/.swarmforge/sessions.tsv" >> "$STUB/session-map.tsv"
}

# ---------- cases ----------
echo "== RED/GREEN suite for open-swarm.sh =="

mk_fixture twopack 1 Coder:Coder Cleaner:Cleaner
mk_fixture fourpack 1 Specifier:Spec Coder:Coder Reviewer:Rev Cleaner:Cleaner
mk_fixture sixpack 1 S:Spec C:Coder R:Rev T:Tester O:Observer L:Cleaner
mk_fixture custom5 1 Intake:Gate Builder:Build Verifier:Verify Shipper:Ship Explorer:Explorer

if [ ! -f "$SCRIPT" ]; then
  echo "script missing — RED confirmed, all cases fail"; exit 1
fi

# 1 two-pack create
reset_stub; map_sessions twopack
run twopack
check "two-pack exit" 0 "$RC"
check "two-pack status" OPENED "$(val STATUS)"
check "two-pack ws count" 1 "$(mutcount)"
check "two-pack pair name" "1" "$(python3 -c 'import json;print(sum(1 for w in json.load(open("'$STUB'/state.json"))["workspaces"] if w["title"]=="Coder + Cleaner"))')"
check "two-pack displays on screen" "2" "$(cat "$STUB"/screens/*.txt | grep -c 'Coder\*\]\|Cleaner\*\]')"
check "two-pack master" "Coder" "$(val MASTER_DISPLAY)"
no_destructive && ok "no destructive calls" || bad "no destructive calls" "close/kill in log"
no_swarm_start && ok "no ./swarm invocation" || bad "no ./swarm invocation" "found"
no_new_window && ok "no macOS window created" || bad "no macOS window created" "new-window called"

# 2 four-pack
reset_stub; map_sessions fourpack
run fourpack
check "four-pack exit" 0 "$RC"
check "four-pack ws count" 2 "$(mutcount)"

# 3 six-pack
reset_stub; map_sessions sixpack
run sixpack
check "six-pack exit" 0 "$RC"
check "six-pack ws count" 3 "$(mutcount)"

# 4 custom 5-role: 3 workspaces, odd tail single pane
reset_stub; map_sessions custom5
run custom5
check "custom5 exit" 0 "$RC"
check "custom5 ws count" 3 "$(mutcount)"
check "custom5 tail single name" "1" "$(python3 -c 'import json;print(sum(1 for w in json.load(open("'$STUB'/state.json"))["workspaces"] if w["title"]=="Explorer"))')"

# 5 reuse: create then rerun two-pack → REUSED, no new mutation
reset_stub; map_sessions twopack
run twopack
check "setup exit" 0 "$RC"
run twopack
check "reuse exit" 0 "$RC"
check "reuse status" REUSED "$(val STATUS)"
check "reuse no extra ws" 1 "$(mutcount)"

# 6 repair stale surface on reuse
reset_stub; map_sessions twopack
run twopack
printf '[admin@macmini ~]$ \n' > "$STUB/screens/102.txt"
run twopack
check "repair exit" 0 "$RC"
check "repair status" REUSED "$(val STATUS)"
check "repair count" 1 "$(val REPAIRED)"
grep -q "attach -t 'swarmforge-Cleaner'" "$STUB/calls.log" \
  && ok "repair re-sent cleaner attach"

# 7 stopped: no .swarmforge at all → exit 3, zero cmux calls
reset_stub
mkdir -p "$WORK/fixtures/dead/.swarmforge"
rm -rf "$WORK/fixtures/dead/.swarmforge"
run dead
check "stopped exit" 3 "$RC"
check "stopped zero cmux calls" 0 "$(grep -c '^cmux' "$STUB/calls.log" || true)"

# 8 socket dead: files present, tmux gate fails → exit 3, no mutation
reset_stub; map_sessions twopack
rm -f "$WORK/fixtures/twopack/.swarmforge/live-marker"
run twopack
check "socket-dead exit" 3 "$RC"
check "socket-dead no mutation" 0 "$(mutcount)"
touch "$WORK/fixtures/twopack/.swarmforge/live-marker"  # restore for later cases

# 9 drift: extra matching workspace → exit 4
reset_stub; map_sessions twopack
run twopack >/dev/null
python3 - "$STUB/state.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
s["workspaces"].append({"id":"WSUUID-99","ref":"workspace:99","window_id":"W1",
 "index":9,"title":"stray","description":"swarmforge:twopack@local"})
json.dump(s,open(sys.argv[1],"w"))
PY
run twopack
check "drift exit" 4 "$RC"

# 10 mutation output unparseable → no duplicate creation (settle-by-description fallback)
reset_stub; map_sessions twopack; touch "$STUB/garbage-newws"
run twopack
check "garbage-out exit" 0 "$RC"
check "garbage-out single ws" 1 "$(mutcount)"

# fixtures for case 1..6 must exist before their reset_stub/map calls
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

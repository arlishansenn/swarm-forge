#!/usr/bin/env bash
# open-dashboard.sh — open the running SwarmForge pack_web dashboard as a
# cmux browser workspace, over an SSH local-forward tunnel or, with
# --tailnet, straight at the target's tailscale IP.
#
# Exit codes / STATUS line: 0 OPENED|REUSED   3 STOPPED   4 DRIFT   5 ERROR
# TUNNEL= reports which path was taken: local | created | reused | tailnet.
# Contract: ../SKILL.md (verb: dashboard). Never starts pack_web or the
# swarm, never closes anything, never creates a macOS window.
#
# --tailnet (issue #78) skips the tunnel. An ssh forward lives on the
# operator's laptop: it dies when the laptop sleeps, and no other device can
# use it. The managed hosts are already on the tailnet, so the dashboard's own
# host:port is reachable from every device the operator owns — as long as the
# port is fixed (see start-swarm.sh --dashboard-port) and published.
#
# This verb runs NO tailscale command, ever. Publishing a port is a one-time
# operator action whose config the verb does not own, does not create and must
# not clean up; the verb only observes the result over HTTP and, when the port
# does not answer, prints the command to run rather than running it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' WINDOW='' LOCAL=0 TAILNET=0

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --window) WINDOW=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --tailnet) TAILNET=1; shift ;;
    *) sed -n '2,4p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || { sed -n '2,4p' "$0"; exit 2; }
# --local means "the dashboard is on this machine"; there is then no target
# host to reach over the tailnet. Rejected rather than quietly ignored, which
# would hand back a loopback URL to someone who asked for a shareable one.
[ "$LOCAL" = 1 ] && [ "$TAILNET" = 1 ] && { sed -n '2,4p' "$0"; exit 2; }

BASE=$(basename "$ROOT")
HOSTPART=local; [ "$LOCAL" = 0 ] && HOSTPART=${TARGET#*@}
DESC="swarmforge-dashboard:${BASE}@${HOSTPART}"

# ---------- is the swarm running at all? (issue #100) ----------
# The same question, asked the same way, as open/start/stop/read swarm,
# wake/talk role and update SwarmForge scripts: read tmux-socket, then probe
# the server behind it. A socket FILE with no server is not "running" — that
# rule came out of the window watchdog tearing a swarm down, and it is the one
# judgment all those verbs share.
#
# This verb used to sit outside it. It read only dashboard-url and
# pack_web.pid, and those two artifacts have different lifetimes: pack_web
# writes both, `stop swarm` deletes the pid and NOTHING deletes the url. After
# a stop they disagree and there was no third source to break the tie, so a
# stopped project fell through to the reachability check and died 5 —
# "the tunnel is broken" for a swarm that was simply off, and on the tailnet
# path a `tailscale serve` command the operator had very likely already run.
#
# Asked before everything else: a project that is not running has no port to
# reach, no owner to identify, and no workspace to open.
if ! SOCK=$(read_file .swarmforge/tmux-socket 2>/dev/null); then
  die STOPPED "$ROOT/.swarmforge/tmux-socket missing — swarm not running; start it first, this verb never does" 3
fi
SOCK=${SOCK%$'\n'}
tmux_remote list-sessions >/dev/null 2>&1 \
  || die STOPPED "socket $SOCK has no tmux server — swarm not running; start it first, this verb never does" 3

# ---------- runtime state ----------
URL=$(read_file .swarmforge/dashboard-url 2>/dev/null) \
  || die STOPPED "$ROOT/.swarmforge/dashboard-url missing — dashboard not running; refusing to start it" 3
[ -n "$URL" ] || die STOPPED "$ROOT/.swarmforge/dashboard-url is empty — dashboard not running; refusing to start it" 3
URL=${URL%$'\n'}
RPORT=$(python3 -c 'import re,sys; m=re.match(r"^http://127\.0\.0\.1:(\d+)/?$", sys.argv[1]); print(m.group(1) if m else "")' "$URL")
[ -n "$RPORT" ] || die ERROR "dashboard-url has unexpected format: $URL" 5

# ---------- port ownership (issue #18) ----------
# curl_200 only proves *something* answers on the port; on a host running
# several managed projects with dynamic port allocation that could be
# another project's pack_web squatting a stale dashboard-url. Confirm the
# pid file's process is alive and its --serve argument is this $ROOT before
# any cmux mutation. This must run against $TARGET/local directly, not
# through the tunnel — the tunnel only forwards HTTP, it carries no process
# identity for the remote host.
PIDFILE="$ROOT/.swarmforge/pack_web.pid"
if [ "$LOCAL" = 1 ]; then
  [ -s "$PIDFILE" ] 2>/dev/null \
    || die STOPPED "$PIDFILE missing — dashboard not owned by a live pack_web; refusing to start it" 3
  PWPID=$(<"$PIDFILE")
else
  PWPID=$(ssh -i "$KEY" "$TARGET" "cat '$PIDFILE'" 2>/dev/null) \
    || die STOPPED "$PIDFILE missing on $TARGET — dashboard not owned by a live pack_web; refusing to start it" 3
fi
PWPID=${PWPID%$'\n'}

# -ww: BSD/macOS ps truncates the command column to terminal width unless
# told not to, which would silently break parsing a long project path.
if [ "$LOCAL" = 1 ]; then
  CMDLINE=$(ps -wwp "$PWPID" -o command= 2>/dev/null) || true
else
  CMDLINE=$(ssh -i "$KEY" "$TARGET" "ps -wwp '$PWPID' -o command=" 2>/dev/null) || true
fi
[ -n "$CMDLINE" ] \
  || die STOPPED "pack_web.pid ($PWPID) has no running process — dashboard not owned by a live pack_web; refusing to start it" 3

# find the --serve token and take the NEXT token as the served root; a
# substring check on the raw command line would false-match a nested
# project path or a log-redirect argument that happens to contain $ROOT.
SERVED_ROOT=$(python3 -c '
import shlex, sys
toks = shlex.split(sys.argv[1])
i = toks.index("--serve") if "--serve" in toks else -1
print(toks[i + 1] if 0 <= i < len(toks) - 1 else "")
' "$CMDLINE")
[ "$SERVED_ROOT" = "$ROOT" ] \
  || die DRIFT "dashboard-url's port is served by pack_web for '$SERVED_ROOT', not '$ROOT' — another project's dashboard is squatting this dashboard-url" 4

# ---------- tunnel ----------
curl_200() { # $1 url → 0 iff HTTP 200
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null)" = 200 ]
}

TUNNEL=local
if [ "$TAILNET" = 1 ]; then
  # The tailscale IP is already in $TARGET; HOSTPART pulled it out above.
  URL="http://${HOSTPART}:${RPORT}/"
  curl_200 "$URL" || die ERROR "$(printf '%s does not answer 200 — that port is not published on the tailnet.\nRun this once on %s:\n  tailscale serve --bg --tcp %s tcp://127.0.0.1:%s\nIt survives reboots and tailscale down/up, so it is a one-time action.' \
    "$URL" "$TARGET" "$RPORT" "$RPORT")" 5
  TUNNEL=tailnet
elif [ "$LOCAL" = 0 ]; then
  LPORT=$RPORT
  if curl_200 "http://127.0.0.1:$LPORT/"; then
    TUNNEL=reused
  else
    # ponytail: two attempts only — preferred port, then any free port
    if ! ssh -f -N -o ExitOnForwardFailure=yes -L "$LPORT:127.0.0.1:$RPORT" -i "$KEY" "$TARGET" 2>/dev/null; then
      LPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
      ssh -f -N -o ExitOnForwardFailure=yes -L "$LPORT:127.0.0.1:$RPORT" -i "$KEY" "$TARGET" 2>/dev/null \
        || die ERROR "ssh local-forward $LPORT→$RPORT failed for $TARGET" 5
    fi
    up=0
    for _ in $(seq 1 20); do curl_200 "http://127.0.0.1:$LPORT/" && { up=1; break; }; sleep 0.5; done
    [ "$up" = 1 ] || die ERROR "tunnel up but http://127.0.0.1:$LPORT/ did not return 200 in 10s" 5
    TUNNEL=created
  fi
  URL="http://127.0.0.1:${LPORT}/"
else
  curl_200 "http://127.0.0.1:$RPORT/" || die ERROR "dashboard-url says port $RPORT but it does not answer locally" 5
fi

# ---------- cmux plumbing (contract: cmux skill) ----------
cmux ping >/dev/null 2>&1 || die ERROR "cmux app not reachable (cmux ping failed)" 5
j() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" "${@:2}"; }

if [ -n "$WINDOW" ]; then
  WIN_UUID=$(cmux rpc window.list | j 'print(next(w["id"] for w in d["windows"] if w["id"]==sys.argv[1] or w["ref"]==sys.argv[1]))' "$WINDOW" 2>/dev/null) \
    || die ERROR "window $WINDOW not found" 5
else
  WIN_UUID=$(cmux rpc workspace.list | j 'print(d["window_id"])')
fi

our_workspaces() {
  cmux rpc workspace.list "{\"window_id\":\"$WIN_UUID\"}" \
    | j 'print("".join("%s\t%s\n"%(w["ref"],w["id"]) for w in d["workspaces"] if w.get("description")=="'"$DESC"'"))'
}
browser_surface() { # $1 ws uuid → first browser surface ref
  cmux rpc surface.list "{\"workspace_id\":\"$1\"}" \
    | j 'print(next((s["ref"] for s in d["surfaces"] if s["type"]=="browser"), ""))'
}

EXISTING_N=$(our_workspaces | grep -c . || true)
[ "$EXISTING_N" -gt 1 ] \
  && die DRIFT "$EXISTING_N workspaces match $DESC — approve cleanup manually" 4

STATUS=OPENED; WS_REF=''; WS_UUID=''
if [ "$EXISTING_N" = 1 ]; then
  STATUS=REUSED
  line=$(our_workspaces | head -1)
  WS_REF=${line%%$'\t'*}; WS_UUID=${line#*$'\t'}
else
  # layout carries the browser surface: one atomic mutation, and unlike a
  # plain new-workspace there is no default terminal pane left behind
  # (verified live against cmux 0.64.22)
  layout=$(python3 -c 'import json,sys; print(json.dumps({"pane":{"surfaces":[{"type":"browser","url":sys.argv[1]}]}}))' "$URL")
  before=$EXISTING_N
  out=$(cmux new-workspace --name "Dashboard · $BASE" --description "$DESC" \
        --window "$WIN_UUID" --focus false --layout "$layout" 2>/dev/null) || true
  WS_REF=$(printf '%s\n' "$out" | grep -o 'workspace:[0-9]*' | head -1 || true)
  for _ in $(seq 1 100); do  # settle: never re-run the mutation
    n=$(our_workspaces | grep -c . || true)
    [ "$n" -gt "$before" ] && break
    sleep 0.05
  done
  [ -z "$WS_REF" ] && WS_REF=$(our_workspaces | awk -F '\t' -v b="$before" 'NR > b {print $1; exit}')
  [ -n "$WS_REF" ] || die ERROR "workspace created but ref unresolvable; state: $(our_workspaces | tr '\n' ' ')" 5
  WS_UUID=$(our_workspaces | awk -F '\t' -v r="$WS_REF" '$1 == r {print $2; exit}')
fi

# browser surface: reuse the existing one, repair only if absent (workspace
# may predate the layout-based creation, e.g. from an earlier buggy run)
#
# Existing is not the same as correct (issue #99). browser_surface() picks by
# type and never looks at the url, and the reuse path only repaired a MISSING
# surface — so the report printed this run's URL while the screen stayed on the
# previous, dead port. That is not a rare state: pack_web binds a fresh port on
# every start unless the project uses --dashboard-port, so after one restart the
# reused surface is ALWAYS stale.
#
# issue #18 proves the port belongs to this project and issue #100 proves the
# project is running; both are about the server. This is the last link: what the
# screen actually shows.
SURF=$(browser_surface "$WS_UUID")
if [ -z "$SURF" ]; then
  out=$(cmux new-surface --type browser --url "$URL" --workspace "$WS_REF" --focus false 2>/dev/null) || true
  for _ in $(seq 1 100); do  # settle by type, then resolve ref by listing
    SURF=$(browser_surface "$WS_UUID")
    [ -n "$SURF" ] && break
    sleep 0.05
  done
  [ -n "$SURF" ] || die ERROR "browser surface in $WS_REF not resolvable after settle" 5
else
  # Read where it actually is, not where it was created. `get-url` answers "this
  # surface, now"; surface.list's url field records what it was opened with, so
  # a human who navigated it — or this verb on an earlier run — would not show
  # up there. Only asked on the reuse path: a surface this run just created
  # already carries the right URL.
  CUR=$(cmux browser --surface "$SURF" get-url 2>/dev/null | tr -d '\r') || CUR=''
  CUR=${CUR%$'\n'}
  if [ "$CUR" != "$URL" ]; then
    # goto, never rebuild: rebuilding throws away the surface's browsing state
    # and is a heavier mutation, and this is the same command a human reaches
    # for to fix it by hand.
    cmux browser --surface "$SURF" goto "$URL" >/dev/null 2>&1 || true
    CUR=$(cmux browser --surface "$SURF" get-url 2>/dev/null | tr -d '\r') || CUR=''
    CUR=${CUR%$'\n'}
    [ "$CUR" = "$URL" ] || die ERROR "browser surface $SURF still points at '${CUR:-<unknown>}' after navigating to $URL — refusing to report success while the report and the screen disagree" 5
  fi
fi

printf 'STATUS=%s\nTUNNEL=%s\nURL=%s\nWORKSPACE=%s\nSURFACE=%s\nROOT=%s\nTARGET=%s\n' \
  "$STATUS" "$TUNNEL" "$URL" "$WS_REF" "$SURF" "$ROOT" "$([ "$LOCAL" = 1 ] && echo local || echo "$TARGET")"
exit 0

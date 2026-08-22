#!/usr/bin/env bash
# open-swarm.sh — open a running SwarmForge swarm as cmux workspaces.
#
# Exit codes / STATUS line:
#   0 OPENED|REUSED   3 STOPPED   4 DRIFT   5 ERROR
# Contract details live in ../SKILL.md (verb: open swarm).
# Depends on bash, python3, cmux. Never starts a stopped swarm, never
# closes anything, never creates a macOS window.
set -euo pipefail

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' WINDOW='' LOCAL=0

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --window) WINDOW=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) sed -n '2,6p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || { sed -n '2,6p' "$0"; exit 2; }

BASE=$(basename "$ROOT")
HOSTPART=local; [ "$LOCAL" = 0 ] && HOSTPART=${TARGET#*@}
DESC="swarmforge:${BASE}@${HOSTPART}"

die() { printf 'STATUS=%s\n%s\n' "$1" "$2"; exit "${3:-5}"; }

# ---------- runtime state (source of truth: the project's own files) ----------
read_file() { # $1 = path under ROOT, quoted for remote shell
  if [ "$LOCAL" = 1 ]; then cat "$ROOT/$1"
  else ssh -i "$KEY" "$TARGET" "cat '$ROOT/$1'"; fi
}

SSH_ERR=$(mktemp); trap 'rm -f "$SSH_ERR"' EXIT
if ! SOCK=$(read_file .swarmforge/tmux-socket 2>"$SSH_ERR"); then
  # local mode: any failure is just a missing file; remote: ssh errors are fatal
  if [ "$LOCAL" = 0 ] && grep -q . "$SSH_ERR"; then
    die ERROR "ssh to $TARGET failed: $(tail -1 "$SSH_ERR")" 5
  fi
  die STOPPED "$ROOT/.swarmforge/tmux-socket missing — swarm not running; refusing to start it" 3
fi
SESSIONS=$(read_file .swarmforge/sessions.tsv) \
  || die STOPPED "$ROOT/.swarmforge/sessions.tsv missing — swarm not running" 3
ROLES=$(read_file .swarmforge/roles.tsv) \
  || die STOPPED "$ROOT/.swarmforge/roles.tsv missing — swarm not running" 3
SOCK=${SOCK%$'\n'}

# runtime gate: socket must actually answer. Stale files after a reboot
# look identical to a live swarm otherwise.
if [ "$LOCAL" = 1 ]; then tmux -S "$SOCK" list-sessions >/dev/null 2>&1 \
  || die STOPPED "socket $SOCK has no tmux server — swarm not running; refusing to start it" 3
else ssh -i "$KEY" "$TARGET" "tmux -S '$SOCK' list-sessions" >/dev/null 2>&1 \
  || die STOPPED "socket $SOCK has no tmux server on $TARGET — swarm not running; refusing to start it" 3
fi

[ -n "$(printf '%s\n' "$SESSIONS" | tr -d '\t\n ')" ] \
  || die STOPPED "sessions.tsv has no rows" 3

MASTER_N=$(printf '%s\n' "$ROLES" | awk -F'\t' '$2 == "master"' | wc -l | tr -d ' ')
[ "$MASTER_N" = 1 ] || die STOPPED "roles.tsv has $MASTER_N master rows, need exactly 1" 3
MASTER_SESSION=$(printf '%s\n' "$ROLES" | awk -F'\t' '$2 == "master" {print $4}')
MASTER_UUID=$(printf '%s\n' "$ROLES" | awk -F'\t' '$2 == "master" {print $1}')

SESSION_LIST=(); DISPLAY_LIST=()
while IFS=$'\t' read -r _idx role session display _backend; do
  [ -n "$session" ] || continue
  SESSION_LIST+=("$session"); DISPLAY_LIST+=("$display")
done <<<"$SESSIONS"
N=${#SESSION_LIST[@]}
[ "$N" -ge 1 ] || die STOPPED "no sessions in sessions.tsv" 3

attach_cmd() { # $1 = session
  if [ "$LOCAL" = 1 ]; then echo "tmux -S '$SOCK' attach -t '$1'"
  else echo "ssh -tt -i $KEY $TARGET 'tmux -S $SOCK attach -t $1'"; fi
}

# ---------- cmux plumbing (contract: cmux skill + automation-patterns) ----------
cmux ping >/dev/null 2>&1 || die ERROR "cmux app not reachable (cmux ping failed)" 5

j() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" "${@:2}"; }

if [ -n "$WINDOW" ]; then
  WIN_UUID=$(cmux rpc window.list | j 'print(next(w["id"] for w in d["windows"] if w["id"]==sys.argv[1] or w["ref"]==sys.argv[1]))' "$WINDOW" 2>/dev/null) \
    || die ERROR "window $WINDOW not found" 5
else
  WIN_UUID=$(cmux rpc workspace.list | j 'print(d["window_id"])')
fi
WIN_REF=$(cmux rpc window.list | j 'print(next(w["ref"] for w in d["windows"] if w["id"]==sys.argv[1]))' "$WIN_UUID")

our_workspaces() { # → "index<TAB>ref<TAB>uuid<TAB>title" lines, index order
  cmux rpc workspace.list "{\"window_id\":\"$WIN_UUID\"}" \
    | j 'print("".join("%d\t%s\t%s\t%s\n"%(w["index"],w["ref"],w["id"],w["title"]) for w in d["workspaces"] if w.get("description")=="'"$DESC"'"))'
}

# surfaces of one workspace, layout order (pane creation order, then in-pane order)
surfaces_of() { # $1 = ws uuid → refs
  cmux rpc surface.list "{\"workspace_id\":\"$1\"}" \
    | j 'ss=sorted(d["surfaces"],key=lambda s:(int(s["pane_ref"].split(":")[1]),s["index_in_pane"])); print(" ".join(s["ref"] for s in ss))'
}

create_workspace() { # $1 name, then 1 or 2 session ids
  local name=$1; shift
  local a1 a2
  a1=$(attach_cmd "$1")
  [ $# -eq 2 ] && a2=$(attach_cmd "$2")
  # json.dumps builds the layout: no hand-counted braces, no shell escaping
  if [ $# -eq 2 ]; then
    layout=$(python3 -c 'import json,sys
def pane(c): return {"pane":{"surfaces":[{"type":"terminal","command":c}]}}
print(json.dumps({"direction":"horizontal","split":0.5,"children":[pane(sys.argv[1]),pane(sys.argv[2])]}))' "$a1" "$a2")
  else
    layout=$(python3 -c 'import json,sys
def pane(c): return {"pane":{"surfaces":[{"type":"terminal","command":c}]}}
print(json.dumps(pane(sys.argv[1])))' "$a1")
  fi
  local before after ref
  # grep -c . : empty listing must count 0 (print("") still emits a newline)
  before=$(our_workspaces | grep -c . || true)
  local out
  out=$(cmux new-workspace --name "$name" --description "$DESC" \
        --window "$WIN_UUID" --focus false --layout "$layout" 2>/dev/null) || true
  ref=$(printf '%s\n' "$out" | grep -o 'workspace:[0-9]*' | head -1 || true)
  # settle: the ref may be absent or garbage. Never re-run the mutation —
  # poll state until our description count grows (automation-patterns.md).
  for _ in $(seq 1 100); do
    after=$(our_workspaces | grep -c . || true)
    [ "$after" -gt "$before" ] && break
    sleep 0.05
  done
  if [ -z "$ref" ]; then
    ref=$(our_workspaces | awk -F'\t' -v b="$before" 'NR > b {print $2; exit}')
  fi
  [ -n "$ref" ] || { echo "create_workspace: could not resolve new workspace ref after settle" >&2; return 1; }
  # settle surfaces too, then emit "wsuuid wsref surf1 surf2..."
  local wsuuid
  for _ in $(seq 1 100); do
    wsuuid=$(our_workspaces | awk -F'\t' -v r="$ref" '$2 == r {print $3; exit}')
    SURFS=$(surfaces_of "${wsuuid:-none}")
    [ -n "$SURFS" ] && break
    sleep 0.05
  done
  [ -n "${SURFS:-}" ] || { echo "create_workspace: workspace $ref has no surfaces after settle" >&2; return 1; }
  echo "$wsuuid $ref $SURFS"
}

verify_surface() { # $1 surface ref, $2 expected display, $3 expected session
  cmux read-screen --surface "$1" --lines 8 2>/dev/null | grep -qF -e "$2" -e "$3"
}

repair_surface() { # clear line, re-type command, submit; then re-verify once
  local s=$1 sess=$2 disp=$3
  cmux send-key --surface "$s" ctrl+u >/dev/null 2>&1 || true
  cmux send --surface "$s" "$(attach_cmd "$sess")"$'\n' >/dev/null 2>&1 || true
  sleep 2
  verify_surface "$s" "$disp" "$sess"
}

# ---------- main: reuse or create ----------
declare -a WS_UUID=() WS_REF=() SURF_REFS=()
EXISTING=$(our_workspaces)
EXPECTED_WS=$(( (N + 1) / 2 ))
EXISTING_N=$(printf '%s\n' "$EXISTING" | grep -c . || true)
[ -z "$EXISTING" ] && EXISTING_N=0

STATUS=OPENED
if [ "$EXISTING_N" = "$EXPECTED_WS" ] && [ "$EXISTING_N" != 0 ]; then
  STATUS=REUSED
  while IFS=$'\t' read -r _i ref uuid _t; do
    [ -n "$ref" ] || continue
    WS_UUID+=("$uuid"); WS_REF+=("$ref")
    read -r -a rs <<<"$(surfaces_of "$uuid")"
    SURF_REFS+=("${rs[@]}")
  done <<<"$EXISTING"
  TOTAL_SURF=${#SURF_REFS[@]}
  [ "$TOTAL_SURF" = "$N" ] \
    || die DRIFT "$EXISTING_N workspaces with description $DESC but $TOTAL_SURF surfaces, runtime expects $N sessions — topology changed; approve close+rebuild manually" 4
elif [ "$EXISTING_N" = 0 ]; then
  i=0
  while [ $i -lt $N ]; do
    if [ $((i + 1)) -lt "$N" ]; then
      NAME="${DISPLAY_LIST[$i]} + ${DISPLAY_LIST[$((i + 1))]}"
      line=$(create_workspace "$NAME" "${SESSION_LIST[$i]}" "${SESSION_LIST[$((i + 1))]}") \
        || die ERROR "pair workspace '$NAME' failed; rerun after checking cmux state" 5
    else
      NAME="${DISPLAY_LIST[$i]}"
      line=$(create_workspace "$NAME" "${SESSION_LIST[$i]}") \
        || die ERROR "tail workspace '$NAME' failed; rerun after checking cmux state" 5
    fi
    read -r u r s1 s2 <<<"$line"
    WS_UUID+=("$u"); WS_REF+=("$r")
    SURF_REFS+=("$s1"); [ -n "${s2:-}" ] && SURF_REFS+=("$s2")
    i=$((i + 2))
  done
else
  die DRIFT "found $EXISTING_N workspaces with description $DESC, expected $EXPECTED_WS (a previous run may be half-done) — approve close+rebuild manually" 4
fi

# ---------- verify every surface, repair stale attaches once ----------
ATTACHED=0 REPAIRED=0 FAILED=0 FAILED_LIST=''
for k in "${!SURF_REFS[@]}"; do
  s=${SURF_REFS[$k]}; disp=${DISPLAY_LIST[$k]}; sess=${SESSION_LIST[$k]}
  good=0
  # fresh ssh attach needs a few seconds; poll before declaring stale
  for _ in $(seq 1 20); do verify_surface "$s" "$disp" "$sess" && { good=1; break; }; sleep 1; done
  if [ "$good" = 0 ] && repair_surface "$s" "$sess" "$disp"; then
    REPAIRED=$((REPAIRED + 1)); good=1
  fi
  if [ "$good" = 1 ]; then ATTACHED=$((ATTACHED + 1)); else
    FAILED=$((FAILED + 1)); FAILED_LIST="$FAILED_LIST $s(${disp})"
  fi
done

# master location: surface index k ↔ SESSION_LIST[k]
MASTER_WS='' MASTER_DISPLAY=''
for k in "${!SESSION_LIST[@]}"; do
  if [ "${SESSION_LIST[$k]}" = "$MASTER_SESSION" ]; then
    # map surface index → owning workspace: walk cumulative surface counts
    cum=0
    for w in "${!WS_REF[@]}"; do
      read -r -a rs <<<"$(surfaces_of "${WS_UUID[$w]}")"
      if [ "$k" -lt $((cum + ${#rs[@]})) ]; then MASTER_WS=${WS_REF[$w]}; break; fi
      cum=$((cum + ${#rs[@]}))
    done
    MASTER_DISPLAY=${DISPLAY_LIST[$k]}
  fi
done

TARGET_OUT=$TARGET; [ "$LOCAL" = 1 ] && TARGET_OUT=local
printf 'STATUS=%s\nTARGET=%s\nROOT=%s\nWINDOW=%s\nWORKSPACES=%s\n' \
  "$STATUS" "$TARGET_OUT" "$ROOT" "$WIN_REF" \
  "$(printf '%s\n' "${WS_REF[@]}" | paste -sd, -)"
printf 'ATTACHED=%d\nREPAIRED=%d\nFAILED=%d\n' "$ATTACHED" "$REPAIRED" "$FAILED"
[ -n "$MASTER_DISPLAY" ] && printf 'MASTER_DISPLAY=%s\nMASTER_WS=%s\n' "$MASTER_DISPLAY" "$MASTER_WS"
[ -n "$FAILED_LIST" ] && printf 'FAILED_SURFACES=%s\n' "${FAILED_LIST# }"
[ "$FAILED" = 0 ] || exit 5
exit 0

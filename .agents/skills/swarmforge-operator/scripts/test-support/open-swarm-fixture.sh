#!/usr/bin/env bash
# Local runtime and cmux state; terminal commands are checked, never executed.
setup_real() {
  FIXTURE=$(mktemp -d "$WORK/open-swarm.XXXXXX")
  # TMPDIR can end in /; keep shell paths equal to Python's normalized paths.
  FIXTURE=$(cd "$FIXTURE" && pwd)
  REAL_ROOT="$FIXTURE/forge/projects/demo with spaces"
  mkdir -p "$REAL_ROOT/.swarmforge" "$FIXTURE/bin"
  : > "$FIXTURE/forge/swarm"
  printf '%s\n' "$FIXTURE/socket" > "$REAL_ROOT/.swarmforge/tmux-socket"
  printf '1\tintake\tsession-intake\tGate\tgrok\n2\tbuilder\tsession-builder\tBuild\tgrok\n3\tchecker\tsession-checker\tVerify\tgrok\n' > "$REAL_ROOT/.swarmforge/sessions.tsv"
  printf 'intake\tmaster\t%s\tsession-intake\tGate\tgrok\tqueue\n' "$REAL_ROOT" > "$REAL_ROOT/.swarmforge/roles.tsv"
  printf '{"workspaces": [], "surfaces": []}\n' > "$FIXTURE/state.json"
  cat > "$FIXTURE/commands.py" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import sys

root = Path(os.environ['OPEN_FIXTURE'])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps([command, *args]) + '\n')

def reject():
    with (root / 'blocked').open('a') as log:
        log.write(json.dumps([command, *args]) + '\n')
    sys.exit(97)

if command == 'tmux':
    if args != ['-S', str(root / 'socket'), 'list-sessions']:
        reject()
    sys.exit(0)
if command != 'cmux':
    reject()
state_file = root / 'state.json'
state = json.loads(state_file.read_text())
if args == ['ping']:
    print('PONG')
elif args == ['rpc', 'window.list']:
    print(json.dumps({'windows': [{'id': 'W1', 'ref': 'window:1'}]}))
elif args in (['rpc', 'workspace.list'], ['rpc', 'workspace.list', '{"window_id":"W1"}']):
    print(json.dumps({'window_id': 'W1', 'workspaces': state['workspaces']}))
elif len(args) == 3 and args[:2] == ['rpc', 'surface.list']:
    query = json.loads(args[2])
    if set(query) != {'workspace_id'} or query['workspace_id'] not in [w['id'] for w in state['workspaces']]:
        reject()
    print(json.dumps({'surfaces': [s for s in state['surfaces'] if s['workspace_id'] == query['workspace_id']]}))
elif len(args) == 11 and args[:1] == ['new-workspace']:
    if args[1::2] != ['--name', '--description', '--window', '--focus', '--layout']:
        reject()
    options = dict(zip(args[1::2], args[2::2]))
    if options['--window'] != 'W1' or options['--focus'] != 'false':
        reject()
    layout = json.loads(options['--layout'])
    panes = layout['children'] if 'children' in layout else [layout]
    index = len(state['workspaces'])
    if index >= 2:
        reject()
    sessions = [['session-intake', 'session-builder'], ['session-checker']][index]
    if len(panes) != len(sessions):
        reject()
    if len(sessions) == 2 and (layout.get('direction') != 'horizontal' or layout.get('split') != 0.5):
        reject()
    ws = {'id': 'WS' + str(index + 1), 'ref': 'workspace:' + str(index + 11),
          'index': index, 'title': options['--name'], 'description': options['--description']}
    for pane_index, (pane, session) in enumerate(zip(panes, sessions)):
        surfaces = pane['pane']['surfaces']
        if len(surfaces) != 1 or surfaces[0]['type'] != 'terminal':
            reject()
        terminal = surfaces[0]['command']
        if shlex.split(terminal) != ['tmux', '-S', str(root / 'socket'), 'attach', '-t', session]:
            reject()
        state['surfaces'].append({'workspace_id': ws['id'], 'ref': 'surface:' + str(101 + len(state['surfaces'])),
                                  'pane_ref': 'pane:' + str(201 + pane_index), 'index_in_pane': 0,
                                  'session': session, 'command': terminal})
    state['workspaces'].append(ws)
    state_file.write_text(json.dumps(state))
    print('OK ' + ws['ref'])
elif len(args) == 5 and args[0] == 'read-screen' and args[1] == '--surface' and args[3:] == ['--lines', '8']:
    surface = next((s for s in state['surfaces'] if s['ref'] == args[2]), None)
    if surface is None:
        reject()
    print(surface['session'])
else:
    reject()
PY
  chmod +x "$FIXTURE/commands.py"
  local cmd
  for cmd in tmux cmux ssh curl git gh tailscale; do
    ln -s ../commands.py "$FIXTURE/bin/$cmd"
  done
  REAL_ENV=("PATH=$FIXTURE/bin:$PATH" "OPEN_FIXTURE=$FIXTURE")
  REAL_ARGS=(--root "$REAL_ROOT" --local)
}
assert_real() {
  check 'real root reported' "$REAL_ROOT" "$(field ROOT)"
  check 'local target reported' local "$(field TARGET)"
  check 'existing window reported' window:1 "$(field WINDOW)"
  check 'paired workspace and odd tail reported' workspace:11,workspace:12 "$(field WORKSPACES)"
  check 'all runtime sessions attached' 3 "$(field ATTACHED)"
  check 'master display comes from runtime' Gate "$(field MASTER_DISPLAY)"
  check 'master workspace reported' workspace:11 "$(field MASTER_WS)"
  check 'no fake result' no "$(grep -q '^ADAPTER=fake$' "$WORK/err" && echo yes || echo no)"
  local verified rc=0
  verified=$(python3 - "$FIXTURE" <<'PY'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1])
state = json.loads((p / 'state.json').read_text())
f = p / 'calls.jsonl'
calls = [json.loads(line) for line in f.read_text().splitlines()] if f.exists() else []
creates = [c for c in calls if c[:2] == ['cmux', 'new-workspace']]
reads = [c[3] for c in calls if c[:2] == ['cmux', 'read-screen']]
print('yes' if len(creates) == 2 and len(state['surfaces']) == 3
      and [w['title'] for w in state['workspaces']] == ['Gate + Build', 'Verify']
      and all(w['description'] == 'swarmforge:demo with spaces@local' for w in state['workspaces'])
      and reads == ['surface:101', 'surface:102', 'surface:103']
      and calls[0] == ['tmux', '-S', str(p / 'socket'), 'list-sessions'] else 'no')
PY
)
  check 'runtime gate, pairing and each screen verified' yes "$verified"
  cp "$FIXTURE/state.json" "$FIXTURE/before-reuse.json"
  env "${REAL_ENV[@]}" SF_ADAPTER=real "$ENTRY" "${REAL_ARGS[@]}" \
    > "$FIXTURE/reuse.out" 2> "$FIXTURE/reuse.err" || rc=$?
  check 'reuse exit' 0 "$rc"
  check 'reuse status' STATUS=REUSED "$(head -1 "$FIXTURE/reuse.out")"
  check 'reuse does not create more workspaces' yes \
    "$(cmp -s "$FIXTURE/before-reuse.json" "$FIXTURE/state.json" && echo yes || echo no)"
  check 'reuse verifies all attachments' ATTACHED=3 "$(grep '^ATTACHED=' "$FIXTURE/reuse.out")"
  check 'no unexpected external operation' yes "$([ ! -e "$FIXTURE/blocked" ] && echo yes || echo no)"
}
cleanup_real() { :; }

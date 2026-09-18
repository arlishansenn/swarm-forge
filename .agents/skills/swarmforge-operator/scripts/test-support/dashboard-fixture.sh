#!/usr/bin/env bash
# Local runtime and command fixtures; never opens a real browser or tunnel.
setup_real() {
  FIXTURE=$(mktemp -d "$WORK/dashboard.XXXXXX")
  REAL_ROOT="$FIXTURE/forge/projects/demo with spaces"
  mkdir -p "$REAL_ROOT/.swarmforge" "$FIXTURE/bin"
  : > "$FIXTURE/forge/swarm"
  printf '%s\n' "$FIXTURE/socket" > "$REAL_ROOT/.swarmforge/tmux-socket"
  printf 'http://127.0.0.1:54870/\n' > "$REAL_ROOT/.swarmforge/dashboard-url"
  printf '501\n' > "$REAL_ROOT/.swarmforge/pack_web.pid"
  printf '{"workspaces": [], "surfaces": []}\n' > "$FIXTURE/state.json"
  cat > "$FIXTURE/commands.py" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import sys

root = Path(os.environ['DASH_FIXTURE'])
project = os.environ['DASH_ROOT']
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps([command, *args]) + '\n')

def reject():
    with (root / 'blocked').open('a') as log:
        log.write(command + '\n')
    sys.exit(97)

if command == 'tmux':
    if args != ['-S', os.environ['DASH_FIXTURE'] + '/socket', 'list-sessions']:
        reject()
elif command == 'ps':
    if args != ['-wwp', '501', '-o', 'command=']:
        reject()
    print('bb pack_web.bb --serve ' + shlex.quote(project) + ' 54870')
elif command == 'curl':
    if args != ['-s', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '3', 'http://127.0.0.1:54870/']:
        reject()
    print('200')
elif command == 'cmux':
    state_path = root / 'state.json'
    state = json.loads(state_path.read_text())
    if args == ['ping']:
        print('PONG')
    elif args[:2] == ['rpc', 'workspace.list']:
        print(json.dumps({'window_id': 'W1', 'workspaces': state['workspaces']}))
    elif args[:2] == ['rpc', 'surface.list']:
        query = json.loads(args[2])
        print(json.dumps({'surfaces': [s for s in state['surfaces'] if s['workspace_id'] == query['workspace_id']]}))
    elif args[:1] == ['new-workspace']:
        options = dict(zip(args[1::2], args[2::2]))
        layout = json.loads(options['--layout'])
        if state['workspaces'] or options['--focus'] != 'false':
            reject()
        state['workspaces'].append({'id': 'WS1', 'ref': 'workspace:11', 'description': options['--description']})
        for index, surface in enumerate(layout['pane']['surfaces']):
            state['surfaces'].append(dict(surface, workspace_id='WS1', ref='surface:' + str(101 + index)))
        state_path.write_text(json.dumps(state))
        print('OK workspace:11')
    elif args == ['browser', '--surface', 'surface:101', 'get-url']:
        print(state['surfaces'][0]['url'])
    else:
        reject()
else:
    reject()
PY
  chmod +x "$FIXTURE/commands.py"
  local cmd
  for cmd in cmux tmux ps curl ssh tailscale gh; do
    ln -s ../commands.py "$FIXTURE/bin/$cmd"
  done
  REAL_ENV=("PATH=$FIXTURE/bin:$PATH" "DASH_FIXTURE=$FIXTURE" "DASH_ROOT=$REAL_ROOT")
  REAL_ARGS=(--root "$REAL_ROOT" --local)
}
assert_real() {
  check 'real root reported' "$REAL_ROOT" "$(field ROOT)"
  check 'local target reported' local "$(field TARGET)"
  check 'local transport reported' local "$(field TUNNEL)"
  check 'real workspace reported' workspace:11 "$(field WORKSPACE)"
  check 'real surface reported' surface:101 "$(field SURFACE)"
  check 'no fake result' no "$(grep -q '^ADAPTER=fake$' "$WORK/err" && echo yes || echo no)"
  check 'no unexpected external operation' yes "$([ ! -e "$FIXTURE/blocked" ] && echo yes || echo no)"
  local verified
  verified=$(python3 - "$FIXTURE" "$REAL_ROOT" <<'PY'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1])
state = json.loads((p / 'state.json').read_text())
calls_file = p / 'calls.jsonl'
calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
expected = ['tmux', 'ps', 'curl', 'cmux']
observed = [call[0] for call in calls]
surface = state['surfaces']
print('yes' if all(name in observed for name in expected)
      and observed.index('tmux') < observed.index('ps') < observed.index('curl') < observed.index('cmux')
      and len(state['workspaces']) == 1 and len(surface) == 1
      and state['workspaces'][0]['description'] == 'swarmforge-dashboard:demo with spaces@local'
      and surface[0]['type'] == 'browser' and surface[0]['url'] == 'http://127.0.0.1:54870/'
      and calls.count(['cmux', 'browser', '--surface', 'surface:101', 'get-url']) == 1 else 'no')
PY
)
  check 'ownership and reachability precede verified browser creation' yes "$verified"
}
cleanup_real() { :; }

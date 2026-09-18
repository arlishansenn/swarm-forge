#!/usr/bin/env bash
# Local installer, real HTTP handshake and real start-swarm.sh; no host services.
setup_real() {
  FIXTURE=$(mktemp -d "$WORK/provision.XXXXXX")
  REAL_ROOT="$FIXTURE/forge with spaces"
  mkdir -p "$FIXTURE/bin"
  cat > "$FIXTURE/dashboard_server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys
root = Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        with (root / 'requests').open('a') as log:
            log.write('GET\n')
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')
server = HTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
PY
  python3 "$FIXTURE/dashboard_server.py" "$FIXTURE" > "$FIXTURE/http.log" 2>&1 &
  SERVER_PID=$!
  local i
  for i in $(seq 1 100); do
    [ -s "$FIXTURE/port" ] && break
    sleep 0.05
  done
  if [ ! -s "$FIXTURE/port" ]; then
    cat "$FIXTURE/http.log" >&2
    return 1
  fi
  PORT=$(cat "$FIXTURE/port")
  cat > "$FIXTURE/launcher" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$SWARMFORGE_TERMINAL" > "$PROVISION_FIXTURE/launched"
mkdir -p .swarmforge
printf '%s\n' "$PROVISION_FIXTURE/socket" > .swarmforge/tmux-socket
printf 'http://127.0.0.1:%s/\n' "$SWARMFORGE_DASHBOARD_PORT" > .swarmforge/dashboard-url
: > "$PROVISION_FIXTURE/live"
SH
  cat > "$FIXTURE/installer" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$1" >> "$PROVISION_FIXTURE/installed"
mkdir -p swarmforge/scripts projects
printf 'reconcile-once!\n' > swarmforge/scripts/handoffd.bb
printf 'roles.tsv\n' > swarmforge/scripts/handoff_lib.bb
cp "$PROVISION_FIXTURE/launcher" swarm
chmod +x swarm
printf 'installer chatter\n'
SH
  cat > "$FIXTURE/bin/tmux" <<'SH'
#!/bin/bash
[ "$#" -eq 3 ] && [ "$1" = -S ] &&
  [ "$2" = "$PROVISION_FIXTURE/socket" ] && [ "$3" = list-sessions ] &&
  [ -f "$PROVISION_FIXTURE/live" ]
SH
  # Allow only the two local curl destinations used by this fixture.
  REAL_CURL=$(command -v curl)
  cat > "$FIXTURE/bin/curl" <<'SH'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    "$PROVISION_HELPER_URL"|"http://127.0.0.1:$PROVISION_PORT/")
      exec "$PROVISION_CURL" --noproxy '*' "$@" ;;
  esac
done
printf 'blocked curl\n' >> "$PROVISION_FIXTURE/blocked"
exit 97
SH
  for cmd in ssh cmux gh; do
    printf '#!/bin/bash\nprintf "blocked command\\n" >> "$PROVISION_FIXTURE/blocked"\nexit 97\n' > "$FIXTURE/bin/$cmd"
  done
  chmod +x "$FIXTURE/installer" "$FIXTURE/launcher" "$FIXTURE/bin/"*
  HELPER_URL=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$FIXTURE/installer")
  # start-swarm.sh runs git_tracked; an inherited GIT_DIR would answer from the
  # caller's repository instead of the fixture. git -C cannot override it.
  REAL_ENV=(-u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE
    "PATH=$FIXTURE/bin:$PATH" "PROVISION_FIXTURE=$FIXTURE"
    "PROVISION_CURL=$REAL_CURL" "PROVISION_HELPER_URL=$HELPER_URL" "PROVISION_PORT=$PORT"
    "SWARMFORGE_HELPER_URL=$HELPER_URL" "SWARM_LAUNCHER=$REAL_ROOT/swarm"
    SF_START_READY_TRIES=30 SF_START_READY_INTERVAL=0.1 SF_DASH_TRIES=10 SF_DASH_INTERVAL=0.1)
  REAL_ARGS=(--root "$REAL_ROOT" --forge lieutenant --dashboard-port "$PORT" --terminal none --local)
}
assert_real() {
  check 'installer executed for lieutenant' lieutenant "$(cat "$FIXTURE/installed" 2>/dev/null)"
  check 'launcher used explicit terminal' none "$(cat "$FIXTURE/launched" 2>/dev/null)"
  check 'manifest was written' yes "$([ -s "$REAL_ROOT/.swarmforge/scripts-manifest" ] && echo yes || echo no)"
  check 'dashboard HTTP was reached' yes "$([ -s "$FIXTURE/requests" ] && echo yes || echo no)"
  check 'reported root is the real fixture' "$REAL_ROOT" "$(field ROOT)"
  check 'reported URL is the local server' "http://127.0.0.1:$PORT/" "$(field URL)"
  check 'no fake result' no "$(grep -q '^ADAPTER=fake$' "$WORK/err" && echo yes || echo no)"
  check 'no external operation' yes "$([ ! -e "$FIXTURE/blocked" ] && echo yes || echo no)"
}
cleanup_real() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=''
  fi
}

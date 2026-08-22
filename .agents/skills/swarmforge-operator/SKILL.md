---
name: swarmforge-operator
description: "Use when operating a running SwarmForge project from the local machine: opening its role sessions in cmux, reading role state, waking or messaging a role, or stopping the swarm."
---

# SwarmForge Operator

Operate a running SwarmForge project from the local machine. SwarmForge is
config-driven: derive the active topology from the target project's runtime
state instead of branching on two-pack, four-pack, six-pack, or role names.

**REQUIRED SUB-SKILL:** `cmux`. Load it before any cmux operation you perform
yourself (creating a window the user asked for, drift recovery, inspecting a
surface). The bundled `open-swarm.sh` script already follows the cmux contract
internally; do not re-implement its mechanics.

## Runtime inputs

Set the target project for every verb. The macmini values are defaults, not
part of the topology:

```sh
TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT=${ROOT:?set ROOT to the remote project root}
SSH=(ssh -i "$KEY" "$TARGET")

SOCK=$("${SSH[@]}" "cat '$ROOT/.swarmforge/tmux-socket'")
SESSIONS=$("${SSH[@]}" "cat '$ROOT/.swarmforge/sessions.tsv'")
ROLES=$("${SSH[@]}" "cat '$ROOT/.swarmforge/roles.tsv'")
MASTER=$(printf '%s\n' "$ROLES" | awk -F '\t' '$2 == "master" {print $1}')
```

Runtime files are the source of truth after launch:

- `tmux-socket`: plain text containing the real socket path. Resolve it again
after every `./swarm` restart.
- `sessions.tsv`: config order, role, session, display name, agent backend.
- `roles.tsv`: role, worktree name/path, session, display name, backend, receive
mode. The row whose worktree name is `master` is the intake role.

Stop if a runtime file is missing, the socket has no sessions, or there is not
exactly one master row. A host can run several projects; only touch state under
`ROOT` and the socket read from that project.

## Verb: `open swarm`

Run the bundled script from this skill's directory; it owns all cmux mechanics
(settle, output parsing, workspace reuse, attach verification):

```sh
scripts/open-swarm.sh --root <project-root> [--window <ref>] \
  [--target user@host] [--key <path>] [--local]
```

It reads the runtime files, gates on a live tmux socket, pairs adjacent
sessions from `sessions.tsv` into `<Display 1> + <Display 2>` workspaces (an
odd tail becomes a single-pane workspace), reuses an existing workspace set
matched by description `swarmforge:<basename>@<host>`, re-sends attach to
stale surfaces once, then verifies every surface shows its session.

Read the result from its output and exit code:

- `0` `STATUS=OPENED|REUSED` — report `WORKSPACES`, `ATTACHED`, `REPAIRED`,
  `MASTER_DISPLAY`/`MASTER_WS` to the user. The script leaves the user's
  focus untouched; name where the master lives instead of focusing it.
- `3` `STOPPED` — the swarm is not running. Report the reason and stop.
- `4` `DRIFT` — cmux state disagrees with runtime files (half-finished run or
  changed topology). Ask the user before closing or re-creating anything.
- `5` `ERROR` — show the message; check cmux state before retrying. Never
  "probe" by re-running a create that may have succeeded.

Hard rules for this verb:

- **Never start a stopped swarm.** No `./swarm`, no restart, no matter how
  likely the user "meant" it. Starting is a human decision; `open` only
  connects to what already runs.
- **No macOS window by default.** The script targets the caller's current
  window. Only when the user explicitly asks for a new window, create it
  yourself per the cmux skill and pass `--window <ref>`.
- **No destructive cleanup without explicit user approval** — the script
  closes nothing, and neither should you.

## Verb: `attach role`

Find the role in `sessions.tsv` and use its recorded session; do not construct
a session from a hardcoded role list:

```sh
ssh -tt -i "$KEY" "$TARGET" "tmux -S '$SOCK' attach -t '$SESSION'"
```

## Verb: `read swarm`

Iterate `sessions.tsv` in config order and capture each recorded session:

```sh
while IFS=$'\t' read -r index role session display agent; do
  printf '%-16s | ' "$role"
  "${SSH[@]}" "tmux -S '$SOCK' capture-pane -p -t '$session' -S -12" \
    | grep -v '^$' | tail -1
done <<< "$SESSIONS"
```

An empty prompt is idle. `Working` is busy. A visible handoff-mail notice on an
idle role means it needs `wake role`.

## Verb: `wake role`

Look up both session and backend in `sessions.tsv`, type
`ready_for_next.sh`, wait for the text to appear, then submit with the backend's
key encoding:

```sh
tmux -S "$SOCK" send-keys -t "$SESSION" -l "ready_for_next.sh"
sleep 1
# claude
tmux -S "$SOCK" send-keys -t "$SESSION" -H 1b 5b 31 33 75
# codex, copilot, or grok
tmux -S "$SOCK" send-keys -t "$SESSION" C-m
tmux -S "$SOCK" send-keys -t "$SESSION" C-j
```

Run those tmux commands on the target host. Use only the branch matching the
recorded backend.

## Verb: `talk role`

Look up the role exactly as for `wake role`, send one behavior slice with
`send-keys -l`, then use the same backend-specific submit key. New work enters
through the `master` row from `roles.tsv`; no role name such as `specifier` or
`coder` is universally the intake role.

## Verb: `stop swarm`

Use the project root with the official control checkout on the target host:

```sh
"${SSH[@]}" "/Users/admin/project/swarm-forge/close-swarm '$ROOT'"
```

If cleanup is incomplete, resolve this project's socket again, kill only that
tmux server, and match `handoffd.bb` with the exact project root. Verify other
project daemons remain running.

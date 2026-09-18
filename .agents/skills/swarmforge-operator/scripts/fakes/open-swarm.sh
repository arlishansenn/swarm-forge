#!/usr/bin/env bash
# Fixed sample only; no real operation is performed.
printf 'ADAPTER=fake\n' >&2
printf '%s' 'STATUS=OPENED
ROOT=/fake/forge/projects/demo
TARGET=fake
WINDOW=window:fake
WORKSPACES=workspace:fake
ATTACHED=1
REPAIRED=0
FAILED=0
'

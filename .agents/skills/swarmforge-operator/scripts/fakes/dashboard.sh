#!/usr/bin/env bash
# Fixed sample only; no real operation is performed.
printf 'ADAPTER=fake\n' >&2
printf '%s' 'STATUS=OPENED
TUNNEL=fake
URL=http://127.0.0.1:7782
WORKSPACE=workspace:fake
SURFACE=surface:fake
ROOT=/fake/forge/projects/demo
TARGET=fake
'

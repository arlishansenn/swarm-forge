#!/usr/bin/env bash
# Fixed sample only; no real operation is performed.
printf 'ADAPTER=fake\n' >&2
printf '%s' 'STATUS=PROVISIONED
ROOT=/fake/forge
FORGE=lieutenant
URL=http://127.0.0.1:7782
TARGET=fake
'

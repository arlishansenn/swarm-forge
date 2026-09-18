#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VERB=wake-role
REAL_SCRIPT=wake-role.sh
EXPECTED_STATUS=WOKEN
FIELDS='ROLE SESSION'
DEFAULT_ADAPTER=real
. "$HERE/test-support/wake-fixture.sh"
. "$HERE/test-support/verb-contract.sh"

#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VERB=dashboard
REAL_SCRIPT=open-dashboard.sh
EXPECTED_STATUS=OPENED
FIELDS='TUNNEL URL WORKSPACE SURFACE ROOT TARGET'
DEFAULT_ADAPTER=real
. "$HERE/test-support/dashboard-fixture.sh"
. "$HERE/test-support/verb-contract.sh"

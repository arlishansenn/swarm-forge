#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bb --classpath "$SCRIPT_DIR" "$SCRIPT_DIR/done_with_current.bb" "$@"

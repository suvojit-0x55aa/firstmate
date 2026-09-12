#!/usr/bin/env bash
# Exit 0 once the given epoch second has been reached, 1 otherwise.
#
# Usage: fm-time-reached.sh <epoch>
#
# Test-only override:
#   FM_QUOTA_NOW_OVERRIDE  epoch second to treat as "now" instead of date +%s
set -u

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

EPOCH=${1:-}
case "$EPOCH" in
  ''|*[!0-9]*) die "usage: fm-time-reached.sh <epoch> (got: ${EPOCH:-<empty>})" ;;
esac

NOW=${FM_QUOTA_NOW_OVERRIDE:-$(date +%s)}
[ "$NOW" -ge "$EPOCH" ]

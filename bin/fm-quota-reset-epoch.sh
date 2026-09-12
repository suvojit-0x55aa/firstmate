#!/usr/bin/env bash
# Print the epoch second at which a quota provider's binding usage window
# resets, read deterministically from `quota-axi --provider <name> --json`.
#
# Quota is account-wide, not per-task: this script never peeks a crewmate's
# pane or reads any task-local state. It queries quota-axi once and reports
# the exact resetsAt it returns.
#
# Usage: fm-quota-reset-epoch.sh [--provider <name>]
#   --provider <name>  quota-axi provider id (default: claude)
#
# Resolution:
#   1. Run `quota-axi --provider <name> --json` (bounded by
#      FM_QUOTA_AXI_TIMEOUT_SECS, default 15s).
#   2. Find the provider's effectiveAvailability entry with scope=all_models,
#      then read its limitingWindowIds - the window(s) actually binding
#      account-wide availability right now.
#   3. Look up each named window in windows[] and take the EARLIEST resetsAt
#      among them (an account can be bound by more than one limiting window
#      at once; the earliest one is what actually unblocks the account).
#   4. Parse that ISO8601 timestamp to an epoch second and print it.
#
# On any failure - quota-axi missing/incompatible, the query timing out or
# exiting nonzero, or a response with no all_models scope, no limiting
# windows, or an unparseable resetsAt - this prints nothing and exits
# nonzero with a distinct message on stderr. There is no silent fallback:
# a caller must never treat a missing epoch as "no reset pending".
#
# Test-only overrides:
#   FM_QUOTA_AXI_CMD          quota-axi command to run (default: quota-axi)
#   FM_QUOTA_AXI_TIMEOUT_SECS bound on the --json query, in seconds (default: 15)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

PROVIDER=claude
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)
      [ $# -ge 2 ] || die "--provider requires a value"
      PROVIDER=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

QUOTA_AXI_CMD="${FM_QUOTA_AXI_CMD:-quota-axi}"
TIMEOUT_SECS="${FM_QUOTA_AXI_TIMEOUT_SECS:-15}"

command -v jq >/dev/null 2>&1 || die "jq is required to parse quota-axi output"

fm_quota_axi_compatible "$TIMEOUT_SECS" "$QUOTA_AXI_CMD" ||
  die "quota-axi is missing, incompatible, or did not respond to --version within ${TIMEOUT_SECS}s"

JSON=$(fm_quota_axi_query_json "$PROVIDER" "$TIMEOUT_SECS" "$QUOTA_AXI_CMD") ||
  die "quota-axi --provider $PROVIDER --json failed or timed out after ${TIMEOUT_SECS}s"

printf '%s\n' "$JSON" | jq -e . >/dev/null 2>&1 ||
  die "quota-axi returned output that is not valid JSON"

RESETS_AT=$(printf '%s\n' "$JSON" | jq -r --arg provider "$PROVIDER" '
  (.providers[]? | select(.provider == $provider)) as $p |
  ($p.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")) as $avail |
  ($avail.limitingWindowIds // [])[] as $wid |
  ($p.windows[]? | select(.id == $wid) | .resetsAt)
' 2>/dev/null | sort | head -1)

[ -n "$RESETS_AT" ] ||
  die "quota-axi response for provider $PROVIDER has no all_models limiting window with a resolvable resetsAt"

# Normalize ISO8601 for portable parsing: drop fractional seconds, and turn a
# trailing Z or +HH:MM/-HH:MM offset into the form each date implementation
# accepts (BSD date wants "+HHMM", GNU date accepts the colon form as-is).
NORMALIZED=$(printf '%s\n' "$RESETS_AT" | sed -E 's/\.[0-9]+//; s/Z$/+0000/')
case "$NORMALIZED" in
  *+[0-9][0-9]:[0-9][0-9]) NORMALIZED=${NORMALIZED%:*}${NORMALIZED##*:} ;;
  *-[0-9][0-9]:[0-9][0-9]) NORMALIZED=${NORMALIZED%:*}${NORMALIZED##*:} ;;
esac

EPOCH=$(date -u -d "$NORMALIZED" +%s 2>/dev/null) ||
  EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$NORMALIZED" +%s 2>/dev/null)

case "$EPOCH" in
  ''|*[!0-9]*) die "could not parse resetsAt timestamp: $RESETS_AT" ;;
esac

printf '%s\n' "$EPOCH"

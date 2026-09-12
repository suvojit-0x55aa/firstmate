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
#      account-wide availability right now. Every named id must resolve to a
#      windows[] entry; one that does not is a loud failure, never a window
#      quietly dropped from the comparison.
#   3. Look up each named window in windows[], parse every one of their
#      ISO8601 resetsAt values to an epoch second, and print the LARGEST.
#      Several windows tie at the same limiting floor exactly when each of
#      them is equally exhausted, and the account stays blocked until the
#      LAST of them clears - waking at an earlier one would spend the
#      watch's single fire while the crewmate is still blocked. Comparing
#      parsed epochs rather than the raw strings keeps the answer correct
#      when the windows carry different UTC offsets.
#
# On any failure - quota-axi missing/incompatible, the query timing out or
# exiting nonzero, or a response with no all_models scope, no limiting
# windows, a limiting window id absent from windows[], or an unparseable
# resetsAt - this prints nothing and exits
# nonzero with a distinct message on stderr. There is no silent fallback:
# a caller must never treat a missing epoch as "no reset pending".
#
# Test-only overrides:
#   FM_QUOTA_AXI_CMD          quota-axi command to run (default: quota-axi)
#   FM_QUOTA_AXI_TIMEOUT_SECS bound on the --json query, in seconds (default: 15)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,${/^set -u$/q; s/^# \{0,1\}//; p;}' "$0"; }

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
      usage
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

# One line per limiting window id, as "<id><TAB><resetsAt>". The resetsAt
# field is empty when the id names no windows[] entry at all, which the loop
# below refuses rather than comparing whatever happened to resolve.
LIMITING_WINDOWS=$(printf '%s\n' "$JSON" | jq -r --arg provider "$PROVIDER" '
  (.providers[]? | select(.provider == $provider)) as $p |
  ($p.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")) as $avail |
  ($avail.limitingWindowIds // [])[] as $wid |
  [$p.windows[]? | select(.id == $wid)] as $matched |
  "\($wid)\t\(if ($matched | length) == 0 then "" else ($matched[0].resetsAt // "null") end)"
' 2>/dev/null)

[ -n "$LIMITING_WINDOWS" ] ||
  die "quota-axi response for provider $PROVIDER has no all_models limiting window"

# Normalize ISO8601 for portable parsing: drop fractional seconds, and turn a
# trailing Z or +HH:MM/-HH:MM offset into the form each date implementation
# accepts (BSD date wants "+HHMM", GNU date accepts the colon form as-is).
resets_at_to_epoch() {
  local raw=$1 normalized epoch
  normalized=$(printf '%s\n' "$raw" | sed -E 's/\.[0-9]+//; s/Z$/+0000/')
  case "$normalized" in
    *+[0-9][0-9]:[0-9][0-9]|*-[0-9][0-9]:[0-9][0-9])
      normalized=${normalized%:*}${normalized##*:}
      ;;
  esac
  epoch=$(date -u -d "$normalized" +%s 2>/dev/null) ||
    epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" +%s 2>/dev/null)
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$epoch"
}

# Compare parsed epochs, never the raw strings: two limiting windows can carry
# different UTC offsets, and a lexicographic comparison would then order them
# by wall-clock text rather than by instant.
EPOCH=''
while IFS=$'\t' read -r wid resets_at; do
  [ -n "$wid" ] || continue
  [ -n "$resets_at" ] ||
    die "quota-axi response for provider $PROVIDER names limiting window $wid, which has no entry in windows[]"
  candidate=$(resets_at_to_epoch "$resets_at") ||
    die "could not parse resetsAt timestamp for limiting window $wid: $resets_at"
  if [ -z "$EPOCH" ] || [ "$candidate" -gt "$EPOCH" ]; then
    EPOCH=$candidate
  fi
done <<EOF
$LIMITING_WINDOWS
EOF

[ -n "$EPOCH" ] ||
  die "quota-axi response for provider $PROVIDER has no all_models limiting window"

printf '%s\n' "$EPOCH"

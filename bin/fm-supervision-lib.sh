# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because its committed
# active-supervision snapshot has live work, because it has a registered check,
# or because it has a registered process-to-event source, and whether its
# watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of active snapshot entries/reservations
#   FM_SUP_CHECKS         count of registered watcher checks
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source check beat m age check_root check_protocol
  local snapshot protocol generation kind task field3 field4 extra snapshot_valid=false
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  # The generation snapshot is the sole recurring owner of task liveness.  A
  # .meta file is a durable lifecycle record and may intentionally outlive its
  # endpoint, so counting the archive here recreates the stale-inventory bug the
  # registry was introduced to prevent.  Homes predating the registry retain a
  # conservative one-time compatibility fallback until startup recovery creates
  # their first snapshot; an EMPTY valid snapshot is authoritative.
  snapshot="$state/.active-supervision-generation"
  if [ -f "$snapshot" ] && [ ! -L "$snapshot" ]; then
    IFS="$(printf '\t')" read -r protocol generation extra < "$snapshot" || protocol=
    case "$protocol:$generation:$extra" in
      fm-active-supervision.v[2-6]:?*:)
        snapshot_valid=true
        while IFS="$(printf '\t')" read -r kind task field3 field4 extra; do
          [ -n "$kind" ] || continue
          case "$kind:$task:$field3:$field4:$extra" in
            entry:?*:?*:pending:|entry:?*:?*:active:|reservation:?*:?*:*:*)
              FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
              ;;
            *) snapshot_valid=false; break ;;
          esac
        done < <(sed '1d' "$snapshot")
        ;;
    esac
  fi
  if [ "$snapshot_valid" != true ]; then
    FM_SUP_IN_FLIGHT=0
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
    done
  fi
  FM_SUP_CHECKS=0
  check_root="$state/.registered-checks-v1"
  check_protocol=
  if [ -f "$check_root/.ready" ] && [ ! -L "$check_root/.ready" ]; then
    IFS= read -r check_protocol < "$check_root/.ready" || check_protocol=
  fi
  if [ "$check_protocol" = fm-registered-checks.v1 ]; then
    for check in "$check_root"/*; do
      [ -f "$check" ] && [ ! -L "$check" ] || continue
      [ -f "$state/$(cat "$check" 2>/dev/null || true)" ] || continue
      FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
    done
  else
    # Compatibility only until the first registration/index migration.
    for check in "$state"/*.check.sh; do
      [ -f "$check" ] && [ ! -L "$check" ] || continue
      FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
    done
  fi
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ "$FM_SUP_CHECKS" -gt 0 ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

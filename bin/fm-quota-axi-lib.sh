# shellcheck shell=bash
# Shared quota-axi helpers: version-floor compatibility check plus a timeout-
# guarded JSON query.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number and of the
# timeout-selection mechanics (GNU timeout / gtimeout / perl-fork fallback)
# used by every quota-axi invocation below. bin/fm-bootstrap.sh turns a
# failing compatibility check into the operator-facing MISSING diagnostic,
# which is what keeps an older build from reaching a dispatch intake at all.
# bin/fm-quota-reset-epoch.sh reuses the same timeout mechanics for its
# `--json` query rather than duplicating them.

FM_QUOTA_AXI_MIN=0.1.29

# _fm_quota_axi_with_timeout <timeout> <cmd> [args...]
# Runs <cmd> with stdin closed, bounded by <timeout> seconds, using whichever
# timeout mechanism is available. Prints stdout on success. Returns the
# command's exit status, or a nonzero timeout/spawn-failure status.
_fm_quota_axi_with_timeout() {
  local timeout=$1; shift
  case "$timeout" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" "$@" 2>/dev/null </dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout" "$@" 2>/dev/null </dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout" "$@" 2>/dev/null </dev/null
  else
    return 1
  fi
}

# fm_quota_axi_compatible [timeout] [cmd]
# Checks that <cmd> (default: quota-axi) is on PATH and its --version output
# meets FM_QUOTA_AXI_MIN. <timeout>, when given, bounds the --version call.
fm_quota_axi_compatible() {
  local timeout=${1:-} cmd=${2:-quota-axi} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v "$cmd" >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    output=$(_fm_quota_axi_with_timeout "$timeout" "$cmd" --version) || return 1
  else
    output=$("$cmd" --version 2>/dev/null </dev/null) || return 1
  fi
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

# fm_quota_axi_query_json <provider> [timeout] [cmd]
# Runs `<cmd> --provider <provider> --json` (default cmd: quota-axi) bounded
# by <timeout> seconds when given, and prints the raw JSON on stdout. Returns
# nonzero on a missing command, a timeout, or a nonzero quota-axi exit -
# callers must treat all of these as one loud, undifferentiated failure
# rather than guessing at a partial result.
fm_quota_axi_query_json() {
  local provider=$1 timeout=${2:-} cmd=${3:-quota-axi}
  [ -n "$provider" ] || return 1
  command -v "$cmd" >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    _fm_quota_axi_with_timeout "$timeout" "$cmd" --provider "$provider" --json
  else
    "$cmd" --provider "$provider" --json 2>/dev/null </dev/null
  fi
}

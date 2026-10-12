#!/usr/bin/env bash
# Shared manual-backlog fixture for lifecycle tests.

if [ -n "${FM_TEST_MANUAL_BACKLOG_FIXTURE_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_MANUAL_BACKLOG_FIXTURE_SOURCED=1

# Seed the smallest authenticated manual-backlog record needed by lifecycle
# fixtures that exercise terminal retirement. The task row is observable input
# to the public captain/terminal owners, not a substitute for their behavior.
fm_test_seed_manual_task() {  # <data-dir> <config-dir> <task-id>
  local data=$1 config=$2 id=$3 backlog tmp
  mkdir -p "$data" "$config" || return 1
  printf '%s\n' manual > "$config/backlog-backend" || return 1
  backlog="$data/backlog.md"
  if [ ! -e "$backlog" ]; then
    printf '## In flight\n\n## Queued\n- [ ] %s - Terminal lifecycle fixture (repo: fixture) (kind: ship)\n\n## Done\n' \
      "$id" > "$backlog"
    return $?
  fi
  grep -Eq "^- \[[ x]\] $id -" "$backlog" && return 0
  tmp=$(mktemp "$data/.backlog.XXXXXX") || return 1
  awk -v id="$id" '
    !added && /^## Queued$/ {
      print
      printf "- [ ] %s - Terminal lifecycle fixture (repo: fixture) (kind: ship)\n", id
      added=1
      next
    }
    { print }
    END { if (!added) exit 1 }
  ' "$backlog" > "$tmp" && mv -f "$tmp" "$backlog" && return 0
  rm -f "$tmp"
  return 1
}

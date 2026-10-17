#!/usr/bin/env bash
set -u

repo=${1:?repo path required}
fixture=$(mktemp -d "${TMPDIR:-/tmp}/fm-promote-evidence.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
home="$fixture/home"
fakebin="$fixture/fakebin"
state="$home/state"
meta="$state/promote-retry.meta"
mkdir -p "$state" "$fakebin"

printf '%s\n' \
  'window=prior-0:pane-0' 'kind=scout' 'worktree=/tmp/promote-retry' \
  'backend=herdr' 'herdr_session=prior-0' 'herdr_workspace_id=workspace-0' \
  'herdr_tab_id=tab-0' 'herdr_pane_id=pane-0' 'spawn_gen=promote-retry-1' \
  > "$meta"
for id in $(seq 1 8); do
  printf '%s\n' \
    "window=prior-$id:pane-$id" 'kind=ship' "worktree=/tmp/historical-$id" \
    'backend=herdr' "herdr_session=prior-$id" "herdr_workspace_id=workspace-$id" \
    "herdr_tab_id=tab-$id" "herdr_pane_id=pane-$id" "spawn_gen=historical-$id" \
    > "$state/historical-$id.meta"
done
cp "$meta" "$fixture/original.meta"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "${1:-}:${2:-}" in' \
  '  session:list)' \
  '    if [ "$FM_TEST_PROMOTE_SESSION_MODE" = oversized ]; then' \
  '      printf '\''%s\n'\'' '\''{"sessions":[{"name":"prior-0","running":true},{"name":"prior-1","running":true},{"name":"prior-2","running":true},{"name":"prior-3","running":true},{"name":"prior-4","running":true},{"name":"prior-5","running":true},{"name":"prior-6","running":true},{"name":"prior-7","running":true},{"name":"prior-8","running":true}]}'\''' \
  '    else' \
  '      printf '\''%s\n'\'' '\''{"sessions":[{"name":"prior-0","running":true}]}'\''' \
  '    fi' \
  '    ;;' \
  '  tab:list) printf '\''%s\n'\'' '\''{"result":{"tabs":[]}}'\'' ;;' \
  '  *) exit 72 ;;' \
  'esac' > "$fakebin/herdr"
chmod 0700 "$fakebin/herdr"

echo '=== Initial task contract ==='
cat "$meta"
echo
echo '=== Attempt 1: registry coverage cannot be proven ==='
set +e
PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
  HERDR_SESSION=prior-0 FM_TEST_PROMOTE_SESSION_MODE=oversized \
  "$repo/bin/fm-promote.sh" promote-retry --mode local-only --yolo off \
  > "$fixture/attempt-1.out" 2>&1
first_rc=$?
set -e
cat "$fixture/attempt-1.out"
echo "exit_code=$first_rc"
if cmp -s "$fixture/original.meta" "$meta"; then
  echo 'metadata_preserved=yes (still retryable scout)'
else
  echo 'metadata_preserved=no'
  exit 1
fi
if [ -e "$state/.active-supervision-generation" ]; then
  echo 'active_generation=unexpectedly-present'
  exit 1
else
  echo 'active_generation=absent (incomplete registry was not published)'
fi
echo 'task_kind='"$(sed -n 's/^kind=//p' "$meta")"

echo
echo '=== Attempt 2: bounded registry coverage succeeds ==='
PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
  HERDR_SESSION=prior-0 FM_TEST_PROMOTE_SESSION_MODE=bounded \
  "$repo/bin/fm-promote.sh" promote-retry --mode local-only --yolo off \
  > "$fixture/attempt-2.out" 2>&1
second_rc=$?
cat "$fixture/attempt-2.out"
echo "exit_code=$second_rc"
echo '--- final task contract ---'
cat "$meta"
echo '--- active supervision inventory ---'
FM_STATE_OVERRIDE="$state" bash -c '
  . "$1/fm-wake-lib.sh"
  . "$1/fm-backend.sh"
  . "$1/fm-supervision-registry-lib.sh"
  fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
' _ "$repo/bin"

[ "$first_rc" -ne 0 ]
[ "$second_rc" -eq 0 ]
grep -qx 'kind=ship' "$meta"
grep -qx 'mode=local-only' "$meta"
grep -qx 'yolo=off' "$meta"

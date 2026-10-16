#!/usr/bin/env bash
# Codex-only native Stop continuation. No wake drain or acknowledgement here.
# A bounded local owner serializes Stop requests, record mutation, cancellation
# and successor handoff under one kernel flock. The hook is only a transport.
# It connects over a private Unix socket; no network/debugging API is involved.
# The owner watches only during a Stop request, using the unchanged watch-arm.
# Cycle admission charges bounded downstream endpoint work only to recorded
# workers that are not authoritatively dead; retained dead endpoints still
# receive their cheap watcher probe but do not multiply worst-case reads.
# Due checks are split into a durable per-cycle batch sized to the remaining
# deadline, without reducing any individual check's timeout.
# Between Stops it holds an identity-checked handling lease for at most 300s.
# Closing an unanswered hook connection cancels its owned watcher process group;
# an independently attached watcher is outside that group and is never killed.
# No lock PID is trusted for exclusion or stale takeover: flock releases on death.
# The stable lock inode is never unlinked. Only its holder writes/removes records.
# --healthy STATE is a read-only challenge to the live owner, not a stale PID test.
# Requires Python 3's standard-library Unix socket/flock support; unavailable
# support blocks Stop with an explicit diagnostic rather than claiming coverage.
# FM_CODEX_WATCH_CHECKPOINT defaults to 180s, capped at 180s. Hook timeout: 600s.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MODE=stop
SESSION_PID=
SESSION_IDENTITY=
SESSION_ID=
if [ "${1:-}" = --healthy ]; then
  MODE=healthy
  STATE=${2:?state required}
else
  PAYLOAD=$(cat 2>/dev/null || true)
  command -v jq >/dev/null 2>&1 || exit 0
  SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -er '.session_id | select(type == "string" and length > 0)') || exit 0
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$STATE" || exit 0
  [ ! -e "$STATE/.afk" ] || exit 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  SESSION_PID=$(cat "$STATE/.lock")
  SESSION_IDENTITY=$(fm_pid_identity "$SESSION_PID") || exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  [ "$MODE" != healthy ] || exit 1
  echo 'Firstmate Codex supervision requires Python 3 Unix socket/flock support.' >&2
  exit 2
fi
if ! python3 - >/dev/null 2>&1 <<'PY'
import sys
PY
then
  [ "$MODE" != healthy ] || exit 1
  echo 'Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.' >&2
  exit 2
fi
export FM_HOME FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE"
PYTHON_PID=
# Invoked indirectly by the HUP/INT/TERM trap below.
# shellcheck disable=SC2329
stop_python() {
  local python_rc=0
  [ -z "$PYTHON_PID" ] || kill -TERM "$PYTHON_PID" 2>/dev/null || true
  [ -z "$PYTHON_PID" ] || wait "$PYTHON_PID" 2>/dev/null || python_rc=$?
  [ "$python_rc" -ne 2 ] || exit 2
  exit 0
}
trap stop_python HUP INT TERM
python3 - "$MODE" "$STATE" "$SCRIPT_DIR" "$SESSION_PID" "$SESSION_IDENTITY" "$SESSION_ID" "$$" <<'PY' &
import sys

try:
    import fcntl
    import json
    import math
    import os
    import selectors
    import signal
    import socket
    import stat
    import subprocess
    import tempfile
    import time
    import uuid

    mode, state, scripts, session_pid, session_identity, session_id, launcher_pid = sys.argv[1:]
    launcher_pid = int(launcher_pid)
    os.chdir(state)  # Relative socket pathname also works in deep worktree paths.
except Exception:
    if len(sys.argv) > 1 and sys.argv[1] == 'healthy':
        sys.exit(1)
    print('Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.', file=sys.stderr)
    sys.exit(2)
RECORD = '.codex-stop.json'
SOCKET = '.codex-stop.sock'
LOCK = '.codex-stop.owner-lock'  # Stable inode: never unlink or replace.


class TransportEnded(Exception):
    pass


try:
    checkpoint = min(180, max(1, int(os.environ.get('FM_CODEX_WATCH_CHECKPOINT', '180'))))
except ValueError:
    checkpoint = 180


try:
    handling_grace = min(300, max(1, int(os.environ.get('FM_CODEX_HANDLING_GRACE', '300'))))
except ValueError:
    handling_grace = 300


try:
    watcher_cadence = float(os.environ.get('FM_POLL', '15'))
    if not math.isfinite(watcher_cadence) or watcher_cadence <= 0:
        raise ValueError
except ValueError:
    watcher_cadence = 15
try:
    watcher_guard_grace = int(os.environ.get('FM_GUARD_GRACE', '300'))
    if watcher_guard_grace <= 0:
        raise ValueError
except ValueError:
    watcher_guard_grace = 300
try:
    signal_grace = float(os.environ.get('FM_SIGNAL_GRACE', '30'))
    if not math.isfinite(signal_grace) or signal_grace < 0:
        raise ValueError
except ValueError:
    signal_grace = 30
try:
    check_timeout = int(os.environ.get('FM_CHECK_TIMEOUT', '30'))
    if check_timeout <= 0:
        raise ValueError
except ValueError:
    check_timeout = 30
check_kill_grace = 1
check_slot_timeout = check_timeout + check_kill_grace
try:
    check_interval = int(os.environ.get('FM_CHECK_INTERVAL', '300'))
except ValueError:
    check_interval = 300
try:
    crew_state_timeout = int(os.environ.get('FM_CREW_STATE_NM_TIMEOUT', '10'))
    if crew_state_timeout <= 0:
        raise ValueError
except ValueError:
    crew_state_timeout = 10
try:
    worktree_write_timeout = int(os.environ.get('FM_WORKTREE_WRITE_TIMEOUT', '10'))
    if worktree_write_timeout <= 0:
        raise ValueError
except ValueError:
    worktree_write_timeout = 10
try:
    remote_send_timeout = int(os.environ.get('FM_SEND_REMOTE_BUDGET', '30'))
    if remote_send_timeout <= 0:
        raise ValueError
except ValueError:
    remote_send_timeout = 30
try:
    inactive_reconcile_budget = int(os.environ.get('FM_INACTIVE_RECONCILE_BUDGET_SECS', '10'))
    if inactive_reconcile_budget <= 0 or inactive_reconcile_budget > 30:
        raise ValueError
except ValueError:
    inactive_reconcile_budget = 10
inactive_reconcile_timeout = inactive_reconcile_budget + 1


try:
    startup_timeout = min(12, max(1, int(os.environ.get('FM_ARM_CONFIRM_TIMEOUT', '10')))) + 1
except ValueError:
    startup_timeout = 11

try:
    transport_timeout = min(590, max(1, int(
        os.environ.get('FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT', '590'))))
except ValueError:
    transport_timeout = 590
protocol_reserve = 10
probe_timeout = 3
probe_cleanup_allowance = 3
identity_allowance = probe_timeout + probe_cleanup_allowance
arm_cleanup_allowance = 2 * identity_allowance + 3
terminal_orchestration_allowance = 1
terminal_reserve = (protocol_reserve + arm_cleanup_allowance + identity_allowance +
                    terminal_orchestration_allowance)
startup_phase_allowance = max(startup_timeout, identity_allowance)
cycle_limit = transport_timeout - startup_phase_allowance - checkpoint - terminal_reserve
budget_reason = 'watcher cycle exceeds Codex Stop deadline; inspect live endpoints and outstanding supervision work'


admission_registry_generation = None


def admission_cycle_work(probe_deadline=None):
    result = shell(r'''
. "$1/fm-backend.sh" || exit 1
. "$1/fm-supervision-registry-lib.sh" || exit 1
. "$1/fm-pending-reply-lib.sh" || exit 1
. "$1/fm-task-inbox-lib.sh" || exit 1
set -o pipefail
fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
generation=$(fm_supervision_registry_generation "$FM_STATE_OVERRIDE") || exit 1
printf 'generation\t%s\n' "$generation"
inventory=$(fm_supervision_registry_inventory "$FM_STATE_OVERRIDE" "$generation") || exit 1
owners=
while IFS= read -r meta; do
  [ -n "$meta" ] || continue
  task=${meta##*/}; task=${task%.meta}
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || continue
  backend=$(fm_backend_of_meta "$meta")
  route=local
  case "$target" in remote:*) route=remote ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || route=remote
  record_home=$(fm_meta_get "$meta" home); [ -n "$record_home" ] || record_home=-
  owners="${owners}${owners:+$'\n'}${backend}\t${target}\t${route}\t${record_home}\t${task}"
done <<EOF
$inventory
EOF
states=$(printf '%b\n' "$owners" | awk -F '\t' '!seen[$1 SUBSEP $3 SUBSEP $2]++ { print $1, $2, $3, $4 }' OFS="$(printf '\t')" \
  | fm_backend_agent_state_batch) || exit 1
plan=$({ printf '%s\n' "$states"; printf '__FM_OWNERS__\n'; printf '%b\n' "$owners"; } | awk -F '\t' '
  BEGIN { OFS="\t" }
  $0 == "__FM_OWNERS__" { owners=1; next }
  !owners { verdict[$1 SUBSEP $4 SUBSEP $2]=$3; next }
  { print $1, $2, verdict[$1 SUBSEP $3 SUBSEP $2], $3, $4, $5 }
') || exit 1
while IFS="$(printf '\t')" read -r backend target agent_state route record_home task; do
  case "$agent_state" in
    dead|missing) ;;
    *)
      printf 'budget-window\t%s\t%s\t%s\n' "$backend" "$route" "$target"
      printf 'active-owner\t%s\n' "$task"
      action=$(fm_task_inbox_due_action "$FM_STATE_OVERRIDE" "$task") || action=quiet
      case "${action%% *}" in ring|escalate) printf 'owner-fanout\tinbox:%s\n' "$task" ;; esac
      ;;
  esac
done <<EOF
$plan
EOF
for file in "$FM_STATE_OVERRIDE"/*.status "$FM_STATE_OVERRIDE"/*.turn-ended; do
  [ -f "$file" ] || continue
  task=$(basename "$file")
  task=${task%.status}; task=${task%.turn-ended}
  fm_supervision_registry_contains "$FM_STATE_OVERRIDE" "$task" "$generation" || continue
  if ! fm_wake_signal_seen_current "$FM_STATE_OVERRIDE" "$file"; then
    printf 'signal\t%s\n' "$(basename "$file")"
  fi
done
dir=${FM_PENDING_REPLY_DIR_OVERRIDE:-$FM_STATE_OVERRIDE/pending-replies}
if [ -d "$dir" ]; then
  now=$(fm_pending_reply_now)
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in .*) continue ;; esac
    [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] || continue
    [ -z "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ] || continue
    delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
    grace=$(fm_pending_reply_get "$rec" grace_secs)
    case "$delivered:$grace:$now" in
      *[!0-9:]*|:*|*::*|*:) continue ;;
    esac
    [ "$((now - delivered))" -ge "$grace" ] || continue
    task_id=$(fm_pending_reply_get "$rec" task_id)
    fm_supervision_registry_contains "$FM_STATE_OVERRIDE" "$task_id" "$generation" || continue
    printf 'owner-fanout\tpending:%s\n' "$(basename "$rec")"
    if fm_pending_reply_target_is_remote "$FM_STATE_OVERRIDE" "$task_id"; then
      printf 'remote-recovery\t%s\n' "$(basename "$rec")"
    fi
  done
fi
after=$(fm_supervision_registry_generation "$FM_STATE_OVERRIDE") || exit 1
[ "$after" = "$generation" ] || exit 1
''', timeout=8, deadline=probe_deadline)
    if result is None or result.returncode != 0:
        return None
    generation = None
    signal_tasks = set()
    remote_recoveries = set()
    owner_fanouts = set()
    active_owners = set()
    windows = set()
    for line in result.stdout.splitlines():
        kind, separator, value = line.partition('\t')
        if not separator or not value:
            continue
        if kind == 'generation':
            generation = value
        elif kind == 'signal':
            if value.endswith('.status'):
                value = value[:-len('.status')]
            elif value.endswith('.turn-ended'):
                value = value[:-len('.turn-ended')]
            signal_tasks.add(value)
        elif kind == 'remote-recovery':
            remote_recoveries.add(value)
        elif kind == 'owner-fanout':
            owner_fanouts.add(value)
        elif kind == 'active-owner':
            active_owners.add(value)
        if kind == 'budget-window' and separator and value:
            windows.add(value)
    if not generation:
        return None
    return (generation, signal_tasks, len(remote_recoveries), len(windows),
            len(active_owners), len(owner_fanouts))


def watcher_cycle_timeout(check_limit=None, cycle_budget=None, budget_deadline=None,
                          probe_deadline=None):
    names = os.listdir('.')
    try:
        check_age = int(time.time()) - int(os.path.getmtime('.last-check'))
    except OSError:
        check_age = 999999
    due_checks = 0
    if check_age >= check_interval:
        due_checks = sum(name.endswith('.check.sh') and os.path.isfile(name) for name in names)
    global admission_registry_generation
    work = admission_cycle_work(probe_deadline)
    if work is None:
        return cycle_limit + 1, check_limit or 1, 0
    (admission_registry_generation, signal_tasks, remote_recoveries, budget_windows,
     active_owners, owner_fanouts) = work
    if budget_deadline is not None:
        cycle_budget = max(0, math.floor(
            budget_deadline - time.monotonic() - startup_phase_allowance - checkpoint -
            terminal_reserve))
    elif cycle_budget is None:
        cycle_budget = cycle_limit
    # The watcher attempts a cheap capture for every recorded target, but only
    # a worker not authoritatively dead can repeatedly reach the bounded
    # crew-state and worktree-write paths charged here. Backends without a
    # verified agent-state classifier remain included. If the aggregate agent
    # scan itself exceeds the bounded helper call, admission fails closed.
    non_check_components = math.ceil(
        watcher_cadence + inactive_reconcile_timeout + signal_grace +
        2 * crew_state_timeout * (len(signal_tasks) + active_owners) +
        worktree_write_timeout * active_owners +
        2 * remote_send_timeout * (remote_recoveries + owner_fanouts) + 5)
    if check_limit is None:
        check_limit = max(1, math.floor((cycle_budget - non_check_components) / check_slot_timeout))
    checks_this_cycle = min(due_checks, check_limit)
    components = non_check_components + check_slot_timeout * checks_this_cycle
    return max(watcher_guard_grace, components), check_limit, cycle_budget


def terminate_probe_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    time.sleep(0.1)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        process.communicate(timeout=1)
    except subprocess.TimeoutExpired:
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass


def shell(body, *args, timeout=probe_timeout, deadline=None):
    process = None
    try:
        if deadline is not None and time.monotonic() + timeout + probe_cleanup_allowance > deadline:
            return None
        command = ['bash', '-c', '. "$1/fm-wake-lib.sh"; ' + body,
                   'codex-stop-probe', scripts, *args]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired:
        terminate_probe_group(process)
        return None
    except OSError:
        if process is not None:
            terminate_probe_group(process)
        return None


def identity(pid, deadline=None):
    result = shell('fm_pid_identity "$2"', str(pid), deadline=deadline)
    if result is None:
        return None
    return result.stdout.rstrip('\n') if result.returncode == 0 else ''


def generation_current(deadline=None):
    try:
        if (os.path.islink('.lock') or open('.lock').read().strip() != session_pid or
                not session_identity or os.path.exists('.afk')):
            return False
    except OSError:
        return False
    current = identity(session_pid, deadline)
    if current is None:
        return None
    return current == session_identity


def needed(probe_deadline=None):
    result = shell('. "$1/fm-supervision-lib.sh"; fm_supervision_needed "$FM_STATE_OVERRIDE"',
                   deadline=probe_deadline)
    # An unavailable probe is uncertainty, not proof that the fleet is idle.
    return result is None or result.returncode != 1


def queued():
    try:
        return os.path.getsize('.wake-queue') > 0
    except FileNotFoundError:
        return False


def launcher_current():
    return os.getppid() == launcher_pid


def watcher_beat():
    try:
        return os.stat('.last-watcher-beat').st_mtime_ns
    except OSError:
        return 0


def capability_number(value):
    return format(value, 'g') if isinstance(value, float) else str(value)


def bounded_watcher_capability_content(check_limit):
    fields = (
        ('checks-per-cycle', check_limit),
        ('check-timeout', check_timeout),
        ('check-kill-grace', check_kill_grace),
        ('check-interval', check_interval),
        ('poll', watcher_cadence),
        ('signal-grace', signal_grace),
        ('crew-state-timeout', crew_state_timeout),
        ('worktree-write-timeout', worktree_write_timeout),
        ('remote-send-timeout', remote_send_timeout),
        ('inactive-reconcile-budget', inactive_reconcile_budget),
        ('admission-guard-grace', watcher_guard_grace),
        ('remote-observation', 'deferred'),
        ('inventory', 'active-registry-v3'),
        ('check-batch-handoff', 'resume-owner-cycle-v4'),
    )
    return 'fm-codex-bounded.v9\t' + '\t'.join(
        f'{key}={capability_number(value)}' for key, value in fields) + '\n'


def bounded_watcher_capability(check_limit):
    fd = None
    try:
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open('.watch.lock/codex-bounded-capability', flags)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 512:
            return None
        content = os.read(fd, 513).decode('ascii')
        prefix = bounded_watcher_capability_content(check_limit).rstrip('\n') + '\tcheck-batch-lease='
        if not content.startswith(prefix) or not content.endswith('\n'):
            return None
        lease = content[len(prefix):-1]
        if not lease or len(lease) > 96 or any(char not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for char in lease):
            return None
        return lease
    except (OSError, UnicodeError):
        return None
    finally:
        if fd is not None:
            os.close(fd)


def watcher_check_batch_boundary(batch_lease):
    fd = None
    try:
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open('.watch.lock/codex-check-batch-boundary', flags)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 192:
            return None
        fields = os.read(fd, 193).decode('ascii').rstrip('\n').split('\t')
        if len(fields) != 3 or fields[:2] != ['fm-codex-check-batch.v1', batch_lease]:
            return None
        sequence = int(fields[2])
        return sequence if sequence > 0 else None
    except ValueError:
        return None
    except (OSError, UnicodeError):
        return None
    finally:
        if fd is not None:
            os.close(fd)


def request_watcher_check_batch(batch_lease, sequence, token, owner_pid,
                                owner_identity, session_pid, session_identity,
                                resume_deadline, resume_cycle_timeout,
                                registry_generation):
    value = (f'fm-codex-check-batch.v4\t{batch_lease}\t{sequence}\t{token}\t'
             f'{owner_pid}\t{owner_identity}\t{session_pid}\t{session_identity}\t'
             f'{resume_deadline}\t{resume_cycle_timeout}\t{registry_generation}\n').encode('ascii')
    path = '.watch.lock/codex-check-batch-resume'
    tmp = '.watch.lock/codex-check-batch-resume.tmp'
    fd = None
    try:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open(tmp, flags, 0o600)
        os.write(fd, value)
        os.close(fd)
        fd = None
        os.replace(tmp, path)
        return True
    except OSError:
        return False
    finally:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def check_batch_authorization(path, batch_lease, token):
    fd = None
    try:
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open(path, flags)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1024:
            return False
        fields = os.read(fd, 1025).decode('ascii').rstrip('\n').split('\t')
        return (len(fields) == 11 and fields[0] == 'fm-codex-check-batch.v4' and
                fields[1] == batch_lease and fields[3] == token)
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError):
        return False
    finally:
        if fd is not None:
            os.close(fd)


def revoke_watcher_check_batch(batch_lease, token, cleanup_deadline):
    request_path = '.watch.lock/codex-check-batch-resume'
    active_path = '.watch.lock/codex-check-batch-active'
    while True:
        request = check_batch_authorization(request_path, batch_lease, token)
        if request is False:
            return False
        if request is True:
            try:
                os.unlink(request_path)
            except FileNotFoundError:
                pass
            except OSError:
                return False
            continue
        active = check_batch_authorization(active_path, batch_lease, token)
        if active is False:
            return False
        if active is None:
            return True
        if cleanup_deadline is None or time.monotonic() >= cleanup_deadline:
            return False
        time.sleep(0.05)


def watcher_arm_ownership(batch_lease, arm_pid, expected_arm_identity, deadline=None):
    fd = None
    try:
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open('.watch.lock/codex-arm-ownership', flags)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 512:
            return None
        fields = os.read(fd, 513).decode('ascii').rstrip('\n').split('\t')
        if (len(fields) != 6 or fields[0] != 'fm-codex-arm-owner.v1' or
                fields[1] != batch_lease or fields[2] != str(arm_pid) or
                fields[3] != expected_arm_identity):
            return None
        watcher_pid = int(fields[4])
        if watcher_pid <= 0 or not fields[5]:
            return None
        current = identity(watcher_pid, deadline)
        if current is None:
            return False
        if current != fields[5]:
            return None
        return watcher_pid, fields[5]
    except (OSError, UnicodeError, ValueError):
        return None
    finally:
        if fd is not None:
            os.close(fd)


def arm_launch_ownership(batch_lease, arm_pid, expected_arm_identity, deadline=None):
    path = '.codex-arm-owner'
    fd = None
    try:
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open(path, flags)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 512:
            return None
        fields = os.read(fd, 513).decode('ascii').rstrip('\n').split('\t')
        if (len(fields) < 5 or fields[:4] != [
                'fm-codex-arm-launch.v1', batch_lease, str(arm_pid), expected_arm_identity]):
            return None
        if fields[4] == 'pending' and len(fields) == 5:
            try:
                os.killpg(arm_pid, 0)
                return None
            except ProcessLookupError:
                return True
            except PermissionError:
                return None
        if fields[4] != 'spawned' or len(fields) != 7:
            return None
        watcher_pid = int(fields[5])
        current = identity(watcher_pid, deadline)
        if current is None:
            return None
        if current != fields[6]:
            return True
        return watcher_pid, fields[6]
    except FileNotFoundError:
        return False
    except (OSError, UnicodeError, ValueError):
        return None
    finally:
        if fd is not None:
            os.close(fd)


def watcher_snapshot(grace, check_limit, probe_deadline=None):
    result = shell('fm_watcher_healthy "$FM_STATE_OVERRIDE" "$1/fm-watch.sh" "$2" "$FM_HOME" '
                   '&& printf "%s\\t%s\\n" "$FM_WATCHER_HEALTHY_PID" "$FM_WATCHER_HEALTHY_IDENTITY"',
                   str(grace), deadline=probe_deadline)
    if result is None or result.returncode != 0:
        return None
    batch_lease = bounded_watcher_capability(check_limit)
    if batch_lease is None:
        return None
    fields = result.stdout.rstrip('\n').split('\t')
    if len(fields) != 2 or not all(fields):
        return None
    try:
        beat = os.stat('.last-watcher-beat').st_mtime_ns
    except OSError:
        return None
    sequence = 1
    try:
        with open('.watch.lock/codex-check-batch-sequence') as stream:
            sequence = int(stream.read().strip())
        if sequence <= 0:
            return None
    except FileNotFoundError:
        pass
    except (OSError, ValueError):
        return None
    return fields[0], fields[1], beat, batch_lease, sequence


def read_record():
    try:
        with open(RECORD) as stream:
            return json.load(stream)
    except (OSError, ValueError):
        return {}


def send(conn, value):
    conn.sendall((json.dumps(value) + '\n').encode())


def receive(conn, timeout=3):
    data = b''
    expires = time.monotonic() + timeout
    previous_timeout = conn.gettimeout()
    try:
        while b'\n' not in data:
            if not launcher_current():
                raise TransportEnded('hook transport ended')
            remaining = expires - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('owner response timed out')
            conn.settimeout(min(0.2, remaining))
            try:
                block = conn.recv(8192)
            except socket.timeout:
                continue
            if not block or len(data) > 16384:
                raise OSError('closed or invalid owner response')
            data += block
        return json.loads(data.split(b'\n', 1)[0])
    finally:
        try:
            conn.settimeout(previous_timeout)
        except OSError:
            pass


def owner(lock):
    # This is the only state writer. Kernel ownership spans the entire lifetime,
    # including handling and successor requests; there is no second record lock,
    # stale-lock reaper, cancellation writer, or competing monitor.
    token = uuid.uuid4().hex
    owner_identity = identity(os.getpid())
    if not owner_identity:
        return
    selector = selectors.DefaultSelector()
    listener = socket.socket(socket.AF_UNIX)
    active = None
    arm = None
    arm_identity = ''
    output = None
    phase = 'idle'
    deadline = time.monotonic() + 5
    next_probe = time.monotonic()
    supervision_needed = True
    pending = {}
    acknowledged = False
    published = {}
    watcher_proof = None
    watcher_last_beat = 0
    watcher_last_progress = 0
    next_watcher_probe = 0
    confirmation_started_at = 0
    cycle_timeout = watcher_guard_grace
    check_batch_limit = 1
    active_cycle_limit = cycle_limit
    transport_deadline = None
    resume_deadline_epoch = None
    resume_cycle_timeout = None
    leased_registry_generation = None
    arm_budget_failure = False
    terminal_delivered = False
    terminal_cleanup_complete = False
    generation_changed = False
    expected_batch_sequence = None
    resume_authorization = None

    def remaining_cycle_limit(now):
        if phase == 'starting':
            cycle_starts = max(now, deadline) + checkpoint
        elif phase == 'watching':
            cycle_starts = max(now, deadline)
        elif phase == 'confirming':
            cycle_starts = confirmation_started_at
        else:
            return 0
        return max(0, math.floor(transport_deadline - cycle_starts - terminal_reserve))

    def publish(next_phase, seconds, started_at=None):
        nonlocal phase, deadline, published
        if started_at is not None:
            seconds = max(0, seconds - (time.monotonic() - started_at))
        phase = next_phase
        deadline = time.monotonic() + seconds
        record = dict(token=token, owner=os.getpid(), owner_identity=owner_identity,
                      session_pid=session_pid, session_identity=session_identity,
                      session_id=session_id, phase=phase, deadline=time.time() + seconds)
        if resume_deadline_epoch is not None:
            record['resume_deadline'] = resume_deadline_epoch
        if resume_cycle_timeout is not None:
            record['resume_cycle_timeout'] = resume_cycle_timeout
        if leased_registry_generation is not None:
            record['registry_generation'] = leased_registry_generation
        published = record
        fd, tmp = tempfile.mkstemp(prefix='.codex-stop-record.')
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(record, stream)
            os.replace(tmp, RECORD)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def cancel_arm(cleanup_deadline=None):
        nonlocal arm, arm_identity, output, resume_authorization
        completed = True
        if resume_authorization is not None:
            batch_lease, authorization_token = resume_authorization
            completed = revoke_watcher_check_batch(
                batch_lease, authorization_token, cleanup_deadline)
            if completed:
                resume_authorization = None
        if arm is not None:
            if (cleanup_deadline is not None and
                    time.monotonic() + arm_cleanup_allowance > cleanup_deadline):
                completed = False
            elif arm.poll() is None:
                arm.terminate()
                try:
                    arm.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(arm.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    arm.wait(timeout=1)
                time.monotonic()
            else:
                proof = watcher_proof
                owned_member = False
                member_pid = None
                member_identity = ''
                if proof is not None:
                    try:
                        member_pid = int(proof[0])
                        owned_member = os.getpgid(member_pid) == arm.pid
                    except ValueError:
                        owned_member = False
                    except OSError:
                        owned_member = False
                    if owned_member:
                        member_identity = proof[1]
                if not owned_member:
                    ownership = watcher_arm_ownership(
                        token, arm.pid, arm_identity, cleanup_deadline)
                    time.monotonic()
                    if ownership is False:
                        completed = False
                    elif ownership is not None:
                        member_pid, member_identity = ownership
                        owned_member = True
                if not owned_member and completed:
                    launch_wait_deadline = time.monotonic() + startup_timeout
                    if cleanup_deadline is not None:
                        launch_wait_deadline = min(launch_wait_deadline, cleanup_deadline)
                    while True:
                        launch_ownership = arm_launch_ownership(
                            token, arm.pid, arm_identity, cleanup_deadline)
                        now = time.monotonic()
                        if launch_ownership is not None:
                            break
                        if now >= launch_wait_deadline:
                            break
                        time.sleep(0.05)
                    if launch_ownership is None:
                        completed = False
                    elif isinstance(launch_ownership, tuple):
                        member_pid, member_identity = launch_ownership
                        owned_member = True
                if owned_member:
                    current = identity(member_pid, cleanup_deadline)
                    time.monotonic()
                    if current is None:
                        completed = False
                        owned_member = False
                    elif current != member_identity:
                        owned_member = False
                    else:
                        try:
                            if os.getpgid(member_pid) != arm.pid:
                                completed = False
                                owned_member = False
                        except ProcessLookupError:
                            owned_member = False
                        except OSError:
                            completed = False
                            owned_member = False
                if owned_member:
                    try:
                        os.killpg(arm.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    except PermissionError:
                        completed = False
                    expires = time.monotonic() + 3
                    while time.monotonic() < expires:
                        current = identity(member_pid, cleanup_deadline)
                        time.monotonic()
                        if current is None:
                            completed = False
                            break
                        if current != member_identity:
                            break
                        time.sleep(0.05)
                    else:
                        current = identity(member_pid, cleanup_deadline)
                        time.monotonic()
                        if current is None:
                            completed = False
                        elif current == member_identity:
                            try:
                                if os.getpgid(member_pid) == arm.pid:
                                    os.killpg(arm.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            except PermissionError:
                                completed = False
                            kill_expires = time.monotonic() + 1
                            while time.monotonic() < kill_expires:
                                current = identity(member_pid, cleanup_deadline)
                                time.monotonic()
                                if current is None:
                                    completed = False
                                    break
                                if current != member_identity:
                                    break
                                time.sleep(0.05)
                            else:
                                completed = False
                elif completed:
                    possible_orphan = watcher_snapshot(
                        cycle_timeout, check_batch_limit, cleanup_deadline)
                    time.monotonic()
                    if possible_orphan is not None and possible_orphan[3] == token:
                        completed = False
            if completed:
                try:
                    os.unlink('.codex-arm-owner')
                except FileNotFoundError:
                    pass
                arm = None
                arm_identity = ''
        if output is not None:
            output.close()
            output = None
        return completed

    def close(conn):
        pending.pop(conn, None)
        try:
            selector.unregister(conn)
        except KeyError:
            pass
        conn.close()

    def finish(reason):
        nonlocal acknowledged, terminal_delivered, terminal_cleanup_complete, generation_changed
        if (transport_deadline is not None and
                time.monotonic() + terminal_reserve > transport_deadline):
            reason = budget_reason
        cleanup_deadline = (transport_deadline - identity_allowance - protocol_reserve
                            if transport_deadline is not None else None)
        terminal_cleanup_complete = cancel_arm(cleanup_deadline) and arm is None
        if not terminal_cleanup_complete:
            reason = budget_reason
        generation_deadline = (transport_deadline - protocol_reserve
                               if transport_deadline is not None else None)
        current = generation_current(generation_deadline)
        time.monotonic()
        if current is False:
            generation_changed = True
            return False
        if current is None:
            reason = budget_reason
        publish('delivering', 5)
        acknowledged = False
        send(active, dict(rc=2, reason=reason, token=token))
        terminal_delivered = True
        return True

    def stop_signal(_signum, _frame):
        raise InterruptedError('owner interrupted')

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, stop_signal)
    try:
        if generation_current() is not True:
            return
        if os.path.lexists(SOCKET):
            os.unlink(SOCKET)
        listener.bind(SOCKET)
        os.chmod(SOCKET, 0o600)
        listener.listen(8)
        listener.setblocking(False)
        selector.register(listener, selectors.EVENT_READ)
        publish('idle', 5)
        while True:
            for key, _events in selector.select(0.2):
                if key.fileobj is listener:
                    conn, _address = listener.accept()
                    conn.setblocking(False)
                    pending[conn] = (b'', time.monotonic() + 3)
                    selector.register(conn, selectors.EVENT_READ)
                    continue
                conn = key.fileobj
                block = conn.recv(8192)
                if not block:
                    close(conn)
                    if conn is active:
                        active = None
                        if not acknowledged:
                            return  # Interrupted hook: cancel, revoke, stand down.
                    continue
                buf, expires = pending[conn]
                buf += block
                if len(buf) > 16384:
                    return
                pending[conn] = (buf, expires)
                if b'\n' not in buf:
                    continue
                line, rest = buf.split(b'\n', 1)
                pending[conn] = (rest, expires)
                request = json.loads(line)
                if request.get('token') != token:
                    close(conn)
                    continue
                if request.get('op') == 'healthy':
                    health_deadline = (transport_deadline - terminal_reserve
                                       if active is not None else None)
                    send(conn, dict(token=token, healthy=request.get('record') == published and
                                    phase in ('watching', 'confirming', 'handling') and
                                    time.monotonic() < deadline and
                                    generation_current(health_deadline) is True))
                    time.monotonic()
                    close(conn)
                elif conn is active and request.get('op') == 'accepted' and phase == 'delivering':
                    send(conn, dict(accepted=True, token=token))
                elif conn is active and request.get('op') == 'commit' and phase == 'delivering':
                    if not terminal_cleanup_complete or arm is not None:
                        return
                    commit_deadline = (transport_deadline
                                       if transport_deadline is not None else None)
                    commit_generation = generation_current(commit_deadline)
                    time.monotonic()
                    if commit_generation is False:
                        generation_changed = True
                        send(conn, dict(committed=False, token=token))
                        return
                    publish('handling', handling_grace)
                    send(conn, dict(committed=True, token=token))
                    acknowledged = True
                elif request.get('op') == 'stop':
                    if (request.get('session_pid'), request.get('session_identity')) != (
                            session_pid, session_identity):
                        send(conn, dict(rc=2, reason='session generation changed; retry Stop', token=token))
                        close(conn)
                    elif request.get('session_id') != session_id:
                        send(conn, dict(rc=2, reason='session generation changed; retry Stop',
                                        retry=True, token=token))
                        close(conn)
                        return
                    elif active is not None or phase == 'watching':
                        send(conn, dict(rc=0, reason='', token=token))
                        close(conn)
                    else:
                        active = conn
                        acknowledged = False
                        terminal_cleanup_complete = False
                        transport_deadline = time.monotonic() + transport_timeout
                        resume_deadline_epoch = math.floor(
                            time.time() + transport_timeout - terminal_reserve)
                        publish('preflighting', max(0, transport_deadline - time.monotonic()))
                        arm_budget_failure = False
                        if queued():
                            if not finish('durable wake pending'):
                                return
                        elif not needed():
                            send(conn, dict(rc=0, reason='', token=token))
                            terminal_delivered = True
                            return
                        else:
                            cycle_timeout, check_batch_limit, active_cycle_limit = watcher_cycle_timeout(
                                budget_deadline=transport_deadline,
                                probe_deadline=(transport_deadline - startup_phase_allowance - checkpoint -
                                                terminal_reserve))
                            leased_registry_generation = admission_registry_generation
                            resume_cycle_timeout = cycle_timeout
                            if cycle_timeout > active_cycle_limit:
                                if not finish(budget_reason):
                                    return
                            else:
                                arm_environment = os.environ.copy()
                                arm_environment['FM_GUARD_GRACE'] = str(cycle_limit)
                                arm_environment['FM_CODEX_BOUNDED_WATCH'] = '1'
                                arm_environment['FM_CHECKS_PER_CYCLE'] = str(check_batch_limit)
                                arm_environment['FM_CODEX_CHECK_BATCH_LEASE'] = token
                                arm_environment['FM_CHECK_TIMEOUT'] = str(check_timeout)
                                arm_environment['FM_CHECK_KILL_GRACE'] = str(check_kill_grace)
                                arm_environment['FM_CHECK_INTERVAL'] = str(check_interval)
                                arm_environment['FM_POLL'] = capability_number(watcher_cadence)
                                arm_environment['FM_SIGNAL_GRACE'] = capability_number(signal_grace)
                                arm_environment['FM_CREW_STATE_NM_TIMEOUT'] = str(crew_state_timeout)
                                arm_environment['FM_WORKTREE_WRITE_TIMEOUT'] = str(worktree_write_timeout)
                                arm_environment['FM_SEND_REMOTE_BUDGET'] = str(remote_send_timeout)
                                arm_environment['FM_INACTIVE_RECONCILE_BUDGET_SECS'] = str(inactive_reconcile_budget)
                                arm_environment['FM_CODEX_ADMISSION_GUARD_GRACE'] = str(watcher_guard_grace)
                                arm_environment['FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION'] = '1'
                                arm_environment['FM_CODEX_REGISTRY_GENERATION'] = leased_registry_generation
                                output = tempfile.TemporaryFile()
                                arm_started_at = time.monotonic()
                                arm = subprocess.Popen(['bash', scripts + '/fm-watch-arm.sh'], stdin=subprocess.DEVNULL,
                                                       stdout=output, stderr=output, start_new_session=True,
                                                       env=arm_environment)
                                publish('starting', startup_timeout, arm_started_at)
                                arm_identity_result = identity(
                                    arm.pid, transport_deadline - terminal_reserve)
                                time.monotonic()
                                if arm_identity_result is None:
                                    arm_identity = ''
                                    arm_budget_failure = True
                                else:
                                    arm_identity = arm_identity_result
            for conn, (_buf, expires) in list(pending.items()):
                if conn is not active and time.monotonic() >= expires:
                    close(conn)
            now = time.monotonic()
            probe_due = now >= next_probe or (
                phase in ('starting', 'watching', 'confirming') and now >= deadline)
            probe_budget_failure = False
            if probe_due:
                generation_deadline = None
                if active is not None:
                    generation_deadline = transport_deadline - terminal_reserve
                    if time.monotonic() + identity_allowance > generation_deadline:
                        probe_budget_failure = True
                if not probe_budget_failure:
                    current = generation_current(generation_deadline)
                    now = time.monotonic()
                    if current is None:
                        probe_budget_failure = active is not None
                        if not probe_budget_failure:
                            return
                    elif current is False:
                        return
                if not probe_budget_failure:
                    supervision_needed = needed(
                        transport_deadline - terminal_reserve if active is not None else None)
                now = time.monotonic()
                next_probe = now + 1
            if phase in ('starting', 'watching', 'confirming') and active is not None:
                reason = 'durable wake pending' if queued() else ''
                if not reason and (arm_budget_failure or probe_budget_failure or
                                   now >= transport_deadline - terminal_reserve):
                    reason = budget_reason
                if not reason and probe_due:
                    next_cycle_timeout, _next_check_limit, _next_cycle_limit = watcher_cycle_timeout(
                        check_batch_limit, active_cycle_limit,
                        probe_deadline=transport_deadline - terminal_reserve)
                    now = time.monotonic()
                    next_cycle_limit = remaining_cycle_limit(now)
                    if admission_registry_generation != leased_registry_generation:
                        reason = budget_reason
                    elif (now >= transport_deadline - terminal_reserve or
                            next_cycle_timeout > next_cycle_limit):
                        reason = budget_reason
                    elif next_cycle_timeout > cycle_timeout:
                        cycle_timeout = next_cycle_timeout
                        resume_cycle_timeout = cycle_timeout
                        if phase == 'confirming':
                            publish('confirming', cycle_timeout, confirmation_started_at)
                        else:
                            publish(phase, max(0, deadline - time.monotonic()))
                if output is not None:
                    text = os.pread(output.fileno(), 65536, 0).decode(errors='replace')
                    if any(line.startswith(('signal:', 'stale:', 'check:', 'heartbeat')) for line in text.splitlines()):
                        reason = 'watcher delivered an actionable wake'
                if not reason and probe_due and not supervision_needed:
                    send(active, dict(rc=0, reason='', token=token))
                    terminal_delivered = True
                    return
                if not reason and arm is not None and (arm.poll() is not None or not arm_identity):
                    reason = 'watcher failed; inspect its startup and ownership before continuing'
                if not reason and phase == 'starting' and probe_due:
                    proof = watcher_snapshot(cycle_timeout, check_batch_limit,
                                             transport_deadline - terminal_reserve)
                    now = time.monotonic()
                    if proof is not None:
                        if cycle_timeout > max(0, math.floor(
                                transport_deadline - now - checkpoint - terminal_reserve)):
                            reason = budget_reason
                        else:
                            boundary_sequence = watcher_check_batch_boundary(proof[3])
                            expected_batch_sequence = proof[4]
                            if proof[3] != token and boundary_sequence == proof[4]:
                                expected_batch_sequence = proof[4] + 1
                                if not request_watcher_check_batch(
                                        proof[3], expected_batch_sequence, token,
                                        os.getpid(), owner_identity, session_pid,
                                        session_identity, resume_deadline_epoch,
                                        resume_cycle_timeout, leased_registry_generation):
                                    reason = 'watcher failed; inspect its startup and ownership before continuing'
                                else:
                                    resume_authorization = (proof[3], token)
                            if not reason:
                                watcher_proof = proof
                                watcher_last_beat = proof[2]
                                watcher_last_progress = now
                                next_watcher_probe = now + watcher_cadence
                                publish('watching', checkpoint)
                    elif now >= transport_deadline - terminal_reserve:
                        reason = budget_reason
                    elif now >= deadline:
                        reason = 'watcher failed; inspect its startup and ownership before continuing'
                if not reason and phase == 'watching' and probe_due:
                    beat = watcher_beat()
                    if beat > watcher_last_beat:
                        watcher_last_beat = beat
                        watcher_last_progress = now
                    if now >= next_watcher_probe:
                        proof = watcher_snapshot(cycle_timeout, check_batch_limit,
                                                 transport_deadline - terminal_reserve)
                        now = time.monotonic()
                        if (proof is None or watcher_proof is None or
                                proof[:2] != watcher_proof[:2] or proof[2] < watcher_last_beat):
                            reason = 'watcher failed; inspect its startup and ownership before continuing'
                        else:
                            watcher_last_beat = proof[2]
                            next_watcher_probe = now + watcher_cadence
                    if not reason and now - watcher_last_progress >= cycle_timeout:
                        reason = 'watcher failed; inspect its startup and ownership before continuing'
                if not reason and phase == 'watching' and now >= deadline:
                    proof = watcher_snapshot(cycle_timeout, check_batch_limit,
                                             transport_deadline - terminal_reserve)
                    now = time.monotonic()
                    current_arm_identity = (identity(arm.pid, transport_deadline - terminal_reserve)
                                            if arm is not None else arm_identity)
                    now = time.monotonic()
                    if current_arm_identity is None:
                        reason = budget_reason
                    elif ((arm is not None and current_arm_identity != arm_identity) or
                            proof is None or watcher_proof is None or
                            proof[:2] != watcher_proof[:2]):
                        reason = 'watcher failed; inspect its startup and ownership before continuing'
                    elif cycle_timeout > max(0, math.floor(
                            transport_deadline - now - terminal_reserve)):
                        reason = budget_reason
                    else:
                        confirmation_started_at = now
                        publish('confirming', cycle_timeout, confirmation_started_at)
                if not reason and phase == 'confirming' and probe_due:
                    boundary_sequence = (watcher_check_batch_boundary(watcher_proof[3])
                                         if watcher_proof is not None else None)
                    if (watcher_proof is not None and expected_batch_sequence is not None and
                            boundary_sequence == expected_batch_sequence):
                        proof = watcher_snapshot(cycle_timeout, check_batch_limit,
                                                 transport_deadline - terminal_reserve)
                        now = time.monotonic()
                        current_arm_identity = (identity(
                            arm.pid, transport_deadline - terminal_reserve)
                            if arm is not None else arm_identity)
                        now = time.monotonic()
                        if current_arm_identity is None or now >= transport_deadline - terminal_reserve:
                            reason = budget_reason
                        elif (proof is not None and watcher_proof is not None and
                                proof[:2] == watcher_proof[:2] and proof[3] == watcher_proof[3] and
                                proof[4] == expected_batch_sequence and
                                (arm is None or current_arm_identity == arm_identity)):
                            reason = 'quiet checkpoint elapsed; supervision is still needed'
                        else:
                            reason = 'watcher failed; inspect its startup and ownership before continuing'
                    elif now >= deadline:
                        reason = 'watcher failed; inspect its startup and ownership before continuing'
                if reason and not finish(reason):
                    return
            elif now >= deadline:
                return
            elif phase == 'handling' and probe_due and not queued() and not supervision_needed:
                return
    except (OSError, ValueError, InterruptedError, subprocess.TimeoutExpired) as error:
        with open('.codex-stop-error', 'w') as stream:
            stream.write(str(error) + '\n')
    finally:
        cleanup_deadline = None
        if active is not None and transport_deadline is not None:
            cleanup_deadline = transport_deadline - identity_allowance - protocol_reserve
        cleanup_complete = cancel_arm(cleanup_deadline)
        terminal_cleanup_complete = cleanup_complete and arm is None
        if active is not None and not terminal_delivered:
            final_generation = False if generation_changed else generation_current(
                transport_deadline - protocol_reserve if transport_deadline is not None else None)
            time.monotonic()
            try:
                if final_generation is False:
                    send(active, dict(rc=0, reason='', token=token))
                else:
                    send(active, dict(rc=2, reason=budget_reason, token=token))
            except OSError:
                pass
        for conn in list(pending):
            close(conn)
        listener.close()
        selector.close()
        # Still holding the same kernel lock: no successor can have published.
        for path in (RECORD, SOCKET):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        lock.close()


def connect():
    record = read_record()
    if not record.get('token'):
        raise OSError('owner not ready')
    conn = socket.socket(socket.AF_UNIX)
    conn.settimeout(3)
    try:
        conn.connect(SOCKET)
    except OSError:
        conn.close()
        raise
    return conn, record


if mode == 'healthy':
    try:
        conn, record = connect()
        with conn:
            send(conn, dict(op='healthy', token=record['token'], record=record))
            answer = receive(conn)
        sys.exit(0 if answer.get('token') == record['token'] and answer.get('healthy') is True else 1)
    except (OSError, ValueError):
        sys.exit(1)

# Every invocation may propose an owner, but only the kernel lock winner runs.
# Losers never mutate shared state. No PID-based stale lock reclamation exists.
try:
    if not launcher_current():
        sys.exit(0)
    child = os.fork()
except OSError:
    print('Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.', file=sys.stderr)
    sys.exit(2)
if child == 0:
    try:
        os.setsid()
        null = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(null, fd)
        os.close(null)
        lock = open(LOCK, 'a+')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            owner(lock)
        except Exception as error:
            with open('.codex-stop-error', 'w') as stream:
                stream.write(type(error).__name__ + ': ' + str(error) + '\n')
    except (OSError, ValueError):
        pass
    os._exit(0)

conn = None
commit_pending = False
specific_refusal = False

def interrupted(_signum, _frame):
    if conn is not None:
        conn.close()
    sys.exit(0)

for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(sig, interrupted)
try:
    for attempt in range(30):
        if not launcher_current():
            sys.exit(0)
        try:
            conn, record = connect()
            break
        except OSError:
            time.sleep(0.1)
    if conn is None:
        raise OSError('owner unavailable')
    with conn:
        if (record.get('session_pid'), record.get('session_identity')) != (session_pid, session_identity):
            raise OSError('prior session owner still active')
        send(conn, dict(op='stop', token=record['token'], session_pid=session_pid,
                        session_identity=session_identity, session_id=session_id))
        response = receive(conn, transport_timeout)
        if response.get('token') != record['token']:
            raise OSError('owner identity changed')
        rc = response['rc']
        if response.get('retry') is True:
            print('Firstmate Codex supervision: ' + response['reason'] + '.', file=sys.stderr)
            sys.exit(2)
        if rc == 2:
            print('Firstmate Codex supervision: ' + response['reason'] +
                  '. Run bin/fm-wake-drain.sh, handle all presented work, then run its exact '
                  'WAKE_ACK_REQUIRED command. The next Stop owns watcher renewal; do not launch another watcher.',
                  file=sys.stderr, flush=True)
            specific_refusal = True
            send(conn, dict(op='accepted', token=record['token']))
            accepted = receive(conn)
            if accepted != dict(accepted=True, token=record['token']):
                raise OSError('continuation was not accepted')
            if os.environ.get('FM_CODEX_STOP_TEST_INTERRUPT_AFTER_ACCEPTED') == '1':
                os.kill(os.getpid(), signal.SIGTERM)
            blocked = {signal.SIGTERM, signal.SIGHUP, signal.SIGINT}
            signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
            if signal.sigpending().intersection(blocked):
                conn.close()
                os._exit(0)
            send(conn, dict(op='commit', token=record['token']))
            commit_pending = True
            committed = receive(conn)
            if committed == dict(committed=False, token=record['token']):
                os._exit(0)
            if committed != dict(committed=True, token=record['token']):
                raise OSError('continuation commit was not confirmed')
            os._exit(2)
    sys.exit(rc)
except TransportEnded:
    if commit_pending:
        if not specific_refusal:
            print('Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.', file=sys.stderr)
        sys.exit(2)
    sys.exit(0)
except (OSError, ValueError, KeyError):
    if not specific_refusal:
        print('Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.', file=sys.stderr)
    sys.exit(2)
PY
PYTHON_PID=$!
wait "$PYTHON_PID"
PYTHON_RC=$?
trap - HUP INT TERM
if [ "$MODE" = healthy ]; then
  [ "$PYTHON_RC" -eq 0 ] && exit 0
  exit 1
fi
case "$PYTHON_RC" in
  0|2) exit "$PYTHON_RC" ;;
  *)
    echo 'Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.' >&2
    exit 2
    ;;
esac

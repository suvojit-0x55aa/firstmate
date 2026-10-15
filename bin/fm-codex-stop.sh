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
    inactive_reconcile_timeout = int(os.environ.get('FM_INACTIVE_RECONCILE_BUDGET_SECS', '10')) + 1
    if inactive_reconcile_timeout <= 1 or inactive_reconcile_timeout > 31:
        raise ValueError
except ValueError:
    inactive_reconcile_timeout = 11


try:
    startup_timeout = min(12, max(1, int(os.environ.get('FM_ARM_CONFIRM_TIMEOUT', '10')))) + 1
except ValueError:
    startup_timeout = 11

transport_timeout = 590
protocol_reserve = 10
cycle_limit = transport_timeout - startup_timeout - checkpoint - protocol_reserve


def cycle_work():
    result = shell(r'''
for file in "$FM_STATE_OVERRIDE"/*.status "$FM_STATE_OVERRIDE"/*.turn-ended; do
  [ -f "$file" ] || continue
  if ! fm_wake_signal_seen_current "$FM_STATE_OVERRIDE" "$file"; then
    printf 'signal\t%s\n' "$(basename "$file")"
  fi
done
dir=${FM_PENDING_REPLY_DIR_OVERRIDE:-$FM_STATE_OVERRIDE/pending-replies}
[ -d "$dir" ] || exit 0
. "$1/fm-pending-reply-lib.sh" || exit 1
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
  fm_pending_reply_target_is_remote "$FM_STATE_OVERRIDE" "$task_id" || continue
  printf 'remote-recovery\t%s\n' "$(basename "$rec")"
done
''')
    if result is None or result.returncode != 0:
        return None
    signal_tasks = set()
    remote_recoveries = set()
    for line in result.stdout.splitlines():
        kind, separator, value = line.partition('\t')
        if not separator or not value:
            continue
        if kind == 'signal':
            if value.endswith('.status'):
                value = value[:-len('.status')]
            elif value.endswith('.turn-ended'):
                value = value[:-len('.turn-ended')]
            signal_tasks.add(value)
        elif kind == 'remote-recovery':
            remote_recoveries.add(value)
    return signal_tasks, len(remote_recoveries)


budget_window_cache = None
budget_window_cache_until = 0


def invalidate_budget_windows():
    global budget_window_cache_until
    budget_window_cache_until = 0


def budget_window_count():
    global budget_window_cache, budget_window_cache_until
    now = time.monotonic()
    if budget_window_cache is not None and now < budget_window_cache_until:
        return budget_window_cache
    result = shell(r'''
. "$1/fm-backend.sh" || exit 1
seen='|'
for meta in "$FM_STATE_OVERRIDE"/*.meta; do
  [ -f "$meta" ] || continue
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || continue
  case "$seen" in
    *"|$target|"*) continue ;;
  esac
  seen="$seen$target|"
  backend=$(fm_backend_of_meta "$meta")
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf unreadable)
  case "$agent_state" in
    dead|missing) ;;
    *) printf 'budget-window\t%s\n' "$target" ;;
  esac
done
''', timeout=8)
    if result is None or result.returncode != 0:
        return None
    windows = set()
    for line in result.stdout.splitlines():
        kind, separator, value = line.partition('\t')
        if kind == 'budget-window' and separator and value:
            windows.add(value)
    budget_window_cache = len(windows)
    budget_window_cache_until = now + max(5, watcher_cadence)
    return budget_window_cache


def watcher_cycle_timeout(check_limit=None):
    names = os.listdir('.')
    try:
        check_age = int(time.time()) - int(os.path.getmtime('.last-check'))
    except OSError:
        check_age = 999999
    due_checks = 0
    if check_age >= check_interval:
        due_checks = sum(name.endswith('.check.sh') and os.path.isfile(name) for name in names)
    work = cycle_work()
    if work is None:
        return cycle_limit + 1, check_limit or 1
    budget_windows = budget_window_count()
    if budget_windows is None:
        return cycle_limit + 1, check_limit or 1
    signal_tasks, remote_recoveries = work
    # The watcher attempts a cheap capture for every recorded target, but only
    # a worker not authoritatively dead can repeatedly reach the bounded
    # crew-state and worktree-write paths charged here. Backends without a
    # verified agent-state classifier remain included. If the aggregate agent
    # scan itself exceeds the bounded helper call, admission fails closed.
    non_check_components = math.ceil(
        watcher_cadence + inactive_reconcile_timeout + signal_grace +
        2 * crew_state_timeout * (len(signal_tasks) + budget_windows) +
        worktree_write_timeout * budget_windows +
        2 * remote_send_timeout * remote_recoveries + 5)
    if check_limit is None:
        check_limit = max(1, math.floor((cycle_limit - non_check_components) / check_timeout))
    checks_this_cycle = min(due_checks, check_limit)
    components = non_check_components + check_timeout * checks_this_cycle
    return max(watcher_guard_grace, components), check_limit


def shell(body, *args, timeout=3):
    try:
        return subprocess.run(['bash', '-c', '. "$1/fm-wake-lib.sh"; ' + body,
                               'codex-stop-probe', scripts, *args],
                              capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def identity(pid):
    result = shell('fm_pid_identity "$2"', str(pid))
    return result.stdout.rstrip('\n') if result and result.returncode == 0 else ''


def identity_in_group(pid, recorded, group):
    if identity(pid) != recorded:
        return False
    try:
        if os.getpgid(pid) != group:
            return False
    except OSError:
        return False
    return identity(pid) == recorded


def generation_current():
    try:
        return (not os.path.islink('.lock') and
                open('.lock').read().strip() == session_pid and
                bool(session_identity) and identity(session_pid) == session_identity and
                not os.path.exists('.afk'))
    except OSError:
        return False


def needed():
    result = shell('. "$1/fm-supervision-lib.sh"; fm_supervision_needed "$FM_STATE_OVERRIDE"')
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


def watcher_snapshot(grace):
    result = shell('fm_watcher_healthy "$FM_STATE_OVERRIDE" "$1/fm-watch.sh" "$2" "$FM_HOME" '
                   '&& printf "%s\\t%s\\n" "$FM_WATCHER_HEALTHY_PID" "$FM_WATCHER_HEALTHY_IDENTITY"',
                   str(grace))
    if result is None or result.returncode != 0:
        return None
    fields = result.stdout.rstrip('\n').split('\t')
    if len(fields) != 2 or not all(fields):
        return None
    try:
        beat = os.stat('.last-watcher-beat').st_mtime_ns
    except OSError:
        return None
    return fields[0], fields[1], beat


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
    confirmation_beat = 0
    cycle_timeout = watcher_guard_grace
    check_batch_limit = 1

    def publish(next_phase, seconds):
        nonlocal phase, deadline, published
        phase = next_phase
        deadline = time.monotonic() + seconds
        record = dict(token=token, owner=os.getpid(), owner_identity=owner_identity,
                      session_pid=session_pid, session_identity=session_identity,
                      session_id=session_id, phase=phase, deadline=time.time() + seconds)
        published = record
        fd, tmp = tempfile.mkstemp(prefix='.codex-stop-record.')
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(record, stream)
            os.replace(tmp, RECORD)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def cancel_arm():
        nonlocal arm, arm_identity, output
        if arm is not None:
            # Let the arm's TERM trap retire its watcher and finish lock cleanup
            # in order. If that bounded cleanup stalls, kill only its owned group;
            # attached foreign watchers are never members of that group.
            if arm.poll() is None:
                arm.terminate()
                try:
                    arm.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(arm.pid, signal.SIGKILL)
                    arm.wait(timeout=1)
            else:
                proof = watcher_proof or watcher_snapshot(cycle_timeout)
                owned_member = False
                if proof is not None:
                    try:
                        member_pid = int(proof[0])
                        owned_member = identity_in_group(member_pid, proof[1], arm.pid)
                    except ValueError:
                        owned_member = False
                if owned_member:
                    try:
                        os.killpg(arm.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    expires = time.monotonic() + 3
                    while time.monotonic() < expires:
                        if not identity_in_group(member_pid, proof[1], arm.pid):
                            break
                        time.sleep(0.05)
                    else:
                        if identity_in_group(member_pid, proof[1], arm.pid):
                            try:
                                os.killpg(arm.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
            arm = None
            arm_identity = ''
        if output is not None:
            output.close()
            output = None

    def close(conn):
        pending.pop(conn, None)
        try:
            selector.unregister(conn)
        except KeyError:
            pass
        conn.close()

    def finish(reason):
        nonlocal acknowledged
        cancel_arm()
        if not generation_current():
            return False
        publish('delivering', 5)
        acknowledged = False
        send(active, dict(rc=2, reason=reason, token=token))
        return True

    def stop_signal(_signum, _frame):
        raise InterruptedError('owner interrupted')

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, stop_signal)
    try:
        if not generation_current():
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
                    send(conn, dict(token=token, healthy=request.get('record') == published and
                                    phase in ('watching', 'confirming', 'handling') and
                                    time.monotonic() < deadline and
                                    generation_current()))
                    close(conn)
                elif conn is active and request.get('op') == 'accepted' and phase == 'delivering':
                    send(conn, dict(accepted=True, token=token))
                elif conn is active and request.get('op') == 'commit' and phase == 'delivering':
                    if not generation_current():
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
                        publish('starting', startup_timeout)
                        if queued():
                            if not finish('durable wake pending'):
                                return
                        elif not needed():
                            send(conn, dict(rc=0, reason='', token=token))
                            return
                        else:
                            invalidate_budget_windows()
                            cycle_timeout, check_batch_limit = watcher_cycle_timeout()
                            if cycle_timeout > cycle_limit:
                                if not finish('watcher cycle exceeds Codex Stop deadline; inspect live endpoints and outstanding supervision work'):
                                    return
                            else:
                                arm_environment = os.environ.copy()
                                arm_environment['FM_GUARD_GRACE'] = str(cycle_limit)
                                arm_environment['FM_CHECKS_PER_CYCLE'] = str(check_batch_limit)
                                arm_environment['FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION'] = '1'
                                output = tempfile.TemporaryFile()
                                arm = subprocess.Popen(['bash', scripts + '/fm-watch-arm.sh'], stdin=subprocess.DEVNULL,
                                                       stdout=output, stderr=output, start_new_session=True,
                                                       env=arm_environment)
                                arm_identity = identity(arm.pid)
            for conn, (_buf, expires) in list(pending.items()):
                if conn is not active and time.monotonic() >= expires:
                    close(conn)
            now = time.monotonic()
            probe_due = now >= next_probe or (
                phase in ('starting', 'watching', 'confirming') and now >= deadline)
            if probe_due:
                if not generation_current():
                    return
                supervision_needed = needed()
                next_probe = now + 1
            if phase in ('starting', 'watching', 'confirming') and active is not None:
                reason = 'durable wake pending' if queued() else ''
                if not reason and probe_due:
                    next_cycle_timeout, _next_check_limit = watcher_cycle_timeout(check_batch_limit)
                    if next_cycle_timeout > cycle_limit:
                        reason = 'watcher cycle exceeds Codex Stop deadline; inspect live endpoints and outstanding supervision work'
                    elif next_cycle_timeout > cycle_timeout:
                        cycle_timeout = next_cycle_timeout
                if output is not None:
                    text = os.pread(output.fileno(), 65536, 0).decode(errors='replace')
                    if any(line.startswith(('signal:', 'stale:', 'check:', 'heartbeat')) for line in text.splitlines()):
                        reason = 'watcher delivered an actionable wake'
                if not reason and probe_due and not supervision_needed:
                    send(active, dict(rc=0, reason='', token=token))
                    return
                if not reason and arm is not None and (arm.poll() is not None or not arm_identity):
                    reason = 'watcher failed; inspect its startup and ownership before continuing'
                if not reason and phase == 'starting' and probe_due:
                    proof = watcher_snapshot(cycle_timeout)
                    if proof is not None:
                        watcher_proof = proof
                        watcher_last_beat = proof[2]
                        watcher_last_progress = now
                        next_watcher_probe = now + watcher_cadence
                        publish('watching', checkpoint)
                    elif now >= deadline:
                        reason = 'watcher failed; inspect its startup and ownership before continuing'
                if not reason and phase == 'watching' and probe_due:
                    beat = watcher_beat()
                    if beat > watcher_last_beat:
                        watcher_last_beat = beat
                        watcher_last_progress = now
                    if now >= next_watcher_probe:
                        proof = watcher_snapshot(cycle_timeout)
                        if (proof is None or watcher_proof is None or
                                proof[:2] != watcher_proof[:2] or proof[2] < watcher_last_beat):
                            reason = 'watcher failed; inspect its startup and ownership before continuing'
                        else:
                            watcher_last_beat = proof[2]
                            next_watcher_probe = now + watcher_cadence
                    if not reason and now - watcher_last_progress >= cycle_timeout:
                        reason = 'watcher failed; inspect its startup and ownership before continuing'
                if not reason and phase == 'watching' and now >= deadline:
                    proof = watcher_snapshot(cycle_timeout)
                    if ((arm is not None and identity(arm.pid) != arm_identity) or
                            proof is None or watcher_proof is None or
                            proof[:2] != watcher_proof[:2]):
                        reason = 'watcher failed; inspect its startup and ownership before continuing'
                    else:
                        confirmation_beat = proof[2]
                        publish('confirming', cycle_timeout)
                if not reason and phase == 'confirming' and probe_due:
                    beat = watcher_beat()
                    if beat > confirmation_beat:
                        proof = watcher_snapshot(cycle_timeout)
                        if (proof is not None and watcher_proof is not None and
                                proof[:2] == watcher_proof[:2] and proof[2] > confirmation_beat and
                                (arm is None or identity(arm.pid) == arm_identity)):
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
        cancel_arm()
        if active is not None and not generation_current():
            try:
                send(active, dict(rc=0, reason='', token=token))
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
        print('Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.', file=sys.stderr)
        sys.exit(2)
    sys.exit(0)
except (OSError, ValueError, KeyError):
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

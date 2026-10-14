#!/usr/bin/env bash
# Codex-only native Stop continuation. No wake drain or acknowledgement here.
# A bounded local owner serializes Stop requests, record mutation, cancellation
# and successor handoff under one kernel flock. The hook is only a transport.
# It connects over a private Unix socket; no network/debugging API is involved.
# The owner watches only during a Stop request, using the unchanged watch-arm.
# Between Stops it holds an identity-checked handling lease for at most 300s.
# Closing an unanswered hook connection cancels its owned watcher process group;
# an independently attached watcher is outside that group and is never killed.
# No lock PID is trusted for exclusion or stale takeover: flock releases on death.
# The stable lock inode is never unlinked. Only its holder writes/removes records.
# --healthy STATE is a read-only challenge to the live owner, not a stale PID test.
# Requires Python 3's standard-library Unix socket/flock support; unavailable
# support blocks Stop with an explicit diagnostic rather than claiming coverage.
# FM_CODEX_WATCH_CHECKPOINT defaults to 180s, capped at 180s. Hook timeout: 240s.
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
export FM_HOME FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE"
exec python3 - "$MODE" "$STATE" "$SCRIPT_DIR" "$SESSION_PID" "$SESSION_IDENTITY" "$SESSION_ID" <<'PY'
import fcntl
import json
import os
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

mode, state, scripts, session_pid, session_identity, session_id = sys.argv[1:]
os.chdir(state)  # Relative socket pathname also works in deep worktree paths.
RECORD = '.codex-stop.json'
SOCKET = '.codex-stop.sock'
LOCK = '.codex-stop.owner-lock'  # Stable inode: never unlink or replace.
try:
    checkpoint = min(180, max(1, int(os.environ.get('FM_CODEX_WATCH_CHECKPOINT', '180'))))
except ValueError:
    checkpoint = 180


try:
    handling_grace = min(300, max(1, int(os.environ.get('FM_CODEX_HANDLING_GRACE', '300'))))
except ValueError:
    handling_grace = 300


def shell(body, *args):
    try:
        return subprocess.run(['bash', '-c', '. "$1/fm-wake-lib.sh"; ' + body,
                               'codex-stop-probe', scripts, *args],
                              capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None


def identity(pid):
    result = shell('fm_pid_identity "$2"', str(pid))
    return result.stdout.rstrip('\n') if result and result.returncode == 0 else ''


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


def read_record():
    try:
        with open(RECORD) as stream:
            return json.load(stream)
    except (OSError, ValueError):
        return {}


def send(conn, value):
    conn.sendall((json.dumps(value) + '\n').encode())


def receive(conn):
    data = b''
    while b'\n' not in data:
        block = conn.recv(8192)
        if not block or len(data) > 16384:
            raise OSError('closed or invalid owner response')
        data += block
    return json.loads(data.split(b'\n', 1)[0])


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
            # An unreaped direct child cannot have a reused PID. It started its
            # own process group; attached foreign watchers are never members.
            if arm.poll() is None and arm_identity and identity(arm.pid) == arm_identity:
                os.killpg(arm.pid, signal.SIGTERM)
                try:
                    arm.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(arm.pid, signal.SIGKILL)
                    arm.wait(timeout=1)
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
                                    phase in ('watching', 'handling') and time.monotonic() < deadline and
                                    generation_current()))
                    close(conn)
                elif conn is active and request.get('op') == 'accepted' and phase == 'delivering':
                    send(conn, dict(accepted=True, token=token))
                elif conn is active and request.get('op') == 'commit' and phase == 'delivering':
                    if not generation_current():
                        return
                    publish('handling', handling_grace)
                    acknowledged = True
                elif request.get('op') == 'stop':
                    if (request.get('session_pid'), request.get('session_identity'), request.get('session_id')) != (
                            session_pid, session_identity, session_id):
                        send(conn, dict(rc=2, reason='session generation changed; retry Stop', token=token))
                        close(conn)
                    elif active is not None or phase == 'watching':
                        send(conn, dict(rc=0, reason='', token=token))
                        close(conn)
                    else:
                        active = conn
                        acknowledged = False
                        publish('watching', checkpoint)
                        if queued():
                            if not finish('durable wake pending'):
                                return
                        elif not needed():
                            send(conn, dict(rc=0, reason='', token=token))
                            return
                        else:
                            output = tempfile.TemporaryFile()
                            arm = subprocess.Popen(['bash', scripts + '/fm-watch-arm.sh'], stdin=subprocess.DEVNULL,
                                                   stdout=output, stderr=output, start_new_session=True)
                            arm_identity = identity(arm.pid)
            for conn, (_buf, expires) in list(pending.items()):
                if conn is not active and time.monotonic() >= expires:
                    close(conn)
            now = time.monotonic()
            probe_due = now >= next_probe or (phase == 'watching' and now >= deadline)
            if probe_due:
                if not generation_current():
                    return
                supervision_needed = needed()
                next_probe = now + 1
            if phase == 'watching' and active is not None:
                reason = 'durable wake pending' if queued() else ''
                if output is not None:
                    text = os.pread(output.fileno(), 65536, 0).decode(errors='replace')
                    if any(line.startswith(('signal:', 'stale:', 'check:', 'heartbeat')) for line in text.splitlines()):
                        reason = 'watcher delivered an actionable wake'
                if not reason and probe_due and not supervision_needed:
                    send(active, dict(rc=0, reason='', token=token))
                    return
                if not reason and arm is not None and (arm.poll() is not None or not arm_identity):
                    reason = 'watcher failed; inspect its startup and ownership before continuing'
                if not reason and now >= deadline:
                    if arm is not None and identity(arm.pid) != arm_identity:
                        reason = 'watcher failed; inspect its startup and ownership before continuing'
                    else:
                        reason = 'quiet checkpoint elapsed; supervision is still needed'
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
child = os.fork()
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

def interrupted(_signum, _frame):
    if conn is not None:
        conn.close()
    sys.exit(0)

for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(sig, interrupted)
try:
    for attempt in range(30):
        try:
            conn, record = connect()
            break
        except OSError:
            time.sleep(0.1)
    if conn is None:
        raise OSError('owner unavailable')
    with conn:
        if (record.get('session_pid'), record.get('session_identity'), record.get('session_id')) != (session_pid, session_identity, session_id):
            raise OSError('prior session owner still active')
        send(conn, dict(op='stop', token=record['token'], session_pid=session_pid,
                        session_identity=session_identity, session_id=session_id))
        conn.settimeout(checkpoint + 15)
        response = receive(conn)
        if response.get('token') != record['token']:
            raise OSError('owner identity changed')
        rc = response['rc']
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
            os._exit(2)
    sys.exit(rc)
except (OSError, ValueError, KeyError):
    print('Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.', file=sys.stderr)
    sys.exit(2)
PY

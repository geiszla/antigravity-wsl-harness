#!/bin/bash
# Starts the Antigravity IDE server, detached from any IDE window.
# Replicates the IDE's own install-script conventions (pid/token/log file names,
# flock on .installation_lock) so the IDE's resolver finds this server and never
# starts its own window-owned one (the "anchor window" bug: the extension's
# resolver keeps the server alive only from the FIRST window's wsl.exe;
# confirmed in the installed resolver code, closest public report:
# https://github.com/jeanp413/open-remote-wsl/issues/2).
set -u

. /usr/local/lib/antigravity-server-common.sh

DISTRO_NAME=fedoraremix
DATA="$AG_DATA"

# exit 75 = a DELIBERATE, known launch failure. The unit sets
# RestartPreventExitStatus=75 so Restart=always does NOT re-burst on these;
# recovery is owned by antigravity-server-update-check.sh, which backs off
# (60 min / version change / manual restart) using the marker below. Every
# critical pre-readiness failure routes through here so none of them can be
# hammered five-at-a-time each minute.
# Marker's first field: the target dir if known, else the caller's arg, else
# "ANY" — a target-independent failure (e.g. lock failure, before a target is
# selected) the checker also backs off on. Written to $AG_RUNDIR (always
# writable, even when $DATA is not) with a CLOCK_BOOTTIME stamp (jump-immune).
fail_launch() {
    echo "${1:-${DIR:-ANY}} $(ag_boottime)" > "$AG_RUNDIR/launch-failed" 2>/dev/null
    exit 75
}

# Take the IDE's install lock FIRST — even before selecting a version: a
# resolver mid-install holds this lock, so waiting here means we select on the
# post-install state instead of racing it; and a window connecting (or
# reloading) while we start must wait for us, not race us to start its own
# window-owned server. If we CANNOT lock, we must not proceed unserialized and
# race the resolver — the exact race the lock prevents; fail deliberately with a
# target-independent marker so the checker backs off instead of retrying every
# minute.
if ! { [ -d "$DATA" ] && [ -w "$DATA" ]; }; then
    echo "install-lock dir missing or not writable: $DATA" >&2
    fail_launch ANY
fi
exec 200>"$DATA/.installation_lock"
if ! true >&200 2>/dev/null; then
    echo "could not open install-lock fd" >&2
    fail_launch ANY
fi
if ! flock 200; then
    echo "could not acquire install lock" >&2
    fail_launch ANY
fi

# --- Server version selection -------------------------------------------------
# Exact version Windows Antigravity runs (handles up- AND downgrades), if fully
# installed; otherwise the newest COMPLETE cached version — a stale-but-working
# server is harmless to the resolver and keeps this unit healthy, and the
# update timer converges to the exact target once its install completes.
DIR=""
if TARGET="$(ag_product_target)"; then
    DIR="$TARGET"
fi
if [ -z "$DIR" ]; then
    DIR="$(ag_newest_complete)" || true
fi
if [ -z "$DIR" ]; then
    # exit 75: no burst. Deliberately NO marker — the checker already no-ops
    # when nothing is installed (want is empty), and an ANY marker here would
    # make it back off from a server that gets installed within the next hour.
    echo "No runnable server under $DATA/bin" >&2
    exit 75
fi
NAME="$(basename "$DIR")"      # e.g. 2.1.1-<commit-sha>
COMMIT="${NAME##*-}"
DIRESC="${DIR//./\\.}"         # pgrep/pkill -f patterns are regexes; escape the dots

SERVER_SCRIPT="$DIR/bin/antigravity-ide-server"
TOKENFILE="$DATA/.$COMMIT.token"
PIDFILE="$DATA/.$COMMIT.pid"
LOGFILE="$DATA/.$COMMIT.log"
# (No readonly/skip-list needed for env parity: captured values are applied to
# the SERVER via `env` below, never exported into this launcher's shell, so they
# cannot collide with these control vars.)

# A server for our target is already running outside this service: a
# window-owned "native" one the resolver started (e.g. a window connected during
# a manual restart / crash gap). Do NOT kill it and disrupt its live windows and
# agents — refuse (exit 75, no marker); the update checker's native deferral
# takes over once it exits. (A server inside our own cgroup cannot exist here:
# KillMode=control-group empties the cgroup before every start.)
if ag_native_server_running "$DIR"; then
    echo "A native (window-owned) server for this version is already serving windows; deferring — the checker takes over when it exits" >&2
    exit 75
fi

# Stable interop socket FIRST: the env capture (wsl.exe) and the fallback's
# cmd.exe PATH recovery both need working interop, and real sessions' own
# sockets die with the session — ours must outlive any of them.
if [ -z "${WSL_INTEROP:-}" ] && [ -e /run/WSL/1_interop ]; then
    export WSL_INTEROP=/run/WSL/1_interop
fi

# --- Environment ------------------------------------------------------------
# The server (and every terminal/agent it spawns) inherits the server's env. We
# build that env EXPLICITLY as an array (SRV_ENV) and launch the server through
# `env` below — so captured/user values are applied to the SERVER only, never
# exported into this launcher's shell. That gives full session PARITY (e.g. the
# real WSL session's NAME=<hostname> reaches the server) with no risk of a
# captured var colliding with a launcher control var. Preferred source: a real
# wsl.exe session captured via interop; fallback: reconstruct.
declare -a SRV_ENV=()
ENV_SOURCE=fallback
# SAFETY (microsoft/WSL#41592, present in every WSL < 3.0, fixed in 3.0 by PRs
# #40691/#40433): the distro init's single Interop thread creates login
# sessions one at a time, and if a client disconnects while init is still
# working on its session (a kill-on-timeout, exactly what `timeout 15` did at
# boot on 2026-10-29), init aborts with SIGABRT. From then on every new wsl.exe
# session fails with Wsl/Service/E_UNEXPECTED and the 9p share hangs, until
# `wsl --terminate`. Mitigations, per the issue's own recommendation:
#  1. wait for the user manager first (the unit also Wants=/After= it): WSL's
#     CreateLoginSession polls `user@<uid>.service` for up to boot.initTimeout
#     (10 s) before the session starts; with the manager up it returns at once;
#  2. a LONG bound (CAPTURE_TIMEOUT) only as a last resort against a wedged
#     interop, long enough that init cannot still be mid-session when it fires;
#  3. no retry after a timeout: a second kill is a second chance to crash init,
#     and a wedged interop would not serve a retry anyway. Fast failures
#     (e.g. binfmt not yet registered) are still retried.
INTEROP_OK=1
CAPTURE_TIMEOUT=120
for _ in $(seq 1 60); do
    systemctl is-active --quiet "user@$(id -u).service" && break
    sleep 0.5
done
if ! systemctl is-active --quiet "user@$(id -u).service"; then
    echo "Warning: user@$(id -u).service not active after 30s; session capture may be slow" >&2
fi
ENVFILE="$(mktemp)"
for attempt in 1 2 3; do
    timeout "$CAPTURE_TIMEOUT" /mnt/c/Windows/System32/wsl.exe -d "$DISTRO_NAME" --exec /usr/bin/env -0 > "$ENVFILE" 2>/dev/null
    rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$ENVFILE" ]; then
        ENV_SOURCE=captured
        break
    fi
    if [ "$rc" -eq 124 ]; then
        echo "Environment capture timed out after ${CAPTURE_TIMEOUT}s; interop looks wedged, not retrying (microsoft/WSL#41592)" >&2
        INTEROP_OK=0
        break
    fi
    echo "Environment capture attempt $attempt failed (rc=$rc), retrying" >&2
    sleep 2
done
if [ "$ENV_SOURCE" = captured ]; then
    while IFS= read -r -d '' kv; do
        name="${kv%%=*}"
        case "$name" in
            # per-process / per-session values we must not carry across:
            # a captured WSL_INTEROP socket dies with the capture session;
            # fedoraremix exports a pre-wrapped DEFAULT PS1 into session envs,
            # which would pin terminals to the "bash-5.2$" prompt because
            # /etc/bashrc only upgrades PS1 when it exactly equals bash's default:
            PWD|OLDPWD|SHLVL|_|HOSTNAME|TERM|WSL_INTEROP|PS1|PS2|PROMPT_COMMAND) continue ;;
        esac
        case "$name" in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac
        SRV_ENV+=("$kv")
    done < "$ENVFILE"
fi
rm -f "$ENVFILE"

if [ "$ENV_SOURCE" = captured ]; then
    echo "Environment adopted from a live WSL session" >&2
else
    echo "Warning: interop capture unavailable after 3 attempts, reconstructing WSL session environment" >&2
    SRV_ENV+=("WSL_DISTRO_NAME=${WSL_DISTRO_NAME:-$DISTRO_NAME}" "WSLENV=${WSLENV:-}")
    if [ -f /etc/locale.conf ]; then
        . /etc/locale.conf
        [ -n "${LANG:-}" ] && SRV_ENV+=("LANG=$LANG")
    fi
    [ -d "/run/user/$(id -u)" ] && SRV_ENV+=("XDG_RUNTIME_DIR=/run/user/$(id -u)")
    [ -S "/run/user/$(id -u)/bus" ] && SRV_ENV+=("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus")
    if [ -d /mnt/wslg ]; then
        SRV_ENV+=("DISPLAY=${DISPLAY:-:0}" "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}" "PULSE_SERVER=${PULSE_SERVER:-unix:/mnt/wslg/PulseServer}")
    fi
    RPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games"
    [ -d /usr/lib/wsl/lib ] && RPATH="$RPATH:/usr/lib/wsl/lib"
    # Skipped when the capture timed out: interop is wedged, and killing another
    # interop client on a timeout is the same crash trigger (WSL#41592).
    WINPATH=""
    if [ "$INTEROP_OK" = 1 ]; then
        WINPATH="$(cd /mnt/c 2>/dev/null && timeout 30 /mnt/c/Windows/System32/cmd.exe /c "echo %PATH%" 2>/dev/null | tr -d '\r')"
    fi
    if [ -n "$WINPATH" ]; then
        IFS=';' read -ra WENTRIES <<< "$WINPATH"
        for e in "${WENTRIES[@]}"; do
            [ -z "$e" ] && continue
            u="$(wslpath -u "$e" 2>/dev/null)" || continue
            [ -n "$u" ] && RPATH="$RPATH:$u"
        done
    fi
    SRV_ENV+=("PATH=$RPATH")
fi
# Stable interop socket for the server and everything it spawns (a real session's
# own socket dies with the session). Overrides whatever the capture carried.
[ -e /run/WSL/1_interop ] && SRV_ENV+=("WSL_INTEROP=/run/WSL/1_interop")
# systemd service metadata that a normal WSL session never has — unset it from
# the server env (env -u below) so it doesn't leak into terminals.
SRV_UNSET=(INVOCATION_ID JOURNAL_STREAM SYSTEMD_EXEC_PID RUNTIME_DIRECTORY
           MEMORY_PRESSURE_WATCH MEMORY_PRESSURE_WRITE
           LISTEN_FDS LISTEN_PID LISTEN_FDNAMES NOTIFY_SOCKET WATCHDOG_PID WATCHDOG_USEC)
UNSET_ARGS=(); for v in "${SRV_UNSET[@]}"; do UNSET_ARGS+=(-u "$v"); done
# -----------------------------------------------------------------------------

if [ ! -s "$TOKENFILE" ]; then
    # subshell: the restrictive umask must not leak to the server/terminals
    (umask 177; tr -dc 0-9 </dev/urandom | head -c 10 > "$TOKENFILE")
fi
chmod 600 "$TOKENFILE"

# Truncate so the resolver's port-grep only ever sees the current instance.
: > "$LOGFILE"

# Same flags the IDE uses, minus --enable-remote-auto-shutdown: systemd owns
# the lifetime now, the server must not dispose itself. Launch through `env` so
# the server gets exactly SRV_ENV (full session parity) minus the systemd
# metadata (UNSET_ARGS); `env` execs the server, so $! is the server's pid.
# --reconnection-grace-time (seconds; server default 10800 = 3 h): how long the
# server keeps a disconnected window's state, and the value it hands to the
# client. The client applies it to its Management connection only; the
# ExtensionHost connection (Source Control) keeps a built-in 3 h wall-clock
# limit, which antigravity-client-patch.sh raises to the same 7 days.
START_TS="$(ag_boottime)"
env "${UNSET_ARGS[@]}" "${SRV_ENV[@]}" \
    "$SERVER_SCRIPT" --start-server --host=127.0.0.1 --port=0 \
    --connection-token-file "$TOKENFILE" --telemetry-level off \
    --use-host-proxy --disable-websocket-compression \
    --without-browser-env-var --accept-server-license-terms \
    --reconnection-grace-time 604800 \
    >> "$LOGFILE" 2>&1 &
SPID=$!
echo "$SPID" > "$PIDFILE"

# Hold the lock until the server is accepting connections. Never expose an
# unconfirmed server to the resolver: if it dies or stays silent past 60s,
# clean up and fail while still holding the lock (released only at exit,
# when the failure is definitive), so systemd's restart/start-limit logic
# sees the truth.
STARTED=0
for _ in $(seq 1 120); do
    if ! kill -0 "$SPID" 2>/dev/null; then
        echo "Server died during startup; last log lines:" >&2
        tail -n 20 "$LOGFILE" >&2
        fail_launch
    fi
    grep -q 'Extension host agent listening on' "$LOGFILE" && { STARTED=1; break; }
    sleep 0.5
done
if [ "$STARTED" != 1 ]; then
    echo "Server alive but not listening after 60s; killing it and failing" >&2
    kill "$SPID" 2>/dev/null
    pkill -u "$(id -u)" -f "$DIRESC/out/server-mai[n].js" 2>/dev/null
    sleep 1
    kill -9 "$SPID" 2>/dev/null
    fail_launch
fi

# Record what we run ONLY once confirmed listening: a failed start must leave
# the previous record in place so the update timer keeps retrying the restart.
echo "$DIR" > "$DATA/.service-server-dir"
rm -f "$AG_RUNDIR/launch-failed"

flock -u 200
exec 200>&-

wait "$SPID"; rc=$?
# The server exited. If it died soon after becoming healthy, treat it as a
# launch failure (exit 75) so systemd does not re-burst and the checker's
# backoff throttles retries. A server that ran a good while and then exited is
# a normal event — let Restart=always bring it straight back. Boottime, not
# wall-clock, so a clock jump can't misjudge the uptime.
if [ $(( $(ag_boottime) - START_TS )) -lt 120 ]; then
    echo "$DIR $(ag_boottime)" > "$AG_RUNDIR/launch-failed" 2>/dev/null
    exit 75
fi
exit "$rc"

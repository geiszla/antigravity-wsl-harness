#!/bin/bash
# Runs every minute (timer). Restarts antigravity-server only when that is both
# NEEDED (version mismatch or failed service) and SAFE (never for an incomplete
# install, never re-attacking a target that just failed, never killing a
# working native server merely to retry a broken one).
set -u
. /usr/local/lib/antigravity-server-common.sh

# What should be running? When product.json is authoritative, exact target
# only: if it isn't fully installed yet (install in progress / not yet
# connected since the update), DO NOT DISTURB the working service — we'll
# converge on a later tick once the executable appears. Fallback to the newest
# complete cached version only when product.json is unreadable/unparseable.
if want="$(ag_product_target)"; then
    [ -n "$want" ] || exit 0
else
    want="$(ag_newest_complete)" || exit 0
fi

# .service-server-dir records the last server CONFIRMED listening.
current="$(cat "$AG_DATA/.service-server-dir" 2>/dev/null || true)"
if [ "$want" = "$current" ] && ! systemctl is-failed --quiet antigravity-server; then
    exit 0
fi

# UNCONDITIONAL native-target deferral: if a server for 'want' is already
# running OUTSIDE our cgroup (a window-owned native server — typically right
# after an app update/relaunch, BEFORE we've migrated, with no launch-failed
# marker yet), never restart: the launcher's takeover would kill that native
# server and disrupt its live windows/agents. Defer and take over once it exits.
# (This is the ordinary first-migration case the old marker-gated check missed.)
if ag_native_server_running "$want"; then
    echo "Deferring restart to '$want': a native server for it is already running (serving windows); will take over when it exits"
    exit 0
fi

# Rate-limit blind retries after a recent DELIBERATE launch failure. The marker
# lives in $AG_RUNDIR (a per-boot tmpfs the launcher can always write, even when
# $AG_DATA is not writable — so lock/dir failures still register a backoff), and
# its stamp is CLOCK_BOOTTIME.
if [ -s "$AG_RUNDIR/launch-failed" ]; then
    read -r fdir fts < "$AG_RUNDIR/launch-failed" || true
    # SECURITY: this file is written by the unprivileged launcher but read here
    # as ROOT. Bash arithmetic recursively evaluates its operands, and an
    # array-subscript operand runs command substitution — so a crafted stamp
    # like 'now[$(cmd)]' would execute cmd as root inside $(( )). Force the
    # field to pure digits BEFORE any arithmetic; fdir is only string-compared.
    case "$fts" in
        ''|*[!0-9]*) fts=0 ;;
    esac
    # Same clock the launcher stamped with; both are seconds-since-THIS-boot, and
    # the marker cannot outlive the boot (tmpfs), so the delta is always valid.
    age=$(( $(ag_boottime) - fts ))
    # Back off for the same target ('want') or a target-independent failure
    # ('ANY', e.g. a lock/dir failure before selection). A marker for a
    # DIFFERENT dir does not gate — a genuine version change retries promptly.
    if { [ "$fdir" = "$want" ] || [ "$fdir" = ANY ]; } && [ "$age" -lt 3600 ]; then
        echo "Skipping restart: '$fdir' launch failed $(( age / 60 )) min ago (retry after 60 min / a version change / manual restart)"
        exit 0
    fi
fi

# Destructive-restart guard: if the server is systemd-active (NB: that means the
# main process is running, not necessarily listening/responsive) AND its cgroup
# holds active terminals/extension hosts, restarting now (a version migration)
# would kill every terminal, extension host, MCP server and agent in it. Defer —
# the app applies updates on relaunch, which drains the cgroup, so migration
# lands at the next idle moment. A dead server that left NO stranded processes
# has an empty cgroup (ag_has_active_windows false) and is revived promptly; a
# wedged server WITH stranded processes stays deferred, which is the safe choice
# (don't kill work) — the checker only reaches here on a version change or a
# failed unit, never for a still-listening same-version server (early-exit above).
if systemctl is-active --quiet antigravity-server && ag_has_active_windows; then
    echo "Deferring restart to '$want': server cgroup is serving active windows/terminals; will proceed when idle"
    exit 0
fi

echo "Wanted server '$want' (recorded: '${current:-none}', state: $(systemctl is-active antigravity-server)); restarting antigravity-server"
# The launcher's flock on .installation_lock makes this safe mid-install: it
# waits until the resolver's install finishes before taking over. reset-failed
# is safe now: RestartPreventExitStatus=75 means deliberate launch failures
# never burn the Restart=always burst, and the backoff above gates this path to
# at most once per 60 min for a repeatedly-failing same target.
systemctl reset-failed antigravity-server 2>/dev/null
systemctl restart antigravity-server || { echo "restart command failed"; exit 1; }

# Shared by antigravity-server-launch.sh and antigravity-server-update-check.sh
# (antigravity-client-patch.sh also sources it, for AG_PRODUCT_JSON only).
# Selection PRIMITIVES live here so the two scripts can't drift; the POLICIES
# deliberately differ:
#   - launcher: exact target, else newest COMPLETE cached version (a stale
#     server is harmless and keeps the unit healthy)
#   - update-check: exact target only; when product.json is authoritative but
#     the target isn't fully installed yet, it must NOT disturb anything
#     (fallback is reserved for an unreadable/unparseable product.json)

AG_DATA=/home/YOUR_LINUX_USER/.antigravity-ide-server
# Windows-side install; if this path moves, callers degrade to newest-cached.
AG_PRODUCT_JSON="/mnt/c/Users/YOUR_WINDOWS_USER/AppData/Local/Programs/Antigravity IDE/resources/app/product.json"

# systemd RuntimeDirectory=antigravity-server (RuntimeDirectoryPreserve=yes):
# a per-boot tmpfs dir, created by systemd BEFORE ExecStart and ALWAYS writable
# by the service user even if $AG_DATA is not. Holds ephemeral runtime state:
#   $AG_RUNDIR/launch-failed  = "<key> <boottime_s>" (deliberate-failure marker)
# Wiped on reboot, so its timestamps never span boots — see ag_boottime.
# Persistent state ($AG_DATA/.service-server-dir = last dir confirmed listening)
# stays in $AG_DATA.
AG_RUNDIR=/run/antigravity-server

# Seconds since boot from CLOCK_BOOTTIME (/proc/uptime): monotonic, never jumps
# with wall-clock (NTP/manual/DST) changes — unlike `date +%s`. Used for the
# failure backoff so a backward clock jump can't extend it or a forward jump end
# it early. Safe to subtract only within one boot (the marker lives in the
# per-boot $AG_RUNDIR, so it always is).
ag_boottime() { cut -d. -f1 /proc/uptime; }

# True if the service cgroup currently holds a live terminal, extension host, or
# pty host — i.e. real user work (windows, agents, MCP servers, shells) that a
# restart would kill along with the server. The update checker uses this to
# DEFER a destructive version-migration restart until the cgroup is idle: the
# app applies its updates on relaunch, which closes those windows and drains the
# cgroup, so migration lands at the next idle moment instead of nuking active
# work. A failed/dead server has an empty cgroup, so revival is never gated.
# Scoped to OUR cgroup so a native server's windows don't count.
ag_has_active_windows() {
    local cg=/sys/fs/cgroup/system.slice/antigravity-server.service/cgroup.procs pid cl
    [ -r "$cg" ] || return 1
    while read -r pid; do
        cl="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
        case "$cl" in
            *shellIntegration-bash*|*--type=extensionHost*|*--type=ptyHost*) return 0 ;;
        esac
    done < "$cg"
    return 1
}

# True if a server for $1 (a bin dir) is running OUTSIDE our service cgroup —
# i.e. a window-owned "native" server the app started (e.g. right after an app
# update, before we migrate). Its windows are NOT in our cgroup, so
# ag_has_active_windows can't see them; the update checker uses THIS to defer a
# migration unconditionally rather than have the launcher's takeover kill a
# native server that is serving live windows. We take over once it exits.
ag_native_server_running() {
    local dir="$1" esc pid cg=/sys/fs/cgroup/system.slice/antigravity-server.service/cgroup.procs
    esc="${dir//./\\.}"
    for pid in $(pgrep -u YOUR_LINUX_USER -f "$esc/bin/antigravity-ide-serve[r]" 2>/dev/null); do
        grep -qx "$pid" "$cg" 2>/dev/null || return 0   # a want-server not in our cgroup = native
    done
    return 1
}

# Echoes the exact server dir Windows Antigravity wants, IF fully installed
# (executable present); echoes nothing when the target isn't installed yet.
# Returns 1 only when product.json is unreadable or unparseable.
ag_product_target() {
    local v c
    [ -r "$AG_PRODUCT_JSON" ] || return 1
    v="$(tr -d '\r\n' < "$AG_PRODUCT_JSON" | grep -o '"ideVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    c="$(tr -d '\r\n' < "$AG_PRODUCT_JSON" | grep -o '"commit"[[:space:]]*:[[:space:]]*"[0-9a-f]\{40\}"' | head -1 | grep -o '[0-9a-f]\{40\}')"
    { [ -n "$v" ] && [ -n "$c" ]; } || return 1
    [ -x "$AG_DATA/bin/$v-$c/bin/antigravity-ide-server" ] && echo "$AG_DATA/bin/$v-$c"
    return 0
}

# Echoes the newest cached server dir that is actually runnable (executable
# present) — never an incomplete/in-progress install. Returns 1 if none.
ag_newest_complete() {
    local d
    for d in $(ls -1d "$AG_DATA"/bin/*/ 2>/dev/null | sort -rV); do
        d="${d%/}"
        if [ -x "$d/bin/antigravity-ide-server" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

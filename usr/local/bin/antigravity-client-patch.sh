#!/bin/bash
# Re-applies ONE client-side constant in the Windows Antigravity install after
# every IDE update. Runs as the service user (never root) from
# antigravity-client-patch.service, which antigravity-server-update.service
# pulls in on every tick of its minutely timer.
#
# WHY: Antigravity's workbench (VS Code 1.107 base) gives the remote
# ExtensionHost connection a fixed 3 h reconnection grace time measured in
# WALL-CLOCK time, and hands the server's --reconnection-grace-time only to the
# Management connection. After an overnight hibernate the first failed retry on
# wake therefore counts as "grace time expired": the window drops its remote
# extension host and Source Control stays empty until Reload Window.
# Upstream fix: microsoft/vscode#338062 (VS Code 1.141), not in Antigravity as
# of 2.8.0. This raises the client default from 3 h (108e5 ms) to 7 d (6048e5),
# the same value the launcher passes to the server.
#
# WHAT: in <app>/out/vs/workbench/workbench.desktop.main.js replace the single
# occurrence of OLD_TOKEN with NEW_TOKEN, then store the bundle's new SHA-256 in
# <app>/product.json ("checksums"); without that the IDE reports a corrupt
# installation. Two copies are handled:
#   staged     <install>/_/resources/app  an update unpacked by the background
#              installer, which then waits for the IDE to exit before moving it
#              into place. Patched as soon as it is complete, and only while the
#              IDE is still running (installer still waiting), so the update
#              arrives already fixed and we never write while files are moved.
#   installed  <install>/resources/app    patched only while the IDE is closed
#              and no update is staged: product.json checksums are read once at
#              IDE start, so changing the bundle under a running IDE makes
#              windows loaded afterwards warn about a corrupt installation.
#
# SAFETY: every decision is made from file CONTENT, never from saved state.
#   - Patch only when the bundle's hash equals the product.json checksum (the
#     file is complete and untouched) AND OLD_TOKEN occurs exactly once.
#   - The patched file must differ by that one token only (substitute back and
#     compare hashes) before anything on the Windows side is replaced.
#   - New files are written NEXT TO their targets and moved in by rename, bundle
#     first. Next to the target on purpose: a file inherits the permissions of
#     the folder it is created in, and a rename keeps them. Staging in the
#     Windows Temp folder gave the patched bundle Temp's ACL, which lets sandbox
#     accounts (e.g. CodexSandboxUsers) modify it (found 2026-11-24).
#   - An interrupted run is recognised on the next tick (patched token present,
#     checksum stale) and completed.
#   - Anything unexpected: change nothing, say so in the journal.
# The cache in $RUNTIME_DIRECTORY only avoids re-reading the 27 MB bundle every
# minute; it is per boot and safe to delete.
#
# Manual check (as the service user):  antigravity-client-patch.sh --dry-run
# Undo: update/reinstall Antigravity, or swap the token back and restore the old
# checksum. To retire this step remove this script,
# antigravity-client-patch.service and
# antigravity-server-update.service.d/10-client-patch.conf, then daemon-reload.
set -u
export LC_ALL=C
. /usr/local/lib/antigravity-server-common.sh

DRY=0
[ "${1:-}" = --dry-run ] && DRY=1

OLD_TOKEN='this._reconnectionGraceTime=108e5'
NEW_TOKEN='this._reconnectionGraceTime=6048e5'
OLD_RE='this\._reconnectionGraceTime=108e5'
NEW_RE='this\._reconnectionGraceTime=6048e5'
# The buggy wall-clock deadline check, e.g. `Date.now()-r>=n){const l=Math.round(n/1e3)`
# (identifier names change per build). Only used to announce that upstream's fix
# has arrived; the patch is harmless either way.
ID='[A-Za-z_$][A-Za-z0-9_$]*'
BUG_RE="Date\\.now\\(\\)-${ID}>=${ID}\\)\\{const ${ID}=Math\\.round\\(${ID}/1e3\\)"
BUNDLE_REL='out/vs/workbench/workbench.desktop.main.js'
CHECKSUM_KEY='vs/workbench/workbench.desktop.main.js'

# AG_CLIENT_PATCH_TEST_* are test hooks (fixture root / forced IDE state); the
# unit never sets them.
WIN_ROOT="${AG_CLIENT_PATCH_TEST_ROOT:-${AG_PRODUCT_JSON%/resources/app/product.json}}"
WIN_HOME="${AG_PRODUCT_JSON%%/AppData/*}"
APP_LOCK="$WIN_HOME/AppData/Roaming/Antigravity IDE/code.lock"
case "$WIN_ROOT$WIN_HOME" in *product.json*) exit 0 ;; esac   # lib path changed shape

WORK="$(mktemp -d)" || exit 0
TMPS=()                                                    # Windows-side temp files to remove on exit
trap 'rm -rf "$WORK"; [ "${#TMPS[@]}" -gt 0 ] && rm -f "${TMPS[@]}" 2>/dev/null' EXIT
if [ "$DRY" = 1 ]; then
    RUN="$WORK"
else
    RUN="${RUNTIME_DIRECTORY:-/tmp/antigravity-client-patch.$(id -u)}"
    mkdir -p "$RUN" || exit 0
fi

log()  { if [ "$DRY" = 1 ]; then echo "$2"; else echo "<$1>$2"; fi; }
note() { log 5 "$*"; }
warn() { log 4 "$*"; }
say()  { [ "$DRY" = 1 ] && echo "$*"; return 0; }          # detail, dry-run only
once() {                                                   # once <id> note|warn <text>: once per boot
    if [ "$DRY" = 0 ]; then
        local f
        f="$RUN/said-$(printf '%s' "$1" | sha256sum | cut -c1-16)"
        [ -e "$f" ] && return 0
        : > "$f"
    fi
    "$2" "$3"
}
remember() { [ "$DRY" = 1 ] || echo "$2" >> "$RUN/$1"; }
known()    { [ "$DRY" = 0 ] && grep -qxF -- "$2" "$RUN/$1" 2>/dev/null; }

b64sha()      { sha256sum "$1" | cut -d' ' -f1 | xxd -r -p | base64 | tr -d '='; }
count()       { grep -o -F -- "$2" "$1" | wc -l; }
jfield()      { tr -d '\r\n' < "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'; }
fingerprint() { stat -c '%s %Y' "$1" 2>/dev/null; }
json_ok()     { ! command -v jq >/dev/null 2>&1 || jq -e . "$1" >/dev/null 2>&1; }

# The IDE's main process holds code.lock from start to clean exit. A connected
# window also shows up as a remote extension host, which covers a missing lock.
app_running() {
    case "${AG_CLIENT_PATCH_TEST_APP_RUNNING:-}" in 0) return 1 ;; 1) return 0 ;; esac
    [ -e "$APP_LOCK" ] || pgrep -u "$(id -u)" -f -- '--type=extensionHost' >/dev/null
}
gate_open() {
    if [ "$1" = staged ]; then
        # Only the lock file counts here: it is the positive sign that the
        # installer is still waiting and has not started moving files.
        case "${AG_CLIENT_PATCH_TEST_APP_RUNNING:-}" in 0) return 1 ;; 1) return 0 ;; esac
        [ -e "$APP_LOCK" ]
    else
        [ ! -d "$WIN_ROOT/_" ] && ! app_running
    fi
}

handle() {
    local label="$1" app="$2"
    local pj="$app/product.json" bundle="$app/$BUNDLE_REL"
    local k ver fp key h nu np hn action pjc newpj tmpb="" tmpj=""

    if [ "$label" = installed ] && [ -d "$WIN_ROOT/_" ]; then
        say "installed: an update is staged; the installed copy is about to be replaced, leaving it alone"
        return 0
    fi
    if ! { [ -r "$pj" ] && [ -r "$bundle" ]; }; then
        say "$label: not present"
        return 0
    fi
    k="$(jfield "$pj" "$CHECKSUM_KEY")"
    ver="$(jfield "$pj" ideVersion) ($(jfield "$pj" commit | cut -c1-10))"
    if [ -z "$k" ]; then
        once "nochecksum $label $ver" warn "$label $ver: product.json has no checksum for the workbench bundle; leaving it alone"
        return 0
    fi
    fp="$(fingerprint "$bundle")"
    key="$label $k $fp"
    known done "$key" && return 0
    if known deferred "$key" && ! gate_open "$label"; then
        return 0
    fi

    # --- heavy path: one read of the bundle, everything else on the local copy
    if ! cp -- "$bundle" "$WORK/orig.js" 2>/dev/null; then
        say "$label $ver: could not read the bundle; retrying next run"
        return 0
    fi
    if [ "$(fingerprint "$bundle")" != "$fp" ] || [ "$(jfield "$pj" "$CHECKSUM_KEY")" != "$k" ]; then
        say "$label $ver: files changed while reading; retrying next run"
        return 0
    fi
    h="$(b64sha "$WORK/orig.js")"
    nu="$(count "$WORK/orig.js" "$OLD_TOKEN")"
    np="$(count "$WORK/orig.js" "$NEW_TOKEN")"

    if [ "$h" = "$k" ] && [ "$nu" = 0 ] && [ "$np" = 1 ]; then
        say "$label $ver: already patched, checksum consistent"
        remember done "$key"
        return 0
    elif [ "$h" = "$k" ] && [ "$nu" = 1 ] && [ "$np" = 0 ]; then
        action=patch
        if ! grep -q -E -- "$BUG_RE" "$WORK/orig.js"; then
            once "fixed $label $k" note "$label $ver: the wall-clock grace check was not found; upstream's fix (microsoft/vscode#338062) may have landed and this patch step may no longer be needed"
        fi
    elif [ "$h" != "$k" ] && [ "$nu" = 0 ] && [ "$np" = 1 ]; then
        action=checksum        # an earlier run replaced the bundle but not product.json
    elif [ "$h" = "$k" ]; then
        once "notapplicable $label $k" note "$label $ver: patch NOT applicable (found $nu unpatched / $np patched tokens); the Source Control hibernate fix is not active for this version"
        remember done "$key"
        return 0
    else
        say "$label $ver: bundle does not match its checksum (still being written, or changed by something else); leaving it alone"
        remember done "$key"
        return 0
    fi

    if ! gate_open "$label"; then
        if [ "$label" = staged ]; then
            say "$label $ver: needs '$action' but the IDE is not running (the installer may be moving files); leaving it alone"
        else
            say "$label $ver: needs '$action' but the IDE is running; deferred until it is closed"
            if [ "$DRY" = 0 ] && ! known deferred "$key"; then
                note "$label $ver: not patched yet; will patch once the IDE is closed"
            fi
        fi
        known deferred "$key" || remember deferred "$key"
        return 0
    fi
    if [ "$DRY" = 1 ]; then
        echo "$label $ver: WOULD apply '$action'"
        return 0
    fi

    rm -f "$bundle".agpatch.* "$pj".agpatch.* 2>/dev/null   # leftovers of a killed run
    tmpb="$bundle.agpatch.$$"
    tmpj="$pj.agpatch.$$"
    TMPS+=("$tmpb" "$tmpj")

    if [ "$action" = patch ]; then
        sed "s/$OLD_RE/$NEW_TOKEN/" "$WORK/orig.js" > "$WORK/new.js"
        if [ "$(count "$WORK/new.js" "$OLD_TOKEN")" != 0 ] || [ "$(count "$WORK/new.js" "$NEW_TOKEN")" != 1 ] \
           || [ "$(sed "s/$NEW_RE/$OLD_TOKEN/" "$WORK/new.js" | sha256sum)" != "$(sha256sum < "$WORK/orig.js")" ]; then
            warn "$label $ver: patched bundle failed verification; nothing changed"
            return 0
        fi
        hn="$(b64sha "$WORK/new.js")"
        if ! cp -- "$WORK/new.js" "$tmpb" 2>/dev/null || [ "$(b64sha "$tmpb")" != "$hn" ]; then
            warn "$label $ver: could not write the patched bundle next to the original; nothing changed"
            rm -f "$tmpb"
            return 0
        fi
    else
        hn="$h"
    fi

    # product.json: swap exactly the one checksum string, byte for byte otherwise.
    pjc="$(cat -- "$pj"; printf x)"
    pjc="${pjc%x}"
    if [ "$(printf '%s' "$pjc" | grep -o -F -- "\"$k\"" | wc -l)" != 1 ]; then
        warn "$label $ver: checksum string is not unique in product.json; nothing changed"
        rm -f "$tmpb"
        return 0
    fi
    newpj="${pjc/"\"$k\""/"\"$hn\""}"
    printf '%s' "$newpj" > "$tmpj" 2>/dev/null
    if [ "$(jfield "$tmpj" "$CHECKSUM_KEY")" != "$hn" ] || [ "$(stat -c %s "$tmpj")" != "$(stat -c %s "$pj")" ] || ! json_ok "$tmpj"; then
        warn "$label $ver: rewritten product.json failed verification; nothing changed"
        rm -f "$tmpb" "$tmpj"
        return 0
    fi

    # Last look before the swap, then two renames (bundle first).
    if [ "$(fingerprint "$bundle")" != "$fp" ] || [ "$(jfield "$pj" "$CHECKSUM_KEY")" != "$k" ] || ! gate_open "$label"; then
        rm -f "$tmpb" "$tmpj"
        return 0
    fi
    if [ "$action" = patch ] && ! mv -f --no-copy -- "$tmpb" "$bundle" 2>/dev/null; then
        warn "$label $ver: could not replace the bundle; nothing changed, retrying next run"
        rm -f "$tmpb" "$tmpj"
        return 0
    fi
    if ! mv -f --no-copy -- "$tmpj" "$pj" 2>/dev/null; then
        warn "$label $ver: bundle patched but product.json not updated yet; completing on the next run"
        rm -f "$tmpj"
        return 0
    fi
    remember done "$label $hn $(fingerprint "$bundle")"
    if [ "$action" = patch ]; then
        note "$label $ver: client reconnection grace patched 3 h -> 7 d; checksum $k -> $hn"
    else
        note "$label $ver: completed an interrupted patch; checksum $k -> $hn"
    fi
}

[ -d /mnt/c/Windows ] || exit 0                    # Windows drive not mounted (yet)
if [ ! -r "$WIN_ROOT/resources/app/product.json" ]; then
    once noinstall warn "Antigravity install not found at $WIN_ROOT: the client patch cannot be applied"
    exit 0
fi
if [ "$DRY" = 0 ]; then
    exec 9>"$RUN/lock"
    flock -n 9 || exit 0
fi
handle staged "$WIN_ROOT/_/resources/app"
handle installed "$WIN_ROOT/resources/app"
exit 0

#!/bin/bash
# Exercises antigravity-client-patch.sh against a FIXTURE copy of the two app
# trees in a throwaway folder under the Windows Temp dir (it must be on /mnt/c
# so renames go through the same drvfs path as the real thing). Reads the real
# install, never writes to it. Takes about a minute.
# Run as the service user, e.g. from root:
#   systemd-run --wait --pipe --collect -p User=YOUR_LINUX_USER /bin/bash \
#     /usr/local/share/antigravity-harness/antigravity-client-patch-test.sh \
#     /usr/local/bin/antigravity-client-patch.sh
# Expect "FAILS=0" on the last line.
set -u
export LC_ALL=C
SCRIPT="${1:-/usr/local/bin/antigravity-client-patch.sh}"
SP="${AG_TEST_SCRATCH:-/mnt/c/Users/YOUR_WINDOWS_USER/AppData/Local/Temp}/antigravity-client-patch-test.$$"
REAL="/mnt/c/Users/YOUR_WINDOWS_USER/AppData/Local/Programs/Antigravity IDE"
FX="$SP/agfix/Antigravity IDE"
B=out/vs/workbench/workbench.desktop.main.js
PR=/tmp/agtest-pristine.$$
RUNT=/tmp/agtest-run.$$
OLD='this._reconnectionGraceTime=108e5'
NEW='this._reconnectionGraceTime=6048e5'
FAILS=0

b64sha() { sha256sum "$1" | cut -d' ' -f1 | xxd -r -p | base64 | tr -d '='; }
chk()    { tr -d '\r\n' < "$1/product.json" | grep -o '"vs/workbench/workbench.desktop.main.js"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/'; }
state()  { printf '%s/%s %s' "$(grep -o -F -- "$OLD" "$1/$B" | wc -l)" "$(grep -o -F -- "$NEW" "$1/$B" | wc -l)" "$([ "$(b64sha "$1/$B")" = "$(chk "$1")" ] && echo consistent || echo MISMATCH)"; }
expect() { if [ "$2" = "$3" ]; then echo "PASS $1: $2"; else echo "FAIL $1: got [$2] want [$3]"; FAILS=$((FAILS+1)); fi; }
run()    { AG_CLIENT_PATCH_TEST_ROOT="$FX" AG_CLIENT_PATCH_TEST_APP_RUNNING="$1" RUNTIME_DIRECTORY="$RUNT" bash "$SCRIPT" ${2:-} 2>&1 | sed 's/^/      | /'; }
reset()  {
    rm -rf "$SP/agfix" "$RUNT"
    mkdir -p "$FX/_/resources/app/out/vs/workbench" "$FX/resources/app/out/vs/workbench" "$RUNT"
    cp "$PR/s.json" "$FX/_/resources/app/product.json"; cp "$PR/s.js" "$FX/_/resources/app/$B"
    cp "$PR/i.json" "$FX/resources/app/product.json";   cp "$PR/i.js" "$FX/resources/app/$B"
}
S="$FX/_/resources/app"; I="$FX/resources/app"

mkdir -p "$PR"
cp "$REAL/_/resources/app/product.json" "$PR/s.json"; cp "$REAL/_/resources/app/$B" "$PR/s.js"
cp "$REAL/resources/app/product.json" "$PR/i.json";   cp "$REAL/resources/app/$B" "$PR/i.js"
# If the real staged copy is already patched, rebuild an unpatched sample from it
# (token swapped back, checksum recomputed) so every scenario starts unpatched.
if [ "$(grep -o -F -- "$NEW" "$PR/s.js" | wc -l)" = 1 ]; then
    sed 's/this\._reconnectionGraceTime=6048e5/this._reconnectionGraceTime=108e5/' "$PR/s.js" > "$PR/s.js.r" && mv "$PR/s.js.r" "$PR/s.js"
    kcur="$(tr -d '\r\n' < "$PR/s.json" | grep -o '"vs/workbench/workbench.desktop.main.js"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
    korig="$(b64sha "$PR/s.js")"
    c="$(cat "$PR/s.json")"; printf '%s' "${c/"$kcur"/"$korig"}" > "$PR/s.json"
    echo "note: real staged copy is already patched; unpatched sample rebuilt, checksum $korig"
fi
echo "mv --no-copy supported: $(mv --help 2>&1 | grep -c -- '--no-copy')"
t0=$(date +%s)

echo "== T1 dry-run, IDE running: reports, changes nothing"
reset; run 1 --dry-run
expect T1.staged "$(state "$S")" "1/0 consistent"; expect T1.installed "$(state "$I")" "1/0 consistent"

echo "== T2 real run, IDE running: staged patched, installed left alone"
run 1
expect T2.staged "$(state "$S")" "0/1 consistent"; expect T2.installed "$(state "$I")" "1/0 consistent"
expect T2.size "$(( $(stat -c %s "$S/$B") - $(stat -c %s "$PR/s.js") ))" "1"
expect T2.reversible "$(sed 's/this\._reconnectionGraceTime=6048e5/this._reconnectionGraceTime=108e5/' "$S/$B" | sha256sum)" "$(sha256sum < "$PR/s.js")"
expect T2.json-size "$(stat -c %s "$S/product.json")" "$(stat -c %s "$PR/s.json")"
expect T2.json-diff-bytes-le-43 "$([ "$(cmp -l "$S/product.json" "$PR/s.json" | wc -l)" -le 43 ] && echo ok || echo too-many)" "ok"
expect T2.json-valid "$(jq -r .ideVersion "$S/product.json" 2>&1)" "$(jq -r .ideVersion "$PR/s.json")"
expect T2.json-other-keys "$(jq -S 'del(.checksums["vs/workbench/workbench.desktop.main.js"])' "$S/product.json" | sha256sum)" "$(jq -S 'del(.checksums["vs/workbench/workbench.desktop.main.js"])' "$PR/s.json" | sha256sum)"

echo "== T3 second run: silent no-op from cache"
m1="$(stat -c %Y "$S/$B") $(stat -c %Y "$S/product.json")"; out="$(run 1)"; m2="$(stat -c %Y "$S/$B") $(stat -c %Y "$S/product.json")"
expect T3.unchanged "$m2" "$m1"; expect T3.silent "[$out]" "[]"

echo "== T4 cache lost (reboot): recognises the patched copy, changes nothing"
rm -f "$RUNT/done"; out="$(run 1)"; m3="$(stat -c %Y "$S/$B") $(stat -c %Y "$S/product.json")"
expect T4.unchanged "$m3" "$m1"; expect T4.silent "[$out]" "[]"; expect T4.state "$(state "$S")" "0/1 consistent"

echo "== T5 interrupted run (bundle patched, checksum stale): completed"
cp "$PR/s.json" "$S/product.json"; rm -f "$RUNT/done"
expect T5.before "$(state "$S")" "0/1 MISMATCH"; run 1; expect T5.after "$(state "$S")" "0/1 consistent"

echo "== T6 token absent but file consistent (a future version): untouched, notice"
reset; sed 's/this\._reconnectionGraceTime=108e5/this._reconnectionGraceTime=999e5/' "$PR/s.js" > "$S/$B"
kold="$(chk "$S")"; knew="$(b64sha "$S/$B")"; c="$(cat "$S/product.json")"; printf '%s' "${c/"$kold"/"$knew"}" > "$S/product.json"
h1="$(b64sha "$S/$B") $(sha256sum < "$S/product.json")"; run 1; h2="$(b64sha "$S/$B") $(sha256sum < "$S/product.json")"
expect T6.unchanged "$h2" "$h1"

echo "== T7 truncated bundle (still being written): untouched"
reset; head -c 5000000 "$PR/s.js" > "$S/$B"
h1="$(b64sha "$S/$B") $(sha256sum < "$S/product.json")"; run 1; h2="$(b64sha "$S/$B") $(sha256sum < "$S/product.json")"
expect T7.unchanged "$h2" "$h1"

echo "== T8 no staged update: installed deferred while IDE runs, patched when closed"
reset; rm -rf "$FX/_"
run 1; expect T8.running "$(state "$I")" "1/0 consistent"
out="$(run 1)"; expect T8.deferred-silent "[$out]" "[]"
run 0; expect T8.closed "$(state "$I")" "0/1 consistent"

echo "== T9 staged present, IDE not running (installer may be moving files): nothing touched"
reset; run 0
expect T9.staged "$(state "$S")" "1/0 consistent"; expect T9.installed "$(state "$I")" "1/0 consistent"

echo "== T10 no leftovers"
expect T10.fixture-files "$(find "$SP/agfix" -type f | wc -l)" "4"
expect T10.no-temp-files "$(find "$SP/agfix" -name '*.agpatch.*' | wc -l)" "0"

echo "== T11 leftover temp files of a killed run are swept on the next patch"
reset; : > "$S/$B.agpatch.999"; : > "$S/product.json.agpatch.999"; run 1
expect T11.staged "$(state "$S")" "0/1 consistent"; expect T11.swept "$(find "$SP/agfix" -name '*.agpatch.*' | wc -l)" "0"

rm -rf "$SP" "$PR" "$RUNT"
echo "elapsed: $(( $(date +%s) - t0 )) s   FAILS=$FAILS"

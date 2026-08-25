#!/bin/bash
# Loads every core and reports where the package temperature settles, so you can
# pick T_HOT and T_PANIC from measurements rather than intuition.
#
# Works with or without the daemon running: the "zone" column is derived from
# the hwmon state, so you can compare the stock BIOS curve against the daemon by
# running this once with the service stopped and once with it running.
#
# Uses stress-ng when available, otherwise falls back to openssl. It aborts the
# load by itself at ABORT_AT so a live T_PANIC brake cannot reboot the machine
# mid-test.
#
# Usage: sudo ./thermal-test.sh [load_seconds]
set -u

LOAD_SEC=${1:-300}
COOL_SEC=${COOL_SEC:-90}
ABORT_AT=${ABORT_AT:-93}
ABORT_HITS=${ABORT_HITS:-2}
STEP=${STEP:-3}
N=$(nproc)

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

MT_NO_DELL="dell_smm hwmon not found"
MT_NO_CORETEMP="coretemp hwmon not found"
MT_NO_PKG="'Package id 0' sensor not found"
MT_LOAD_STRESS="Load: stress-ng --cpu %s --cpu-method matrixprod\n"
MT_LOAD_OPENSSL="Load: openssl aes-256-gcm x %s (stress-ng not installed)\n"
MT_NO_LOADER="Neither stress-ng nor openssl is available — nothing to load with."
MT_PLAN="%ss load, then %ss cooldown. Aborting the load at %sC.\n"
MT_HDR_SEC="sec"
MT_HDR_TEMP="temp"
MT_HDR_PEAK="peak"
MT_HDR_RPM="RPM"
MT_HDR_ZONE="zone"
MT_LOAD_DONE="--- load finished ---"
MT_ABORTED="--- reached %sC: load aborted early ---\n"
MT_SUMMARY="== SUMMARY =="
MT_PEAK="Package peak:       %sC\n"
MT_FIRST_MAX="First MAX at:       %s\n"
MT_NEVER="never engaged"
MT_TOTAL_MAX="Total time in MAX:  %ss\n"
MT_TOGGLES="Zone transitions:   %s\n"
MT_NOTE_ABORT="NOTE: stopped early at %sC — the real ceiling is higher than %sC.\n"
[ -r "$SRC_DIR/lang/load.sh" ] && . "$SRC_DIR/lang/load.sh"

find_hwmon() {
    local target="$1" dir
    for dir in /sys/class/hwmon/hwmon*; do
        [ -r "$dir/name" ] || continue
        [ "$(cat "$dir/name")" = "$target" ] && { echo "$dir"; return 0; }
    done
    return 1
}

DELL_DIR=$(find_hwmon dell_smm) || { echo "$MT_NO_DELL" >&2; exit 1; }
CORETEMP_DIR=$(find_hwmon coretemp) || { echo "$MT_NO_CORETEMP" >&2; exit 1; }
TEMP_INPUT=$(for f in "$CORETEMP_DIR"/temp*_label; do
    [ "$(cat "$f" 2>/dev/null)" = "Package id 0" ] && echo "${f%_label}_input"
done)
[ -n "$TEMP_INPUT" ] || { echo "$MT_NO_PKG" >&2; exit 1; }

pids=()
cleanup() {
    [ ${#pids[@]} -gt 0 ] && kill "${pids[@]}" 2>/dev/null
    pkill -x stress-ng 2>/dev/null
    pkill -x openssl 2>/dev/null
    pids=()
}
trap cleanup EXIT TERM INT

start_load() {
    if command -v stress-ng >/dev/null 2>&1; then
        printf "$MT_LOAD_STRESS" "$N"
        stress-ng --cpu "$N" --cpu-method matrixprod --timeout "${LOAD_SEC}s" >/dev/null 2>&1 &
        pids+=($!)
    elif command -v openssl >/dev/null 2>&1; then
        printf "$MT_LOAD_OPENSSL" "$N"
        local i
        for i in $(seq "$N"); do
            while :; do openssl speed -evp aes-256-gcm -seconds 3 >/dev/null 2>&1; done &
            pids+=($!)
        done
    else
        echo "$MT_NO_LOADER" >&2
        exit 1
    fi
}

zone_now() {
    local en pw
    en=$(cat "$DELL_DIR/pwm1_enable" 2>/dev/null)
    pw=$(cat "$DELL_DIR/pwm1" 2>/dev/null)
    if   [ "$en" = 2 ];   then echo BIOS
    elif [ "$pw" = 255 ]; then echo MAX
    else                       echo quiet
    fi
}

printf "$MT_PLAN" "$LOAD_SEC" "$COOL_SEC" "$ABORT_AT"
echo
start_load
printf '%6s %6s %6s %8s  %s\n' "$MT_HDR_SEC" "$MT_HDR_TEMP" "$MT_HDR_PEAK" "$MT_HDR_RPM" "$MT_HDR_ZONE"

max=0; hits=0; stopped=0; aborted=0; start=$SECONDS
prev=""; toggles=0; first_max=""; max_secs=0
while (( SECONDS - start < LOAD_SEC + COOL_SEC )); do
    el=$(( SECONDS - start ))
    if (( el >= LOAD_SEC && stopped == 0 )); then
        stopped=1; cleanup; echo "$MT_LOAD_DONE"
    fi

    t=$(( $(cat "$TEMP_INPUT") / 1000 ))
    (( t > max )) && max=$t
    z=$(zone_now)

    [ -n "$prev" ] && [ "$z" != "$prev" ] && toggles=$(( toggles + 1 ))
    if [ "$z" = MAX ]; then
        [ -z "$first_max" ] && first_max=$el
        max_secs=$(( max_secs + STEP ))
    fi
    prev=$z

    printf '%6s %5sC %5sC %8s  %s\n' \
        "$el" "$t" "$max" "$(cat "$DELL_DIR/fan1_input" 2>/dev/null)" "$z"

    if (( stopped == 0 && t >= ABORT_AT )); then
        hits=$(( hits + 1 ))
        if (( hits >= ABORT_HITS )); then
            stopped=1; aborted=1; cleanup
            printf "$MT_ABORTED" "$ABORT_AT"
        fi
    else
        hits=0
    fi
    sleep "$STEP"
done

echo
echo "$MT_SUMMARY"
printf "$MT_PEAK" "$max"
printf "$MT_FIRST_MAX" "${first_max:-$MT_NEVER}${first_max:+s}"
printf "$MT_TOTAL_MAX" "$max_secs"
printf "$MT_TOGGLES" "$toggles"
if (( aborted == 1 )); then
    printf "$MT_NOTE_ABORT" "$ABORT_AT" "$max"
fi
exit 0

#!/bin/bash
# Maps pwm1 values to actual EC fan levels: sweeps the range in steps of 25,
# then probes what the driver does with out-of-range writes and with
# pwm1_enable values other than 1 and 2.
#
# Run this first on any model other than the 7080 Micro — the level boundaries
# in README.md were measured, not derived, and yours may differ.
#
# Stops the daemon for the duration and restores everything on any exit,
# including Ctrl+C.
#
# Usage: sudo ./pwm-sweep.sh
set -u
SETTLE=${SETTLE:-12}

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

MS_NEED_ROOT="Run with sudo: sudo ./pwm-sweep.sh"
MS_NO_DELL="dell_smm not found"
MS_RESTORING="== restoring =="
MS_STARTED="   optiplex-fan started again"
MS_WAS_STOPPED="   service was already stopped, leaving it that way"
MS_STOPPING="Stopping optiplex-fan for the duration..."
MS_MANUAL="Manual mode, %ss settling time per value.\n"
MS_HDR_WRITTEN="written"
MS_HDR_READBACK="readback"
MS_HDR_RPM="RPM"
MS_HDR_TEMP="temp"
MS_HDR_LEVEL="EC level"
MS_REFUSED="REFUSED"
MS_JUMP="  <-- JUMP"
MS_OUT_OF_RANGE="== out-of-range writes =="
MS_ACCEPTED="  wrote %-6s -> ACCEPTED (rc=0), readback=%s, RPM=%s\n"
MS_REJECTED="  wrote %-6s -> rejected: %s\n"
MS_ENABLE_HDR="== pwm1_enable: any modes besides 1 and 2? =="
MS_EN_ACCEPTED="  enable=%-2s -> ACCEPTED, readback=%s, RPM=%s\n"
MS_EN_REJECTED="  enable=%-2s -> rejected: %s\n"
MS_REFERENCE="== for reference =="
MS_FAN_MAX="  fan1_max attribute: %s\n"
MS_FAN_MIN="  fan1_min attribute: %s\n"
[ -r "$SRC_DIR/lang/load.sh" ] && . "$SRC_DIR/lang/load.sh"

if [ "$EUID" -ne 0 ]; then
    echo "$MS_NEED_ROOT" >&2
    exit 1
fi

D=$(for d in /sys/class/hwmon/hwmon*; do [ "$(cat $d/name 2>/dev/null)" = dell_smm ] && echo $d; done)
C=$(for d in /sys/class/hwmon/hwmon*; do [ "$(cat $d/name 2>/dev/null)" = coretemp ] && echo $d; done)
[ -n "$D" ] || { echo "$MS_NO_DELL" >&2; exit 1; }
TI=$(for f in $C/temp*_label; do [ "$(cat $f)" = "Package id 0" ] && echo "${f%_label}_input"; done)
PWM=$D/pwm1; EN=$D/pwm1_enable

WAS_ACTIVE=0
systemctl is-active --quiet optiplex-fan.service && WAS_ACTIVE=1

restore() {
    echo
    echo "$MS_RESTORING"
    echo 2 > "$EN" 2>/dev/null
    if [ "$WAS_ACTIVE" = 1 ]; then
        systemctl start optiplex-fan.service && echo "$MS_STARTED"
    else
        echo "$MS_WAS_STOPPED"
    fi
}
trap restore EXIT TERM INT

if [ "$WAS_ACTIVE" = 1 ]; then
    echo "$MS_STOPPING"
    systemctl stop optiplex-fan.service
    sleep 3
fi

printf "$MS_MANUAL" "$SETTLE"
echo 1 > "$EN"
sleep "$SETTLE"
echo
printf '%8s %10s %8s %7s  %s\n' "$MS_HDR_WRITTEN" "$MS_HDR_READBACK" "$MS_HDR_RPM" "$MS_HDR_TEMP" "$MS_HDR_LEVEL"

prev_rpm=""
for v in 0 25 50 75 100 125 150 175 200 225 250 255; do
    if ! echo "$v" > "$PWM" 2>/dev/null; then
        printf '%8s %10s\n' "$v" "$MS_REFUSED"
        continue
    fi
    sleep "$SETTLE"
    rb=$(cat "$PWM" 2>/dev/null || echo "n/a")
    rpm=$(cat "$D/fan1_input")
    t=$(( $(cat "$TI") / 1000 ))
    case "$rb" in 0) lvl=0 ;; 128) lvl=1 ;; 255) lvl=2 ;; *) lvl="?" ;; esac
    mark=""
    [ -n "$prev_rpm" ] && (( rpm > prev_rpm + 200 || rpm < prev_rpm - 200 )) && mark="$MS_JUMP"
    printf '%8s %10s %8s %6sC  %s%s\n' "$v" "$rb" "$rpm" "$t" "$lvl" "$mark"
    prev_rpm=$rpm
done

echo
echo "$MS_OUT_OF_RANGE"
for v in 256 300 1000 -1 -100; do
    err=$( { echo "$v" > "$PWM"; } 2>&1 )
    rc=$?
    sleep 2
    rb=$(cat "$PWM" 2>/dev/null || echo "n/a")
    if [ $rc -eq 0 ]; then
        printf "$MS_ACCEPTED" "$v" "$rb" "$(cat $D/fan1_input)"
    else
        printf "$MS_REJECTED" "$v" "$(echo "$err" | tail -1 | sed 's/.*: //')"
    fi
done

echo
echo "$MS_ENABLE_HDR"
for v in 0 3; do
    err=$( { echo "$v" > "$EN"; } 2>&1 )
    rc=$?
    if [ $rc -eq 0 ]; then
        sleep 5
        printf "$MS_EN_ACCEPTED" "$v" "$(cat $EN)" "$(cat $D/fan1_input)"
        echo 1 > "$EN"; sleep 3
    else
        printf "$MS_EN_REJECTED" "$v" "$(echo "$err" | tail -1 | sed 's/.*: //')"
    fi
done

echo
echo "$MS_REFERENCE"
printf "$MS_FAN_MAX" "$(cat $D/fan1_max 2>/dev/null)"
printf "$MS_FAN_MIN" "$(cat $D/fan1_min 2>/dev/null)"

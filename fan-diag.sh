#!/bin/bash
# Fan diagnostics for Dell OptiPlex (dell_smm_hwmon): shows what the fan
# actually responds to — the pwm1_enable switch (manual / BIOS auto) or the
# value written to pwm1.
#
# Installs nothing and changes nothing permanently. On exit — including on
# Ctrl+C — it always restores pwm1_enable=2 (BIOS auto).
#
# Usage: sudo ./fan-diag.sh
set -u

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

MD_NEED_ROOT="Run with sudo: sudo ./fan-diag.sh"
MD_NO_DELL="dell_smm hwmon not found — is dell_smm_hwmon loaded?"
MD_NO_CORETEMP="coretemp hwmon not found"
MD_NO_PKG="'Package id 0' sensor not found"
MD_RESTORED="== restored pwm1_enable=2 (BIOS auto) =="
MD_TEMP_SRC="Temp source: %s\n"
MD_PWM_CTL="PWM control: %s (enable: %s)\n"
MD_BIOS_TOKEN="== BIOS token =="
MD_NO_CCTK="cctk not installed"
MD_STEP1="== 1) as found (pwm1_enable=%s) ==\n"
MD_STEP2="== 2) pwm1_enable=1 (manual, EC control off) =="
MD_STEP3="== 3) pwm1=%s ==\n"
MD_STEP4="== 4) back to pwm1_enable=2 =="
[ -r "$SRC_DIR/lang/load.sh" ] && . "$SRC_DIR/lang/load.sh"

if [ "$EUID" -ne 0 ]; then
    echo "$MD_NEED_ROOT" >&2
    exit 1
fi

CCTK=/opt/dell/dcc/cctk

find_hwmon() {
    local target="$1" dir
    for dir in /sys/class/hwmon/hwmon*; do
        [ -r "$dir/name" ] || continue
        [ "$(cat "$dir/name")" = "$target" ] && { echo "$dir"; return 0; }
    done
    return 1
}

find_temp_input() {
    local dir="$1" label="$2" f
    for f in "$dir"/temp*_label; do
        [ -r "$f" ] || continue
        [ "$(cat "$f")" = "$label" ] && { echo "${f%_label}_input"; return 0; }
    done
    return 1
}

DELL_DIR=$(find_hwmon dell_smm) || { echo "$MD_NO_DELL" >&2; exit 1; }
CORETEMP_DIR=$(find_hwmon coretemp) || { echo "$MD_NO_CORETEMP" >&2; exit 1; }
TEMP_INPUT=$(find_temp_input "$CORETEMP_DIR" "Package id 0") || { echo "$MD_NO_PKG" >&2; exit 1; }
PWM="$DELL_DIR/pwm1"
PWM_ENABLE="$DELL_DIR/pwm1_enable"

restore() {
    echo 2 > "$PWM_ENABLE" 2>/dev/null
    echo
    echo "$MD_RESTORED"
}
trap restore EXIT TERM INT

pkg()    { echo $(( $(cat "$TEMP_INPUT") / 1000 )); }
sample() {
    local i
    for i in 1 2 3 4 5; do
        printf "   t=%sC rpm=%s pwm=%s\n" \
            "$(pkg)" "$(cat "$DELL_DIR/fan1_input")" "$(cat "$PWM" 2>&1 | tail -c 20)"
        sleep 2
    done
}

printf "$MD_TEMP_SRC" "$TEMP_INPUT"
printf "$MD_PWM_CTL" "$PWM" "$PWM_ENABLE"
echo

echo "$MD_BIOS_TOKEN"
if [ -x "$CCTK" ]; then "$CCTK" --FanCtrlOvrd 2>&1 | tail -2; else echo "$MD_NO_CCTK"; fi

printf "$MD_STEP1" "$(cat "$PWM_ENABLE")"
sample

echo "$MD_STEP2"
echo 1 > "$PWM_ENABLE"; sleep 3; sample

for v in 0 128 255; do
    printf "$MD_STEP3" "$v"
    echo "$v" > "$PWM" 2>&1; sleep 4; sample
done

echo "$MD_STEP4"
echo 2 > "$PWM_ENABLE"; sleep 5; sample

#!/bin/bash
# Three-zone fan control for Dell OptiPlex Micro (dell_smm_hwmon).
#
# The EC exposes three fan levels through the SMM interface, and levels 0 and 1
# behave identically on this box, so there are two usable manual states plus
# whatever the BIOS does on its own:
#
#   manual, pwm 0..175   -> ~1130 RPM  quieter than the BIOS's own idle
#   pwm1_enable=2        -> BIOS auto  ~1800 RPM idle, own curve above that
#   manual, pwm 192..255 -> ~3250 RPM  written once and left alone
#   the same, rewritten  -> ~4600 RPM  every write to pwm1 kicks the fan into a
#                                      short burst, so rewriting it every couple
#                                      of seconds holds a speed the level cannot
#                                      otherwise sustain
#
# That last one is measured, not folklore: writing 255 once spikes to ~4260 and
# settles to ~3250 within twelve seconds, rewriting every 2 s holds 4477-4773
# indefinitely, and stopping the rewrites drops back to ~3260 in twelve seconds
# — all of it at a steady 32-38C, so none of it is the EC reacting to heat.
#
# A smooth ramp is impossible; what this daemon does is pick the right one of
# those three for the current CPU temperature:
#
#   below T_QUIET-T_HYST   quiet    the BIOS idles louder than it needs to
#   T_QUIET .. T_BOOST     BIOS     stock curve handles the ordinary middle
#   T_BOOST .. T_PURGE     boost    ~3250 RPM, the top level left alone
#   T_PURGE and above      purge    ~4600 RPM, the top level kept in burst
#
# That top zone is not theoretical. Measured on this machine under a 12-thread
# load: with the fan lagging at ~1780 RPM the package settled at 91C, while the
# same load with the fan already at ~2570 RPM settled at 81C. The BIOS gives up
# ten degrees of headroom by ramping late, and pwm 255 takes them back.
#
# Each band drops out below the point it was entered so the fan does not flap on
# a boundary: T_HYST for the quiet band, T_HOT_HYST for the max band. The top one
# gets its own knob because it wants a tighter grip — once the fan is flat out it
# should stay there until the package has genuinely come back down, not merely
# dipped a degree.
#
# Failure modes all end in BIOS auto: the EXIT/TERM/INT/ABRT trap restores it
# and an unreadable temperature restores it, so a dead daemon never leaves the
# fan pinned. Above that sits the panic brake — see panic_sequence().
set -u

# CONF, PANIC_FLAG and HWMON_ROOT are overridable so the whole curve can be
# exercised against a fake sysfs tree. Never set them in production.
CONF=${CONF:-/etc/optiplex-fan.conf}
[ -f "$CONF" ] && source "$CONF"

T_QUIET=${T_QUIET:-65}
T_HYST=${T_HYST:-10}
# T_HOT was the old name for T_BOOST, back when boost and purge were one zone.
T_BOOST=${T_BOOST:-${T_HOT:-75}}
T_PURGE=${T_PURGE:-85}
T_HOT_HYST=${T_HOT_HYST:-5}
QUIET_PWM=${QUIET_PWM:-0}
INTERVAL=${INTERVAL:-2}
T_PANIC=${T_PANIC:-0}
# PANIC_COOL_TO / PANIC_COOL_TIMEOUT were the old names, from the version that
# cooled down and then watched to decide whether to reboot.
PANIC_RECOVER=${PANIC_RECOVER:-${PANIC_COOL_TO:-80}}
PANIC_TIMEOUT=${PANIC_TIMEOUT:-${PANIC_COOL_TIMEOUT:-120}}
PANIC_ACTION=${PANIC_ACTION:-poweroff}

PANIC_FLAG=${PANIC_FLAG:-/var/lib/optiplex-fan/panic}
ALARM_SH=${ALARM_SH:-/usr/local/sbin/optiplex-fan-alarm.sh}
HWMON_ROOT=${HWMON_ROOT:-/sys/class/hwmon}

# The watchdog is what saves us if this loop wedges while the fan is pinned to
# the quiet level, so the interval must stay well inside WatchdogSec (30).
(( INTERVAL < 1 ))  && INTERVAL=1
(( INTERVAL > 10 )) && INTERVAL=10
(( T_HYST < 1 ))     && T_HYST=1
(( T_HOT_HYST < 1 )) && T_HOT_HYST=1
# The driver maps pwm to an EC level with DIV_ROUND_CLOSEST(pwm * fan_max, 255),
# so with fan_max=2 level 2 starts at pwm 192 — not at 255. Anything at or above
# that is full speed, which is the opposite of quiet. 175 is the highest value
# measured to still land on the quiet level.
(( QUIET_PWM > 175 )) && QUIET_PWM=175
# Zones must stay ordered, or a band would be unreachable. T_BOOST=0 or
# T_PURGE=0 turns that zone off; T_PANIC=0 turns the brake off.
(( T_BOOST > 0 && T_BOOST <= T_QUIET )) && T_BOOST=$(( T_QUIET + 1 ))
(( T_PURGE > 0 && T_BOOST > 0 && T_PURGE <= T_BOOST )) && T_PURGE=$(( T_BOOST + 1 ))
(( T_PURGE > 0 && T_BOOST == 0 && T_PURGE <= T_QUIET )) && T_PURGE=$(( T_QUIET + 1 ))
(( T_PANIC > 0 && T_PANIC <= T_QUIET )) && T_PANIC=$(( T_QUIET + 1 ))
(( T_PANIC > 0 && T_PURGE > 0 && T_PANIC <= T_PURGE )) && T_PANIC=$(( T_PURGE + 1 ))
# Recovery has to be below the trigger, or the wait would be over before it
# began and every trip would end in a shutdown.
(( T_PANIC > 0 && PANIC_RECOVER >= T_PANIC )) && PANIC_RECOVER=$(( T_PANIC - 5 ))
(( PANIC_TIMEOUT < INTERVAL )) && PANIC_TIMEOUT=$INTERVAL
[ "$PANIC_ACTION" = reboot ] || PANIC_ACTION=poweroff
T_RESUME=$(( T_QUIET - T_HYST ))

find_hwmon() {
    local target="$1" dir
    for dir in "$HWMON_ROOT"/hwmon*; do
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

if [ -n "${NOTIFY_SOCKET:-}" ] && ! command -v systemd-notify >/dev/null 2>&1; then
    echo "Type=notify service but systemd-notify is missing" >&2
    exit 1
fi

DELL_DIR=$(find_hwmon dell_smm) || { echo "dell_smm hwmon not found — is dell_smm_hwmon loaded?" >&2; exit 1; }
CORETEMP_DIR=$(find_hwmon coretemp) || { echo "coretemp hwmon not found" >&2; exit 1; }
TEMP_INPUT=$(find_temp_input "$CORETEMP_DIR" "Package id 0") || { echo "'Package id 0' sensor not found" >&2; exit 1; }
PWM="$DELL_DIR/pwm1"
PWM_ENABLE="$DELL_DIR/pwm1_enable"

mode=""
manual=0
mode_rb=""      # what pwm1 reads back in the current manual mode

ping_watchdog() { command -v systemd-notify >/dev/null 2>&1 && systemd-notify WATCHDOG=1; }

# Entering manual control makes the EC blip to full speed, so the level is
# written in the same breath. Once manual, the enable file is left alone —
# rewriting it would re-trigger that blip on every boost/purge transition.
set_manual() {
    local want="$1"
    if (( manual == 0 )); then
        echo 1 > "$PWM_ENABLE" || return 1
        manual=1
    fi
    echo "$want" > "$PWM" 2>/dev/null
    mode_rb=$(cat "$PWM" 2>/dev/null)
    return 0
}

go_auto() {
    [ "$mode" = auto ] && return
    echo 2 > "$PWM_ENABLE" || return
    manual=0
    mode_rb=""
    mode=auto
    echo "-> BIOS auto"
}

go_quiet() {
    [ "$mode" = quiet ] && return
    set_manual "$QUIET_PWM" || return
    mode=quiet
    echo "-> quiet (pwm $QUIET_PWM)"
}

# Top EC level, written once and then left alone: ~3250 RPM.
go_boost() {
    [ "$mode" = boost ] && return
    set_manual 255 || return
    mode=boost
    echo "-> boost (pwm 255, left alone) — ~3250 RPM"
}

# Same level, but rewritten every cycle. Each write kicks the fan into a short
# burst, and back-to-back bursts hold ~4600 RPM, which the level cannot sustain
# on its own. Costs nothing but the write.
go_purge() {
    [ "$mode" = purge ] && return
    set_manual 255 || return
    mode=purge
    echo "-> PURGE (pwm 255, rewritten every ${INTERVAL}s) — ~4600 RPM"
}

restore_bios() {
    echo "Restoring BIOS automatic fan control..."
    echo 2 > "$PWM_ENABLE" 2>/dev/null
}

# A bare `trap restore_bios TERM` would run the handler and then resume the
# loop — bash does not exit on a trapped signal — so systemctl stop would hang
# until TimeoutStopSec and end in SIGKILL. Signals need their own handler that
# actually leaves; the EXIT trap then restores again, harmlessly.
on_signal() { restore_bios; exit 143; }
trap restore_bios EXIT
trap on_signal TERM INT ABRT

# bash defers traps until the running foreground command returns, so a plain
# `sleep` would swallow the signal for up to INTERVAL seconds. Backgrounding it
# and waiting makes stops immediate.
nap() { sleep "$1" & wait $!; }

# Which zone the current temperature belongs to, given where we already are.
# Highest zone wins; a band is only left once the temperature has fallen its
# own hysteresis below the point that entered it.
pick_zone() {
    local t="$1"
    if (( T_PURGE > 0 )); then
        (( t >= T_PURGE )) && { echo purge; return; }
        [ "$mode" = purge ] && (( t >= T_PURGE - T_HOT_HYST )) && { echo purge; return; }
    fi
    if (( T_BOOST > 0 )); then
        (( t >= T_BOOST )) && { echo boost; return; }
        [ "$mode" = boost ] && (( t >= T_BOOST - T_HOT_HYST )) && { echo boost; return; }
    fi
    (( t >= T_QUIET ))  && { echo auto; return; }
    (( t <= T_RESUME )) && { echo quiet; return; }
    # Inside the quiet/auto hysteresis band: hold, but never hold a top zone
    # here — those were already left above.
    [ "$mode" = quiet ] && { echo quiet; return; }
    echo auto
}

# Put the fan where the given temperature says it belongs, and hold it there.
apply_zone() {
    local t="$1"
    case "$(pick_zone "$t")" in
        quiet) go_quiet ;;
        auto)  go_auto  ;;
        boost) go_boost ;;
        purge) go_purge ;;
    esac

    case "$mode" in
        purge)
            # The whole point of this zone: every write restarts the burst.
            echo 255 > "$PWM" 2>/dev/null
            ;;
        quiet|boost)
            # Guard against the EC drifting off the level we asked for, but do
            # NOT write unconditionally — an unnecessary write here would kick
            # the fan into the burst we are deliberately not using.
            if [ "$(cat "$PWM" 2>/dev/null)" != "$mode_rb" ]; then
                echo "$([ "$mode" = quiet ] && echo "$QUIET_PWM" || echo 255)" > "$PWM" 2>/dev/null
                echo "re-asserted ${mode} level"
            fi
            ;;
    esac
}

# Panic brake, off by default (T_PANIC=0). One rule: reaching T_PANIC means the
# fan is already flat out and losing, so sound the alarm, hold purge, and give
# the machine PANIC_TIMEOUT seconds to get back down to PANIC_RECOVER. If it
# does, carry on. If it does not, the cooling has lost — long beep, and shut the
# box down.
#
# Powering off beats rebooting: a package that could not be cooled while running
# will not be cooled any better by coming straight back up into the same
# workload, and nothing controls the fan through POST at all. PANIC_ACTION=reboot
# is there for a machine that has to come back.
#
# The latch is a file, not `systemctl disable`. The unit stays enabled and still
# starts at the next boot — it just reads the flag and controls nothing, which
# is what makes it able to beep about its own state. See the startup check.
beep() {
    [ -x "$ALARM_SH" ] || return 0
    if [ "${2:-}" = once ]; then
        # On the way down: one pattern, then get on with it.
        "$ALARM_SH" --alert "$1" --once 2>/dev/null
    else
        # Never let the alarm hold up the fan: the purge zone needs its rewrite
        # every INTERVAL seconds, and a repeated pattern takes far longer.
        "$ALARM_SH" --alert "$1" >/dev/null 2>&1 &
    fi
}

panic_latch_and_stop() {
    local why="$1"
    echo "PANIC: $why — ${PANIC_ACTION}" >&2
    logger -p daemon.crit -t optiplex-fan "$why — ${PANIC_ACTION}" 2>/dev/null
    command -v wall >/dev/null 2>&1 && wall "optiplex-fan: $why — ${PANIC_ACTION}" 2>/dev/null

    # Latch first, so a machine that dies anywhere below still comes back with
    # the fan on the stock curve and beeping about it.
    mkdir -p "$(dirname "$PANIC_FLAG")" 2>/dev/null
    printf '%s\t%s\n' "$(date -Is)" "$why" >> "$PANIC_FLAG" 2>/dev/null

    # Hand the fan over before going down: if the shutdown stalls, the EC has to
    # be in charge, not a daemon that is about to disappear.
    echo 2 > "$PWM_ENABLE" 2>/dev/null
    mode=auto
    manual=0

    beep long once

    sync
    systemctl "$PANIC_ACTION" --force

    # Do not exit: Restart=always would drag this daemon back mid-shutdown.
    # Keep feeding the watchdog until the machine actually goes down.
    while true; do ping_watchdog; nap 5; done
}

# Returns 0 if the machine came back down on its own and normal operation
# resumes. Otherwise it never returns — panic_latch_and_stop takes over.
panic_sequence() {
    local t="$1" waited=0 tnow
    local msg="CPU ${t}C >= ${T_PANIC}C"

    echo "PANIC: $msg — purge, ${PANIC_TIMEOUT}s to get back to ${PANIC_RECOVER}C" >&2
    logger -p daemon.crit -t optiplex-fan "$msg — purge, ${PANIC_TIMEOUT}s to reach ${PANIC_RECOVER}C" 2>/dev/null
    beep short

    set_manual 255
    mode=purge
    while (( waited < PANIC_TIMEOUT )); do
        echo 255 > "$PWM" 2>/dev/null
        if tnow=$(cat "$TEMP_INPUT" 2>/dev/null) && [ -n "$tnow" ]; then
            tnow=$(( tnow / 1000 ))
            if (( tnow <= PANIC_RECOVER )); then
                echo "PANIC: recovered — ${tnow}C after ${waited}s, carrying on"
                logger -p daemon.notice -t optiplex-fan "recovered to ${tnow}C after ${waited}s of purge" 2>/dev/null
                return 0
            fi
            echo "PANIC: purging ${tnow}C -> ${PANIC_RECOVER}C (${waited}/${PANIC_TIMEOUT}s)"
        fi
        ping_watchdog
        nap "$INTERVAL"
        waited=$(( waited + INTERVAL ))
    done

    panic_latch_and_stop "still above ${PANIC_RECOVER}C after ${PANIC_TIMEOUT}s of purge"
}

# Latched by an earlier trip: stay running, but control nothing. The unit is
# still enabled precisely so this runs and says so — the fan is on the stock
# BIOS curve until somebody clears the flag.
if [ -e "$PANIC_FLAG" ]; then
    echo "Panic brake latched — $PANIC_FLAG exists. Fan control is OFF (BIOS auto)."
    echo "Last entry: $(tail -1 "$PANIC_FLAG" 2>/dev/null)"
    echo "Clear it with: rm $PANIC_FLAG && systemctl restart optiplex-fan"
    logger -p daemon.crit -t optiplex-fan "latched by the panic brake — fan control disabled, BIOS auto" 2>/dev/null
    command -v systemd-notify >/dev/null 2>&1 && systemd-notify --ready
    restore_bios
    beep long
    # Nothing to do but stay alive and keep saying so if anyone asks.
    while true; do ping_watchdog; nap "$INTERVAL"; done
fi

echo "Four-zone fan control active."
echo "  Temp source: $TEMP_INPUT"
echo "  PWM control: $PWM (enable: $PWM_ENABLE)"
echo "  Quiet below ${T_RESUME}C, BIOS auto from ${T_QUIET}C, every ${INTERVAL}s"
if (( T_BOOST > 0 )); then
    echo "  Boost (~3250 RPM) from ${T_BOOST}C, releases below $(( T_BOOST - T_HOT_HYST ))C"
else
    echo "  Boost zone: disabled (T_BOOST=0)"
fi
if (( T_PURGE > 0 )); then
    echo "  Purge (~4600 RPM) from ${T_PURGE}C, releases below $(( T_PURGE - T_HOT_HYST ))C"
else
    echo "  Purge zone: disabled (T_PURGE=0)"
fi
if (( T_PANIC > 0 )); then
    echo "  Panic brake: ${T_PANIC}C -> alarm + purge; ${PANIC_ACTION} unless it is back"
    echo "               to ${PANIC_RECOVER}C within ${PANIC_TIMEOUT}s"
else
    echo "  Panic brake: disabled (T_PANIC=0)"
fi

command -v systemd-notify >/dev/null 2>&1 && systemd-notify --ready

while true; do
    if ! temp_raw=$(cat "$TEMP_INPUT" 2>/dev/null) || [ -z "$temp_raw" ]; then
        # No temperature means no safe way to hold any manual level.
        go_auto
        nap "$INTERVAL"
        continue
    fi
    t=$(( temp_raw / 1000 ))

    apply_zone "$t"
    echo "temp=${t}C mode=${mode:-untouched} rpm=$(cat "$DELL_DIR/fan1_input" 2>/dev/null)"

    (( T_PANIC > 0 && t >= T_PANIC )) && panic_sequence "$t"

    ping_watchdog
    nap "$INTERVAL"
done

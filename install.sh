#!/bin/bash
# Installs (or updates) the two-zone fan-control daemon as a systemd service.
# Usage: sudo ./install.sh              (interactive prompts)
#        sudo ./install.sh -y           (non-interactive, keep/use defaults)
set -euo pipefail

INTERACTIVE=1
PROBE=auto
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--non-interactive) INTERACTIVE=0 ;;
        --probe)    PROBE=yes ;;
        --no-probe) PROBE=no ;;
    esac
done
# Prompts read from /dev/tty, not stdin, so that `curl ... | sudo bash` still
# asks questions instead of silently taking defaults. Test what we actually
# read from: a terminal we can open, not whether stdin happens to be one.
( : < /dev/tty ) 2>/dev/null || INTERACTIVE=0

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --- messages -------------------------------------------------------------
# English is defined here; lang/load.sh overrides it when FANCTL_LANG is set.
# %s conversions must survive translation in the same order.
MI_NEED_ROOT="Run with sudo: sudo ./install.sh"
MI_PANIC_TRIPPED="!! The overheat brake is latched — fan control is OFF until this is cleared:"
MI_PANIC_TRACE="   Latch: %s (remove it once you have dealt with the cause)\n"
MI_ENTER_INT="  Enter a whole number between %s and %s.\n"
MI_ANSWER_YN="  Answer y or n."
MI_PROBE_NO_DELL="   dell_smm hwmon not found — skipping the probe."
MI_PROBE_NO_WRITE="   %s is not writable — skipping the probe.\n"
MI_PROBE_STOPPING="   stopping optiplex-fan for the probe..."
MI_PROBE_BIOS="   measuring BIOS auto at idle..."
MI_PROBE_NO_MANUAL="   manual mode unavailable."
MI_PROBE_BOOST="   measuring boost (255 written once)..."
MI_PROBE_PURGE="   measuring purge (255 rewritten every two seconds)..."
MI_HEADER="== Fan control setup =="
MI_FOUND_CONF="Found an existing config at %s — current values are shown in brackets.\n"
MI_KEEP_HINT="Press Enter to keep the bracketed value."
MI_ZONES="There is no smooth curve here — the EC has discrete levels. The daemon
picks one of four states for the current temperature:
  below T_QUIET-T_HYST : quiet     level 1
  T_QUIET .. T_BOOST   : BIOS auto the stock curve
  T_BOOST .. T_PURGE   : boost     top level, written once
  T_PURGE and above    : purge     same level, but rewritten"
MI_ZONES_WHY="boost and purge are the same EC level. The difference is that every
write to pwm1 kicks the fan into a short burst, so rewriting it holds a
speed the level cannot sustain on its own."
MI_PROBE_HEADER="== Hardware probe (~50s) =="
MI_PROBE_WHY="Measures what each state actually does on THIS machine, so the defaults
come from your hardware and not someone else's OptiPlex. It gets loud."
MI_PROBE_ASK="Run the probe?"
MI_PROBE_FAILED="   probe failed, falling back to built-in defaults"
MI_PROBE_RESULTS="   Measured on this machine:"
MI_PROBE_QUIET="     quiet level    %s RPM\n"
MI_PROBE_IDLE="     BIOS at idle   %s RPM\n"
MI_PROBE_BOOST_RPM="     boost          %s RPM\n"
MI_PROBE_PURGE_RPM="     purge          %s RPM\n"
MI_PROBE_BOUNDARY="     top level starts at pwm %s\n"
MI_WARN_QUIET="   !! The quiet level is no quieter than BIOS auto — the bottom zone
      buys nothing here. Set T_QUIET low to bypass it."
MI_WARN_PURGE="   !! Rewriting gains nothing — purge == boost on this machine.
      You can turn the top zone off (T_PURGE=0)."
MI_Q_TQUIET="T_QUIET — temperature (C) at which control is handed to the BIOS"
MI_Q_THYST="T_HYST — degrees below T_QUIET before returning to quiet"
MI_Q_TBOOST="T_BOOST — temperature (C) for boost"
MI_Q_TPURGE="T_PURGE — temperature (C) for purge"
MI_Q_OFF="0 = off"
MI_Q_THOTHYST="T_HOT_HYST — degrees below the threshold before releasing the top zones"
MI_Q_QUIETPWM="QUIET_PWM — level held while quiet"
MI_Q_INTERVAL="INTERVAL — seconds between temperature checks"
MI_PANIC_HEADER="== Overheat protection (optional) =="
MI_PANIC_WHAT="If the CPU reaches T_PANIC — the fan is already flat out and losing —
the daemon sounds the alarm and holds the fan in purge. It then has
PANIC_TIMEOUT seconds to get the package back down to PANIC_RECOVER:
  reached it   the alarm was enough, work carries on as normal
  did not      one long beep, and the machine is powered off
A machine that shuts down this way comes back with fan control OFF: the
service still starts, but it only beeps to say it is latched, until you
remove /var/lib/optiplex-fan/panic."
MI_PANIC_AGAINST="Against it: --force skips the normal unmount, and the threshold has to
sit above what real workloads reach — 91C was measured here under full
load, with the CPU throttling at 100C. Too low a threshold means the
server shutting down in the middle of an ordinary build."
MI_PANIC_ASK="Enable overheat protection?"
MI_Q_TPANIC="T_PANIC — temperature (C) that triggers the alarm and purge"
MI_Q_PRECOVER="PANIC_RECOVER — temperature (C) it has to get back down to"
MI_Q_PTIMEOUT="PANIC_TIMEOUT — seconds allowed to get there"
MI_PANIC_ACTION_WHY="   Powering off is the safer end: a package that could not be cooled while
   running will not be cooled by coming straight back up into the same
   workload, and nothing drives the fan through POST at all."
MI_Q_PACTION="PANIC_ACTION — what to do when it does not recover [poweroff/reboot] (%s): "
MI_SUM_HEAD="Summary: quiet below %sC, BIOS auto from %sC, checked every %ss\n"
MI_SUM_BOOST="         boost from %sC (releases below %sC)\n"
MI_SUM_BOOST_OFF="         boost disabled"
MI_SUM_PURGE="         purge from %sC (releases below %sC)\n"
MI_SUM_PURGE_OFF="         purge disabled"
MI_SUM_PANIC="         overheat protection: alarm + purge at %sC,
         %s unless it is back to %sC within %ss\n"
MI_SUM_PANIC_OFF="         overheat protection disabled"
MI_CONFIRM="Write these to %s and continue installing? [Y/n]: "
MI_CANCELLED="Cancelled, nothing changed."
MI_NONINTERACTIVE="Non-interactive: using %s.\n"
MI_NI_EXISTING="the existing %s"
MI_NI_DEFAULTS="built-in defaults"
MI_LOADING_MODULE="Loading dell_smm_hwmon module..."
MI_DONE="Installed and running with %s.\n"
MI_HINT_STATUS="Status:   systemctl status optiplex-fan"
MI_HINT_LOG="Live log: journalctl -u optiplex-fan -f"
MI_HINT_RECONF="Reconfigure: sudo ./install.sh   (same prompts, current values as defaults)"
MI_ALARM_HEADER="== Audible alarm (optional) =="
MI_ALARM_WHAT="Every failure path here ends in BIOS auto — quietly, saying nothing
about it. The alarm is what says something, through the internal
speaker:
  two short beeps    trouble now: the daemon is not running, or the
                     overheat brake has tripped and is purging
  three long beeps   fan control is OFF: the brake latched, and the box
                     is on the stock BIOS curve until you clear it
The daemon beeps for itself, and a second, tiny service checks %ss into
each boot whether optiplex-fan is running at all — that is the one case
a dead daemon cannot report. Then it exits; nothing nags afterwards."
MI_ALARM_ASK="Install the audible alarm?"
MI_ALARM_NO_SOUND="   Note: no PC speaker (pcspkr) and no sound card found here. Installing
   anyway — it still logs, and the speaker may only show up after a
   reboot. See ALARM_BACKEND in the config."
MI_ALARM_TEST_ASK="Beep now to check the speaker?"
MI_ALARM_HEARD="Did you hear it?"
MI_ALARM_TRYING="   Trying the %s backend...\n"
MI_ALARM_TRYING_DEV="   Trying the sound card through %s...\n"
MI_ALARM_NEXT="   Nothing wired to the buzzer, then. Going through the sound card's
   outputs one at a time — say when you hear it."
MI_ALARM_PINNED="   Using ALARM_BACKEND=%s.\n"
MI_ALARM_DEAF="   Then nothing on this box makes a sound. Check that the speakers are
   on and the mixer is up, or set ALARM_BACKEND / ALARM_ALSA_DEV in %s by
   hand. The alarm still logs to the journal either way.\n"
MI_Q_ALARM_DELAY="ALARM_DELAY — seconds into the boot before the check"
MI_Q_ALARM_REPEATS="ALARM_REPEATS — how many times to repeat the beeps"
MI_SUM_ALARM="         boot beep %ss in, repeated %s time(s)\n"
MI_SUM_ALARM_OFF="         boot beep disabled"
MI_HINT_REMOVE="Remove:      sudo ./uninstall.sh"
MI_HINT_ALARM="Test beep:   sudo optiplex-fan-alarm.sh --test"
[ -r "$SRC_DIR/lang/load.sh" ] && . "$SRC_DIR/lang/load.sh"
# --------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "$MI_NEED_ROOT" >&2
    exit 1
fi
CONF_FILE=/etc/optiplex-fan.conf

# Defaults, overridden by an existing config if present (so re-running this
# installer on an already-configured box lets you tweak the current values).
T_QUIET=65
T_HYST=10
T_BOOST=75
T_PURGE=85
T_HOT_HYST=5
QUIET_PWM=0
INTERVAL=2
T_PANIC=0
PANIC_RECOVER=80
PANIC_TIMEOUT=120
PANIC_ACTION=poweroff
ALARM=1
ALARM_DELAY=30
ALARM_REPEATS=3
ALARM_BACKEND=auto
ALARM_ALSA_DEV=
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# An old linear-curve config may still be lying around; its keys are gone.
T_QUIET=${T_QUIET:-65}
T_HYST=${T_HYST:-10}
T_BOOST=${T_BOOST:-${T_HOT:-75}}
T_PURGE=${T_PURGE:-85}
T_HOT_HYST=${T_HOT_HYST:-5}
QUIET_PWM=${QUIET_PWM:-0}
INTERVAL=${INTERVAL:-2}
T_PANIC=${T_PANIC:-0}
# PANIC_COOL_TO / PANIC_COOL_TIMEOUT are the old names for these two.
PANIC_RECOVER=${PANIC_RECOVER:-${PANIC_COOL_TO:-80}}
PANIC_TIMEOUT=${PANIC_TIMEOUT:-${PANIC_COOL_TIMEOUT:-120}}
PANIC_ACTION=${PANIC_ACTION:-poweroff}
ALARM=${ALARM:-1}
ALARM_DELAY=${ALARM_DELAY:-30}
ALARM_REPEATS=${ALARM_REPEATS:-3}
ALARM_BACKEND=${ALARM_BACKEND:-auto}
ALARM_ALSA_DEV=${ALARM_ALSA_DEV:-}

PANIC_FLAG=/var/lib/optiplex-fan/panic
if [ -f "$PANIC_FLAG" ]; then
    echo "$MI_PANIC_TRIPPED"
    tail -3 "$PANIC_FLAG" | sed 's/^/   /'
    printf "$MI_PANIC_TRACE" "$PANIC_FLAG"
    echo
fi

prompt_int() {
    # prompt_int LABEL CURRENT MIN MAX -> prints the chosen integer
    local label="$1" cur="$2" min="$3" max="$4" val
    while true; do
        read -r -p "$label [$cur]: " val </dev/tty
        val="${val:-$cur}"
        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); then
            echo "$val"
            return 0
        fi
        printf "$MI_ENTER_INT" "$min" "$max" >&2
    done
}

# ---------------------------------------------------------------------------
# Hardware probe
#
# The fan levels this daemon switches between are an EC property, and they
# differ between OptiPlex models. Rather than shipping the 7080's numbers as
# gospel, measure them here and propose defaults from what this machine
# actually does.
#
# The level boundary is found by bisection on the pwm readback, which reflects
# the EC level immediately — no need to wait for the fan. Only the three RPM
# figures need settling time, so the whole probe costs about 40 seconds.
# ---------------------------------------------------------------------------

PROBE_DONE=0
PROBE_BOUNDARY=""      # lowest pwm that selects the top level
PROBE_RPM_QUIET=""
PROBE_RPM_BIOS=""
PROBE_RPM_BOOST=""     # top level written once and left alone
PROBE_RPM_PURGE=""     # top level rewritten every 2s

probe_find_hwmon() {
    local target="$1" dir
    for dir in /sys/class/hwmon/hwmon*; do
        [ -r "$dir/name" ] || continue
        [ "$(cat "$dir/name")" = "$target" ] && { echo "$dir"; return 0; }
    done
    return 1
}

probe_hardware() {
    local dell rb_low lo hi mid rb was_active=0

    dell=$(probe_find_hwmon dell_smm) || {
        echo "$MI_PROBE_NO_DELL" >&2
        return 1
    }
    local pwm="$dell/pwm1" en="$dell/pwm1_enable" fan="$dell/fan1_input"
    [ -w "$en" ] || { printf "$MI_PROBE_NO_WRITE" "$en" >&2; return 1; }

    systemctl is-active --quiet optiplex-fan.service && was_active=1
    if [ "$was_active" = 1 ]; then
        echo "$MI_PROBE_STOPPING"
        systemctl stop optiplex-fan.service
        sleep 3
    fi

    # Restore state even if the probe is interrupted.
    probe_restore() {
        echo 2 > "$en" 2>/dev/null
        [ "$was_active" = 1 ] && systemctl start optiplex-fan.service 2>/dev/null
    }
    trap probe_restore EXIT INT TERM

    echo "$MI_PROBE_BIOS"
    echo 2 > "$en" 2>/dev/null
    sleep 10
    PROBE_RPM_BIOS=$(cat "$fan" 2>/dev/null)

    echo 1 > "$en" 2>/dev/null || { echo "$MI_PROBE_NO_MANUAL" >&2; return 1; }
    echo 0 > "$pwm" 2>/dev/null
    sleep 12
    PROBE_RPM_QUIET=$(cat "$fan" 2>/dev/null)
    rb_low=$(cat "$pwm" 2>/dev/null)

    # Bisect: the lowest pwm whose readback differs from the bottom level.
    lo=0; hi=255
    while (( hi - lo > 1 )); do
        mid=$(( (lo + hi) / 2 ))
        echo "$mid" > "$pwm" 2>/dev/null
        rb=$(cat "$pwm" 2>/dev/null)
        if [ "$rb" = "$rb_low" ]; then lo=$mid; else hi=$mid; fi
    done
    PROBE_BOUNDARY=$hi

    echo "$MI_PROBE_BOOST"
    echo 255 > "$pwm" 2>/dev/null
    sleep 14
    PROBE_RPM_BOOST=$(cat "$fan" 2>/dev/null)

    echo "$MI_PROBE_PURGE"
    local kicker
    ( while :; do echo 255 > "$pwm" 2>/dev/null; sleep 2; done ) &
    kicker=$!
    sleep 14
    PROBE_RPM_PURGE=$(cat "$fan" 2>/dev/null)
    kill "$kicker" 2>/dev/null
    wait "$kicker" 2>/dev/null

    probe_restore
    trap - EXIT INT TERM
    PROBE_DONE=1
    return 0
}

QUIET_MAX=175

prompt_yesno() {
    # prompt_yesno LABEL DEFAULT(y|n) -> 0 = yes, 1 = no
    local label="$1" def="$2" ans hint
    if [ "$def" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    while true; do
        read -r -p "$label $hint: " ans </dev/tty
        ans="${ans:-$def}"
        case "$ans" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
        esac
        echo "$MI_ANSWER_YN" >&2
    done
}

if [ "$INTERACTIVE" -eq 1 ]; then
    echo "$MI_HEADER"
    [ -f "$CONF_FILE" ] && printf "$MI_FOUND_CONF" "$CONF_FILE"
    echo "$MI_KEEP_HINT"
    echo
    echo "$MI_ZONES"
    echo
    echo "$MI_ZONES_WHY"
    echo

    if [ "$PROBE" != no ]; then
        echo "$MI_PROBE_HEADER"
        echo "$MI_PROBE_WHY"
        echo
        if prompt_yesno "$MI_PROBE_ASK" y; then
            probe_hardware || echo "$MI_PROBE_FAILED"
        fi
    fi

    if [ "$PROBE_DONE" = 1 ]; then
        echo
        echo "$MI_PROBE_RESULTS"
        printf "$MI_PROBE_QUIET" "$PROBE_RPM_QUIET"
        printf "$MI_PROBE_IDLE" "$PROBE_RPM_BIOS"
        printf "$MI_PROBE_BOOST_RPM" "$PROBE_RPM_BOOST"
        printf "$MI_PROBE_PURGE_RPM" "$PROBE_RPM_PURGE"
        printf "$MI_PROBE_BOUNDARY" "$PROBE_BOUNDARY"
        if (( PROBE_RPM_QUIET >= PROBE_RPM_BIOS )); then
            echo "$MI_WARN_QUIET"
        fi
        if (( PROBE_RPM_PURGE <= PROBE_RPM_BOOST + 100 )); then
            echo "$MI_WARN_PURGE"
        fi
        # Clamp the quiet level to the measured boundary, not the 7080 figure.
        if [ -n "$PROBE_BOUNDARY" ] && (( PROBE_BOUNDARY > 1 )); then
            QUIET_MAX=$(( PROBE_BOUNDARY - 1 ))
        fi
        echo
    fi

    T_QUIET=$(prompt_int "$MI_Q_TQUIET" "$T_QUIET" 30 90)
    T_HYST=$(prompt_int "$MI_Q_THYST" "$T_HYST" 1 20)
    T_BOOST=$(prompt_int "$MI_Q_TBOOST${PROBE_RPM_BOOST:+ (~$PROBE_RPM_BOOST RPM)} ($MI_Q_OFF)" "$T_BOOST" 0 99)
    T_PURGE=$(prompt_int "$MI_Q_TPURGE${PROBE_RPM_PURGE:+ (~$PROBE_RPM_PURGE RPM)} ($MI_Q_OFF)" "$T_PURGE" 0 99)
    if (( T_BOOST > 0 || T_PURGE > 0 )); then
        T_HOT_HYST=$(prompt_int "$MI_Q_THOTHYST" "$T_HOT_HYST" 1 30)
    fi
    QUIET_PWM=$(prompt_int "$MI_Q_QUIETPWM (0..${QUIET_MAX})" "$QUIET_PWM" 0 "$QUIET_MAX")
    INTERVAL=$(prompt_int "$MI_Q_INTERVAL" "$INTERVAL" 1 10)

    echo
    echo "$MI_PANIC_HEADER"
    echo "$MI_PANIC_WHAT"
    echo
    echo "$MI_PANIC_AGAINST"
    echo
    # Off by default: this machine legitimately reaches 91C under full load, so
    # shutting the box down is a deliberate choice, not something to inherit.
    panic_default=n
    (( T_PANIC > 0 )) && panic_default=y
    if prompt_yesno "$MI_PANIC_ASK" "$panic_default"; then
        # Coming back from disabled, offer a sensible default rather than 0.
        (( T_PANIC == 0 )) && T_PANIC=95
        T_PANIC=$(prompt_int "$MI_Q_TPANIC" "$T_PANIC" 1 99)
        PANIC_RECOVER=$(prompt_int "$MI_Q_PRECOVER" "$PANIC_RECOVER" 30 $(( T_PANIC - 1 )))
        PANIC_TIMEOUT=$(prompt_int "$MI_Q_PTIMEOUT" "$PANIC_TIMEOUT" 10 3600)
        echo "$MI_PANIC_ACTION_WHY"
        while true; do
            read -r -p "$(printf "$MI_Q_PACTION" "$PANIC_ACTION")" panic_action_ans </dev/tty
            panic_action_ans=${panic_action_ans:-$PANIC_ACTION}
            case "$panic_action_ans" in
                poweroff|reboot) PANIC_ACTION=$panic_action_ans; break ;;
            esac
        done
    else
        T_PANIC=0
    fi

    echo
    echo "$MI_ALARM_HEADER"
    printf "$MI_ALARM_WHAT\n" "$ALARM_DELAY"
    echo
    alarm_default=n
    (( ALARM > 0 )) && alarm_default=y
    if prompt_yesno "$MI_ALARM_ASK" "$alarm_default"; then
        ALARM=1
        # A silent alarm is worse than none — it is a promise the box cannot
        # keep — so say so now, while it can still be answered with n.
        "$SRC_DIR/optiplex-fan-alarm.sh" --check 2>/dev/null | grep -q 'backend: none' \
            && echo "$MI_ALARM_NO_SOUND"
        ALARM_DELAY=$(prompt_int "$MI_Q_ALARM_DELAY" "$ALARM_DELAY" 0 600)
        ALARM_REPEATS=$(prompt_int "$MI_Q_ALARM_REPEATS" "$ALARM_REPEATS" 1 20)
        if prompt_yesno "$MI_ALARM_TEST_ASK" y; then
            # auto cannot tell a pcspkr driver with a buzzer on the end from one
            # with nothing on the end — only an ear can. So ask, and if the
            # answer is no, fall through to the sound card and ask again.
            alarm_heard=0
            if [ "$ALARM_BACKEND" != alsa ]; then
                printf "$MI_ALARM_TRYING" "$ALARM_BACKEND"
                "$SRC_DIR/optiplex-fan-alarm.sh" --test >/dev/null 2>&1 || true
                if prompt_yesno "$MI_ALARM_HEARD" n; then
                    alarm_heard=1
                else
                    echo "$MI_ALARM_NEXT"
                fi
            fi
            # Which socket has a speaker on it is not something the machine can
            # answer — an HDMI output that takes the samples happily may be a
            # sleeping monitor. So walk them and let an ear pick, then pin it:
            # at boot this runs as root with no session to guess for it.
            if (( alarm_heard == 0 )); then
                for dev in $("$SRC_DIR/optiplex-fan-alarm.sh" --devices); do
                    printf "$MI_ALARM_TRYING_DEV" "$dev"
                    ALARM_BACKEND=alsa ALARM_ALSA_DEV="$dev" \
                        "$SRC_DIR/optiplex-fan-alarm.sh" --test >/dev/null 2>&1 || true
                    if prompt_yesno "$MI_ALARM_HEARD" n; then
                        ALARM_BACKEND=alsa
                        ALARM_ALSA_DEV="$dev"
                        printf "$MI_ALARM_PINNED" "alsa ($dev)"
                        alarm_heard=1
                        break
                    fi
                done
            fi
            (( alarm_heard )) || printf "$MI_ALARM_DEAF" "$CONF_FILE"
        fi
    else
        ALARM=0
    fi

    echo
    printf "$MI_SUM_HEAD" "$((T_QUIET - T_HYST))" "$T_QUIET" "$INTERVAL"
    if (( T_BOOST > 0 )); then
        printf "$MI_SUM_BOOST" "$T_BOOST" "$((T_BOOST - T_HOT_HYST))"
    else
        echo "$MI_SUM_BOOST_OFF"
    fi
    if (( T_PURGE > 0 )); then
        printf "$MI_SUM_PURGE" "$T_PURGE" "$((T_PURGE - T_HOT_HYST))"
    else
        echo "$MI_SUM_PURGE_OFF"
    fi
    if (( T_PANIC > 0 )); then
        printf "$MI_SUM_PANIC" "$T_PANIC" "$PANIC_ACTION" "$PANIC_RECOVER" "$PANIC_TIMEOUT"
    else
        echo "$MI_SUM_PANIC_OFF"
    fi
    if (( ALARM > 0 )); then
        printf "$MI_SUM_ALARM" "$ALARM_DELAY" "$ALARM_REPEATS"
    else
        echo "$MI_SUM_ALARM_OFF"
    fi
    # `|| true`: a closed tty makes read return non-zero, and under set -e that
    # would kill the installer silently after asking every question.
    ok=""
    read -r -p "$(printf "$MI_CONFIRM" "$CONF_FILE")" ok </dev/tty || true
    if [[ "$ok" =~ ^[Nn]$ ]]; then
        echo "$MI_CANCELLED"
        exit 1
    fi
else
    printf "$MI_NONINTERACTIVE" "$( [ -f "$CONF_FILE" ] && printf "$MI_NI_EXISTING" "$CONF_FILE" || echo "$MI_NI_DEFAULTS" )"
fi

cat > "$CONF_FILE" <<EOF
# Config for optiplex-fan.service — edit, then \`sudo systemctl restart optiplex-fan\`,
# or re-run install.sh for an interactive prompt.
#
# T_QUIET:   CPU package temperature (C) at which the daemon hands the fan back
#            to BIOS automatic control. Everything above this point — including
#            the stock overheat protection — is the BIOS's own curve.
# T_HYST:    how far below T_QUIET the CPU must fall to re-enter quiet mode.
# QUIET_PWM: fan level held while quiet. The EC only distinguishes 0/1 vs 2, and
#            anything from 0 to 175 lands on the same ~1130 RPM level. From 192
#            up the EC switches to its full-speed level, so higher values are
#            clamped away — they would be the opposite of quiet.
# INTERVAL:  seconds between temperature checks (clamped to 1..10 by the daemon,
#            which must stay well inside the service's WatchdogSec).
# T_HOT:         CPU temperature (C) from which the daemon drives the fan flat
#                out (pwm 255, ~4800 RPM) instead of waiting for the BIOS. The
#                stock curve ramps far too slowly up here: measured, the same
#                12-thread load settles at 91C behind the BIOS curve and at 81C
#                with the fan already spun up. 0 disables the zone.
# T_HOT_HYST:    how far below T_HOT the CPU must fall before the fan is handed
#                back to the BIOS. Separate from T_HYST because the top zone
#                wants a tighter grip: once the fan is flat out it should stay
#                there until the package has genuinely come down.
# T_PANIC:       CPU temperature (C) at which the daemon sounds the alarm and
#                holds the fan in purge. By this point the fan is already flat
#                out from T_PURGE, so this is not extra cooling — it is the
#                point at which losing the race stops being acceptable.
#                Keep it above T_PURGE and above what real workloads reach —
#                this CPU is measured at 91C under full load and throttles at
#                100. 0 disables the whole brake, and that is the default.
# PANIC_RECOVER: the temperature (C) it has to get back down to. Reaching it
#                means the alarm was enough and work carries on as normal.
# PANIC_TIMEOUT: seconds allowed to get there. If the package is still above
#                PANIC_RECOVER when they run out, the cooling has lost: one
#                long beep, and PANIC_ACTION.
# PANIC_ACTION:  poweroff (default) or reboot. Powering off is the safer end —
#                a package that could not be cooled while running will not be
#                cooled by coming straight back up into the same workload, and
#                nothing drives the fan through POST at all. reboot is for a
#                machine that has to come back on its own.
#                Either way the daemon latches first, by writing
#                /var/lib/optiplex-fan/panic. On the next boot the service
#                still starts — it just controls nothing and beeps to say so,
#                which is why the latch is a file and not a disabled unit.
#                Remove that file to hand control back.
# ALARM:         beep the internal speaker. At boot, if optiplex-fan.service is
#                not running; and on demand for the daemon, which is how the
#                panic beeps get made. Everything here fails safe into the BIOS
#                curve without a word, so a silent box is exactly the one that
#                needs to say something. Two short beeps mean trouble now (not
#                running, or the brake purging); three long ones mean fan
#                control is off and latched. 0 disables the alarm entirely.
# ALARM_DELAY:   seconds into the boot before the check, so a daemon that is
#                still coming up is not reported as dead.
# ALARM_REPEATS: how many times the whole signal is played. Separate from
#                ALARM_RETRIES, which is how many times a beep that did not
#                play at all — a sound card busy for a moment — is attempted
#                again.
# ALARM_BEEPS / ALARM_LONG_BEEPS:
#                beeps in each signal, two and three.
# ALARM_BACKEND: auto (default), beep, console, alsa or none. auto prefers the
#                beep(1) binary, then the kernel console bell — both need the
#                pcspkr module, which the alarm loads by name even though
#                Ubuntu blacklists it — and falls back to a sine through the
#                sound card. What auto cannot know is whether the pcspkr line
#                reaches a buzzer at all: many machines load the driver, expose
#                the input device, and have nothing soldered to the far end. If
#                the test beep was inaudible, this says alsa.
# ALARM_ALSA_DEV: which PCM the alsa backend plays through. Empty (default)
#                tries "default" first, then every device aplay lists, and
#                keeps the first one that takes it. Name one — plughw:0,0 for
#                the green socket, plughw:0,3 for the first HDMI — if the
#                sound comes out of the wrong place.
# ALARM_FREQ / ALARM_LEN / ALARM_LONG_LEN / ALARM_GAP / ALARM_REPEAT_GAP:
#                pitch (Hz) and lengths (ms, except REPEAT_GAP which is
#                seconds) of the beeps. Defaults: 1000, 150, 600, 150, 5.
# ALARM_ALSA_MIXER / ALARM_ALSA_LEVEL / ALARM_ALSA_AMP:
#                which mixer controls to raise for the beep (colon-separated,
#                because names have spaces in them), how far, and how loud the
#                generated tone itself is. All three are restored afterwards.
#                Defaults: "Master:Speaker:PCM:Line Out", 80%, 90%. A desktop
#                session pointing at HDMI parks the analog volume at zero, so
#                without this the beep plays at -65dB into the speaker.
T_QUIET=$T_QUIET
T_HYST=$T_HYST
T_BOOST=$T_BOOST
T_PURGE=$T_PURGE
T_HOT_HYST=$T_HOT_HYST
QUIET_PWM=$QUIET_PWM
INTERVAL=$INTERVAL
T_PANIC=$T_PANIC
PANIC_RECOVER=$PANIC_RECOVER
PANIC_TIMEOUT=$PANIC_TIMEOUT
PANIC_ACTION=$PANIC_ACTION
ALARM=$ALARM
ALARM_DELAY=$ALARM_DELAY
ALARM_REPEATS=$ALARM_REPEATS
ALARM_BACKEND=$ALARM_BACKEND
ALARM_ALSA_DEV=$ALARM_ALSA_DEV
EOF
chmod 644 "$CONF_FILE"

if ! lsmod | grep -q '^dell_smm_hwmon'; then
    echo "$MI_LOADING_MODULE"
    modprobe dell_smm_hwmon
fi
if ! grep -qs '^dell_smm_hwmon' /etc/modules-load.d/*.conf 2>/dev/null; then
    echo "dell_smm_hwmon" > /etc/modules-load.d/dell-smm-hwmon.conf
fi

install -m 755 "$SRC_DIR/optiplex-fan-control.sh" /usr/local/sbin/optiplex-fan-control.sh
install -m 644 "$SRC_DIR/optiplex-fan.service" /etc/systemd/system/optiplex-fan.service
install -m 755 "$SRC_DIR/optiplex-fan-alarm.sh" /usr/local/sbin/optiplex-fan-alarm.sh
install -m 644 "$SRC_DIR/optiplex-fan-alarm.service" /etc/systemd/system/optiplex-fan-alarm.service

systemctl daemon-reload
systemctl enable optiplex-fan.service
systemctl restart optiplex-fan.service

# Enabled, never started here: it is a boot check, and starting it now would
# only sit through ALARM_DELAY to conclude what we already know — the daemon
# was restarted a line ago and is running.
if (( ALARM > 0 )); then
    systemctl enable optiplex-fan-alarm.service
else
    systemctl disable optiplex-fan-alarm.service
fi

echo
printf "$MI_DONE" "$CONF_FILE"
echo "$MI_HINT_STATUS"
echo "$MI_HINT_LOG"
echo "$MI_HINT_RECONF"
echo "$MI_HINT_REMOVE"
if (( ALARM > 0 )); then
    echo "$MI_HINT_ALARM"
fi

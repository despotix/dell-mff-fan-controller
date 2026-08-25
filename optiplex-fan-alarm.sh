#!/bin/bash
# Beeps at boot if the fan daemon did not come up.
#
# The daemon fails safe: every exit path hands the fan back to the BIOS, and the
# panic brake goes one further — it disables its own unit before rebooting, so a
# box that gave up on cooling comes back stock with nothing started. That is the
# right behaviour and it is completely silent, which is the problem: a headless
# machine gives no sign that the quiet idle, the boost zone and the brake itself
# are all gone until somebody next looks at it.
#
# So: one check, ALARM_DELAY seconds into the boot, and if optiplex-fan is not
# running, beep the box's own speaker. Two cases, told apart because they mean
# different things:
#
#   unit enabled, not running   two short beeps    it failed to start
#   unit disabled               three long beeps   the panic brake latched it
#
# It says its piece and exits. Nothing nags afterwards, and nothing beeps while
# the daemon is running — a beep from this box always means the same thing.
#
# Separate unit on purpose: what it reports on is the fan daemon not running, so
# it cannot live inside that daemon, and the panic latch — which disables
# optiplex-fan.service — must not be able to switch off the alarm with it.
#
# Usage: optiplex-fan-alarm.sh          check once and beep if needed (the unit)
#        optiplex-fan-alarm.sh --now    the same check with no start-up delay
#        optiplex-fan-alarm.sh --test   beep the alert pattern and exit
#        optiplex-fan-alarm.sh --check  report state and backend, make no sound
#        optiplex-fan-alarm.sh --devices list the ALSA outputs it would try
set -u

# CONF is overridable so this can be exercised without touching the real
# system. Never set it in production.
CONF=${CONF:-/etc/optiplex-fan.conf}
[ -f "$CONF" ] && source "$CONF"

ALARM=${ALARM:-1}
ALARM_UNIT=${ALARM_UNIT:-optiplex-fan.service}
ALARM_DELAY=${ALARM_DELAY:-30}
ALARM_REPEATS=${ALARM_REPEATS:-3}
ALARM_REPEAT_GAP=${ALARM_REPEAT_GAP:-5}
ALARM_RETRIES=${ALARM_RETRIES:-3}
ALARM_RETRY_GAP=${ALARM_RETRY_GAP:-3}
ALARM_BEEPS=${ALARM_BEEPS:-2}
ALARM_LONG_BEEPS=${ALARM_LONG_BEEPS:-3}
ALARM_FREQ=${ALARM_FREQ:-1000}
ALARM_LEN=${ALARM_LEN:-150}
ALARM_GAP=${ALARM_GAP:-150}
ALARM_LONG_LEN=${ALARM_LONG_LEN:-600}
ALARM_BACKEND=${ALARM_BACKEND:-auto}
ALARM_ALSA_DEV=${ALARM_ALSA_DEV:-}
ALARM_ALSA_RATE=${ALARM_ALSA_RATE:-16000}
ALARM_ALSA_AMP=${ALARM_ALSA_AMP:-90}
# Colon-separated, because control names have spaces in them ("Line Out").
ALARM_ALSA_MIXER=${ALARM_ALSA_MIXER:-Master:Speaker:PCM:Line Out}
ALARM_ALSA_LEVEL=${ALARM_ALSA_LEVEL:-80}

# The delay exists to let the daemon start; systemd may well have ordered us
# after it anyway, but Restart=always means a daemon that crashed once is still
# on its way back up, and beeping at that would be a false alarm.
(( ALARM_DELAY < 0 ))    && ALARM_DELAY=0
(( ALARM_REPEATS < 1 ))  && ALARM_REPEATS=1
(( ALARM_RETRIES < 1 ))  && ALARM_RETRIES=1
(( ALARM_BEEPS < 1 ))       && ALARM_BEEPS=1
(( ALARM_LONG_BEEPS < 1 ))  && ALARM_LONG_BEEPS=1
(( ALARM_FREQ < 20 ))    && ALARM_FREQ=20
(( ALARM_FREQ > 20000 )) && ALARM_FREQ=20000
(( ALARM_LEN < 20 ))      && ALARM_LEN=20
(( ALARM_LONG_LEN < 20 )) && ALARM_LONG_LEN=20
(( ALARM_ALSA_AMP < 1 ))   && ALARM_ALSA_AMP=1
(( ALARM_ALSA_AMP > 100 )) && ALARM_ALSA_AMP=100
(( ALARM_ALSA_LEVEL < 1 ))   && ALARM_ALSA_LEVEL=1
(( ALARM_ALSA_LEVEL > 100 )) && ALARM_ALSA_LEVEL=100

log() { echo "$*"; logger -p daemon.warning -t optiplex-fan-alarm "$*" 2>/dev/null; }

# --- making a noise ---------------------------------------------------------
#
# Three ways down, in order of how much control they give:
#
#   beep      the beep(1) binary, if it happens to be installed
#   console   the kernel console bell, which is the same pcspkr driver reached
#             through the VT's own escape sequences: ESC[10;<Hz>] sets the
#             pitch, ESC[11;<ms>] the duration, BEL sounds it. Nothing to
#             install, and both are put back to the kernel defaults afterwards
#             so an ordinary console bell is not left retuned.
#   alsa      a sine wave through the sound card, for a box with no buzzer but
#             something plugged into the green socket. The samples are made
#             here and piped to aplay as raw U8, so the tone is the same pitch
#             and length as the other two backends give.
#
# The first two need the pcspkr module, which Ubuntu blacklists by default. A
# blacklist only suppresses loading by alias, so asking for it by name — which
# is what the modprobe below does — still works.
#
# What auto cannot know is whether the pcspkr line goes anywhere: plenty of
# machines load the driver, expose the input device, and have no buzzer soldered
# to the other end. There is no way to ask. That is what the installer's "did
# you hear it?" question is for, and answering no there pins ALARM_BACKEND=alsa.

CONSOLE=""
ALSA_DEVS=""

have_pcspkr() { grep -q '"PC Speaker"' /proc/bus/input/devices 2>/dev/null; }

find_console() {
    local d
    for d in /dev/tty0 /dev/console; do
        [ -w "$d" ] && { CONSOLE=$d; return 0; }
    done
    return 1
}

have_alsa() {
    command -v aplay >/dev/null 2>&1 || return 1
    command -v awk  >/dev/null 2>&1 || return 1
    grep -q '[0-9]' /proc/asound/cards 2>/dev/null
}

# Which PCM to play through. An explicit ALARM_ALSA_DEV is the only one tried;
# otherwise every hardware device aplay lists, in its order — which puts the
# analog codec, and so the internal speaker, ahead of the HDMI outputs — and
# "default" last.
#
# Hardware first, not "default" first: this runs as root during boot, where
# there is no desktop session for "default" to lean on. It may resolve to
# PipeWire and fail, or worse, succeed and play into an HDMI monitor that is
# asleep. A named device always means the same socket.
alsa_devices() {
    if [ -n "$ALARM_ALSA_DEV" ]; then
        echo "$ALARM_ALSA_DEV"
        return
    fi
    aplay -l 2>/dev/null | awk '/^card [0-9]+:.*device [0-9]+:/ {
        card = $2; sub(":", "", card)
        dev = $0; sub(/.*device /, "", dev); sub(/:.*/, "", dev)
        print "plughw:" card "," dev
    }'
    echo default
}

# An alarm that plays into a muted output is not an alarm. Whatever left the
# mixer where it is — a desktop session pointing at HDMI parks the analog sink's
# volume at zero, which is -65dB into the internal speaker and silence to anyone
# in the room — this raises the playback controls just long enough to be heard,
# then puts them back exactly as they were.
#
# The snapshot is alsactl's own, so restoring is its business rather than a
# guess at what "as they were" meant per channel. It hangs off an EXIT trap: a
# killed alarm must not leave the speakers wound up.
MIXER_SNAPSHOT=""
MIXER_MANUAL=""
MIXER_CARD=""

alsa_card_of() {
    # plughw:0,0 -> 0, hw:1,3 -> 1, anything else -> 0
    local dev="$1" n
    case "$dev" in
        *hw:*) n=${dev#*hw:}; n=${n%%,*} ;;
        *)     n=0 ;;
    esac
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}

alsa_mixer_up() {
    local card="$1" c
    [ -n "$ALARM_ALSA_MIXER" ] || return 0
    command -v amixer >/dev/null 2>&1 || return 0
    # Either snapshot means the mixer is already up and already remembered.
    # Missing the manual one here meant re-snapshotting the raised levels on the
    # second beep, and the restore then wound back to those instead.
    [ -n "$MIXER_SNAPSHOT$MIXER_MANUAL" ] && return 0
    if command -v alsactl >/dev/null 2>&1; then
        MIXER_SNAPSHOT=$(mktemp /run/optiplex-fan-alarm.mixer.XXXXXX 2>/dev/null) || MIXER_SNAPSHOT=""
        if [ -n "$MIXER_SNAPSHOT" ] && ! alsactl -f "$MIXER_SNAPSHOT" store "$card" 2>/dev/null; then
            rm -f "$MIXER_SNAPSHOT"
            MIXER_SNAPSHOT=""
        fi
    fi
    # No alsactl, or nowhere to write its snapshot: remember the level and the
    # switch per control by hand. Coarser than alsactl — one level for all
    # channels — but it is the difference between putting the mixer back and
    # leaving somebody's volume at 80% for good.
    if [ -z "$MIXER_SNAPSHOT" ]; then
        local lvl sw out
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            out=$(amixer -c "$card" sget "$c" 2>/dev/null) || continue
            lvl=$(echo "$out" | grep -om1 '[0-9]*%')
            sw=$(echo "$out"  | grep -om1 '\[o[nf]*\]' | tr -d '[]')
            [ -n "$lvl$sw" ] && MIXER_MANUAL+="${lvl:--} ${sw:--} $c"$'\n'
        done <<< "${ALARM_ALSA_MIXER//:/$'\n'}"
    fi
    MIXER_CARD="$card"
    # Volume and switch go in separate calls: a switch-only control ("Line Out")
    # rejects the whole command if a percentage is bundled with it, and then it
    # would never get unmuted.
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        amixer -c "$card" sset "$c" "${ALARM_ALSA_LEVEL}%" >/dev/null 2>&1
        amixer -c "$card" sset "$c" unmute                 >/dev/null 2>&1
    done <<< "${ALARM_ALSA_MIXER//:/$'\n'}"
    return 0
}

alsa_mixer_restore() {
    local c lvl sw
    if [ -n "$MIXER_SNAPSHOT" ]; then
        alsactl -f "$MIXER_SNAPSHOT" restore "$MIXER_CARD" 2>/dev/null
        rm -f "$MIXER_SNAPSHOT"
        MIXER_SNAPSHOT=""
        return 0
    fi
    [ -n "$MIXER_MANUAL" ] || return 0
    # Level and switch first, control name last: the name is the field that can
    # contain spaces, so it has to be the one read soaks up the rest of.
    while read -r lvl sw c; do
        [ -n "$c" ] || continue
        [ "$lvl" = - ] || amixer -c "$MIXER_CARD" sset "$c" "$lvl" >/dev/null 2>&1
        [ "$sw" = - ]  || amixer -c "$MIXER_CARD" sset "$c" "$sw"  >/dev/null 2>&1
    done <<< "$MIXER_MANUAL"
    MIXER_MANUAL=""
    return 0
}

# One sine, as raw unsigned 8-bit. LC_ALL=C matters: in a UTF-8 locale gawk
# would helpfully turn %c above 127 into a multi-byte character and the tone
# would come out as noise of the wrong length.
alsa_samples() {
    LC_ALL=C awk -v r="$ALARM_ALSA_RATE" -v hz="$ALARM_FREQ" -v ms="$1" -v amp="$ALARM_ALSA_AMP" '
        BEGIN {
            n = int(r * ms / 1000)
            a = 127 * amp / 100
            for (i = 0; i < n; i++)
                printf "%c", int(128 + a * sin(6.283185307179586 * hz * i / r))
        }'
}

detect_backend() {
    case "$ALARM_BACKEND" in
        beep|none)
            BACKEND=$ALARM_BACKEND
            return 0
            ;;
        alsa)
            BACKEND=alsa
            ALSA_DEVS=$(alsa_devices)
            return 0
            ;;
        console)
            # Without a writable console there is nothing to write the bell to,
            # and pretending otherwise would only produce a failed redirection.
            find_console && { BACKEND=console; return 0; }
            log "ALARM_BACKEND=console but no writable /dev/tty0 or /dev/console"
            BACKEND=none
            return 1
            ;;
    esac
    have_pcspkr || modprobe pcspkr 2>/dev/null
    if have_pcspkr; then
        command -v beep >/dev/null 2>&1 && { BACKEND=beep; return 0; }
        find_console && { BACKEND=console; return 0; }
    fi
    have_alsa && { BACKEND=alsa; ALSA_DEVS=$(alsa_devices); return 0; }
    BACKEND=none
    return 1
}

ms_to_s() { printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )); }

# One tone, ms long. The caller spaces them out.
tone() {
    local ms="$1"
    case "$BACKEND" in
        beep)
            beep -f "$ALARM_FREQ" -l "$ms" 2>/dev/null
            ;;
        console)
            # The reset at the end only affects the *next* bell — the tone this
            # BEL started is already running on its own timer.
            printf '\033[10;%d]\033[11;%d]\a\033[10;750]\033[11;125]' \
                "$ALARM_FREQ" "$ms" > "$CONSOLE" 2>/dev/null
            sleep "$(ms_to_s "$ms")"
            ;;
        alsa)
            local dev err
            for dev in $ALSA_DEVS; do
                alsa_mixer_up "$(alsa_card_of "$dev")"
                if err=$(alsa_samples "$ms" | aplay -q -t raw -f U8 \
                        -r "$ALARM_ALSA_RATE" -c 1 -D "$dev" - 2>&1); then
                    # Stop shopping around once something has taken it, so the
                    # repeats do not re-walk the list on every beep.
                    ALSA_DEVS=$dev
                    return 0
                fi
            done
            log "aplay could not play through $ALSA_DEVS: ${err:-unknown error}"
            return 1
            ;;
        *)  return 1 ;;
    esac
    return 0
}

pattern() {
    # pattern COUNT LENGTH_MS
    local count="$1" ms="$2" i
    if [ "$BACKEND" = none ]; then
        [ "$ALARM_BACKEND" = auto ] &&
            log "no way to make a sound (no PC speaker, no sound card) — alarm is mute"
        return 1
    fi
    for (( i = 0; i < count; i++ )); do
        tone "$ms" || return 1
        (( i + 1 < count )) && sleep "$(ms_to_s "$ALARM_GAP")"
    done
    return 0
}

# --- what the beeps mean ----------------------------------------------------

unit_active()  { systemctl is-active  --quiet "$ALARM_UNIT"; }
unit_enabled() { systemctl is-enabled --quiet "$ALARM_UNIT" 2>/dev/null; }

# Two short: enabled but not running, so it tried and failed (or someone stopped
# it before this check). Three long: the unit is disabled, which is exactly what
# the panic brake leaves behind — that machine rebooted itself and came back
# stock, and nobody has looked at it since.
#
# It is meant to read as an error, not as a notification: short, hard beeps at
# full amplitude, repeated. The counts and lengths are knobs, but the defaults
# are the signal.
alert_pattern() {
    if unit_enabled; then
        pattern "$ALARM_BEEPS" "$ALARM_LEN"
    else
        pattern "$ALARM_LONG_BEEPS" "$ALARM_LONG_LEN"
    fi
}

# Two different counters, because they answer different questions. ALARM_REPEATS
# is how many times the signal should be heard; ALARM_RETRIES is how many times
# to try again when it was not played at all — the usual reason being the sound
# card held by something else for a moment, an audio server that has not
# suspended yet, which is free again seconds later.
alert() {
    local played=0 failed=0
    while (( played < ALARM_REPEATS && failed < ALARM_RETRIES )); do
        if alert_pattern; then
            played=$(( played + 1 ))
            (( played < ALARM_REPEATS )) && sleep "$ALARM_REPEAT_GAP"
        else
            failed=$(( failed + 1 ))
            (( failed < ALARM_RETRIES )) && sleep "$ALARM_RETRY_GAP"
        fi
    done
    alsa_mixer_restore
    (( played > 0 ))
}

why_down() {
    if unit_enabled; then
        echo "$ALARM_UNIT did not start — the fan is on the stock BIOS curve"
    else
        echo "$ALARM_UNIT is disabled and did not start — the panic brake latches it exactly like this; the fan is on the stock BIOS curve"
    fi
}

detect_backend

# Whatever happens next, the mixer goes back the way it was found.
trap alsa_mixer_restore EXIT

case "${1:-}" in
    --test)
        echo "backend: $BACKEND${CONSOLE:+ ($CONSOLE)}${ALSA_DEVS:+ ($(echo $ALSA_DEVS | tr '\n' ' '))}"
        [ "$BACKEND" = none ] && { echo "Nothing here can make a sound." >&2; exit 1; }
        alert_pattern
        exit $?    # the EXIT trap puts the mixer back
        ;;
    --check)
        echo "unit:    $ALARM_UNIT"
        echo "active:  $(systemctl is-active "$ALARM_UNIT" 2>/dev/null)"
        echo "enabled: $(systemctl is-enabled "$ALARM_UNIT" 2>/dev/null)"
        echo "backend: $BACKEND${CONSOLE:+ ($CONSOLE)}${ALSA_DEVS:+ ($(echo $ALSA_DEVS | tr '\n' ' '))}"
        [ "$BACKEND" = alsa ] && [ -n "$ALARM_ALSA_MIXER" ] &&
            echo "mixer:   raises $ALARM_ALSA_MIXER to ${ALARM_ALSA_LEVEL}% for the beep, then restores"
        echo "alarm:   $( (( ALARM )) && echo enabled || echo "disabled (ALARM=0)" )"
        exit 0
        ;;
    --devices)
        # What the alsa backend would walk, in order. The installer uses this to
        # let an ear pick the output, since nothing here can tell which socket
        # has a speaker on it.
        alsa_devices
        exit 0
        ;;
    --now)
        ALARM_DELAY=0
        ;;
esac

if (( ALARM == 0 )); then
    echo "ALARM=0 in $CONF — nothing to do."
    exit 0
fi

(( ALARM_DELAY > 0 )) && sleep "$ALARM_DELAY"

if unit_active; then
    echo "$ALARM_UNIT is running — no alarm."
    exit 0
fi

log "$(why_down)"
alert
exit 0

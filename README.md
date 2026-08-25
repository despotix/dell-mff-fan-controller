# dell-mff-fan-controller

Three-zone fan control for Dell OptiPlex Micro machines on Linux. It gives you
a quiet idle instead of the needlessly loud stock curve, and forces the fan to
full speed where the BIOS ramps up far too late.

English · [українською](README.ua.md)

> Developed and measured on an **OptiPlex 7080 Micro** (i5-10500T, Ubuntu 26.04,
> kernel 7.0). Other OptiPlex models exposed through `dell_smm_hwmon` should
> work, but verify the thresholds on your own machine — see `thermal-test.sh`.

**Key features**

- **Quiet idle.** The EC has a ~1130 RPM level the BIOS never uses. On my own
  unit the stock curve holds **2000+ RPM on a cold CPU** — audible in a quiet
  room; this daemon actually uses the quiet level instead.
- **Aggressive ramp under load**, forcing full speed where the stock curve
  steps too late and lets the package run hotter than it needs to.
- **Overheat protection with an audible alarm.** At 95°C the box beeps and goes
  to full purge; if it cannot get back under 80°C within two minutes, one long
  beep and it powers itself off. It comes back with fan control latched off,
  beeping to say so — but still watching: 90°C in that state means full purge
  and power-off, never a reboot. A silent failure never stays silent.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/despotix/dell-mff-fan-controller/main/get.sh | sudo bash
```

The installer asks about each threshold, showing current values as defaults, so
re-running it is also how you reconfigure. It needs no git on the target
machine — it fetches a tarball with curl.

Non-interactive, taking defaults (or keeping an existing config):

```bash
curl -fsSL https://raw.githubusercontent.com/despotix/dell-mff-fan-controller/main/get.sh | sudo bash -s -- -y
```

From a clone:

```bash
sudo ./install.sh        # interactive
sudo ./install.sh -y     # defaults / keep existing config
sudo ./uninstall.sh      # remove; BIOS auto is restored when the service stops
```

Check it afterwards:

```bash
systemctl status optiplex-fan
journalctl -u optiplex-fan -f
```

## The problem

The stock BIOS holds the fan at ~1800 RPM even on a cold CPU (35-40°C), and
above that it steps rather than ramps. Two things are wrong with that:

- **Idle is louder than it needs to be.** The EC has a level that runs at
  ~1130 RPM and the BIOS never uses it.
- **The ramp is late.** Under a sustained 12-thread load the package settled at
  91°C while the fan was still turning 1783 of an available ~4800 RPM. Ten
  degrees of headroom, given away for nothing.

The exact idle RPM depends on your build (drives, RAM, case airflow all shift
the EC's baseline). On my own unit the stock curve idles at **2000+ RPM on a
cold CPU** — noticeably above the ~1800 RPM baseline above, and audible in a
quiet room. That gap between "cold CPU" and "loud fan" is the whole reason
the quiet level (~1130 RPM) exists: the BIOS never uses it, but the EC
supports it.

## What the hardware can actually do

Measured with `fan-diag.sh`, which installs nothing and always restores BIOS
control on exit:

A sweep of the whole range in steps of 25, at 35-40°C, twelve seconds per step:

| written | reads back | RPM | EC level |
|---|---|---|---|
| 0, 25, 50, 75, 100, 125, 150, 175 | 128 | ~1133 | 1 |
| 200, 225, 250, 255 | 255 | ~3270 | 2 |
| `pwm1_enable=2` (BIOS auto) | `No data available` | 1803 | — |

Writes to `pwm1` do work, but the SMM interface takes a level in `0..fan_max`
(here `fan_max=2`), not a 0-255 duty cycle. The driver converts with
`DIV_ROUND_CLOSEST(pwm * fan_max, 255)`, which puts the level-2 boundary at
**pwm 192**, not at 255.

Two things the sweep settles that arithmetic alone would get wrong:

- **Level 0 is unreachable.** Writing 0 reads back as 128, i.e. level 1 — the EC
  floors the request. There is no "slower than 1130 RPM" state.
- **Every write to `pwm1` kicks the fan into a short burst**, and that turns the
  top level into two usable states. Written once, it spikes to ~4260 RPM and
  settles to ~3250 within twelve seconds. Rewritten every two seconds, it holds
  4477-4773 indefinitely. Stop the rewrites and it falls back to ~3260 in twelve
  seconds. All of that was measured at a steady 32-38°C, so none of it is the EC
  reacting to heat — it is the write itself. Rewriting every 5 s only holds
  ~3720; every 10 s or slower is indistinguishable from leaving it alone.

So the reachable states are:

| state | RPM | how |
|---|---|---|
| quiet | ~1130 | level 1 |
| BIOS auto | 1800 idle, up to ~2900 loaded | `pwm1_enable=2` |
| boost | ~3250 | write 255 once, leave it |
| purge | ~4600 | write 255 every ~2 s |

**A smooth curve is still impossible** — these are four discrete points, not a
ramp — but they are four, not two, and the top two cost nothing but a write.

Out-of-range writes are accepted, not rejected: the driver clamps them. `1000`
becomes 255, and `-1` becomes 0 (which the EC then floors to level 1). Values
above 255 buy nothing, because level 2 is the firmware's ceiling. `pwm1_enable`
accepts only 1 and 2 — both `0` and `3` are rejected with `EINVAL`, so there is
no fourth mode hiding behind the hwmon convention.

Two more things worth knowing:

- Handing control back is safe. After `pwm1_enable=2` the EC returns to its own
  curve within ~10 s (measured: 2531 → 2126 → 1969 → 1847 → 1812 RPM).
- Entering manual mode makes the EC blip to full speed, so the daemon writes the
  target level immediately after `pwm1_enable=1` to keep the blip to a fraction
  of a second.

## How it works

| zone | condition | fan |
|---|---|---|
| quiet | below `T_QUIET - T_HYST` (55°C) | manual, ~1130 RPM |
| auto | `T_QUIET` (65°C) up to `T_BOOST` | `pwm1_enable=2`, stock BIOS curve |
| boost | `T_BOOST` (75°C) up to `T_PURGE` | pwm 255 written once, ~3250 RPM |
| purge | `T_PURGE` (85°C) and above | pwm 255 rewritten every cycle, ~4600 RPM |

The bottom zone removes the pointless idle noise. The top zone covers the late
ramp. The middle is left to the BIOS, where its curve behaves perfectly well.

Each zone releases below the point that entered it so the fan does not flap on a
boundary: `T_HYST` (10°C) for the quiet band, `T_HOT_HYST` (5°C) for the two top
bands. The top bands get their own knob deliberately — once the fan is up it
should stay up until the package has genuinely come down, not merely dipped a
degree.

The re-assert behaviour is what separates boost from purge, so it is deliberate
in both directions: in purge the daemon rewrites `pwm1` every cycle because that
is the whole mechanism, while in quiet and boost it rewrites **only** if the
readback has drifted off the expected level — an unnecessary write there would
kick the fan into the very burst those zones are avoiding.

**Expect cycling.** Under a sustained load the fan will alternate between zones,
because the levels are discrete. Raise `T_BOOST` and `T_PURGE` to trade
temperature for quiet; raise `T_HOT_HYST` for fewer, longer cycles.

Every failure path ends in BIOS auto: an `EXIT/TERM/INT/ABRT` trap restores it,
an unreadable temperature restores it, and if the loop wedges while the fan is
on a manual level, `WatchdogSec=30` restarts the service and the trap fires on
the way out.

## Language

The scripts speak English. Set `FANCTL_LANG` to one of the files in `lang/` to
change that:

```bash
FANCTL_LANG=uk sudo ./install.sh
curl -fsSL .../get.sh | sudo FANCTL_LANG=uk bash
```

Unset means English. A value with no matching `lang/<value>.sh` prints a warning
and falls back to English, and any message a translation leaves out keeps its
English text — a partial translation degrades gracefully instead of going blank.
It is deliberately not driven by `LANG`/`LC_ALL`: a Ukrainian locale is a
statement about dates and sorting, not a request to switch the installer's
language on someone reading the English docs.

To add a language, copy `lang/uk.sh`, translate the right-hand sides, and keep
every `%s` in the same order. The daemon itself always logs in English —
journal output is for grepping.

## Configuration

`/etc/optiplex-fan.conf`, written by the installer. After editing by hand, run
`sudo systemctl restart optiplex-fan`.

| key | default | meaning |
|---|---|---|
| `T_QUIET` | 65 | °C at which control is handed to the BIOS |
| `T_HYST` | 10 | °C below `T_QUIET` before returning to quiet |
| `T_BOOST` | 75 | °C from which pwm 255 is written once (~3250 RPM); `0` disables |
| `T_PURGE` | 85 | °C from which pwm 255 is rewritten every cycle (~4600 RPM); `0` disables |
| `T_HOT_HYST` | 5 | °C below `T_BOOST` / `T_PURGE` before releasing those zones |
| `QUIET_PWM` | 0 | level held while quiet; 0-175 all give ~1130 RPM, higher is clamped |
| `INTERVAL` | 2 | seconds between temperature checks (clamped to 1..10) |
| `T_PANIC` | 0 | °C that sounds the alarm and starts the deadline; `0` (default) disables it |
| `PANIC_RECOVER` | 80 | °C it has to get back down to |
| `PANIC_TIMEOUT` | 120 | seconds allowed to get there |
| `PANIC_ACTION` | poweroff | what to do if it does not: `poweroff` or `reboot` |
| `LATCH_T_PANIC` | 90 | °C that trips the brake while latched (fan control off, BIOS curve); `0` disables the watch |
| `LATCH_PANIC_RECOVER` | 80 | °C it has to get back down to in the latched state |
| `LATCH_PANIC_TIMEOUT` | 60 | seconds allowed before the latched state powers the machine off |
| `ALARM` | 1 | the audible alarm, boot check included; `0` disables all of it |
| `ALARM_DELAY` | 30 | seconds into the boot before the check |
| `ALARM_REPEATS` | 3 | how many times the whole signal is played |
| `ALARM_RETRIES` | 3 | attempts when a beep does not play at all (busy card) |
| `ALARM_BEEPS` / `ALARM_LONG_BEEPS` | 2 / 3 | beeps in the short and long signal |
| `ALARM_BACKEND` | auto | `auto`, `beep`, `console`, `alsa` or `none` |
| `ALARM_ALSA_DEV` | *(empty)* | PCM for the `alsa` backend; empty walks hardware devices, then `default` |
| `ALARM_ALSA_AMP` | 90 | tone amplitude, percent of full scale |
| `ALARM_ALSA_MIXER` | Master:Speaker:PCM:Line Out | controls raised for the beep, then restored |
| `ALARM_ALSA_LEVEL` | 80 | percent to raise them to |
| `ALARM_ALSA_RATE` | 16000 | sample rate of the generated tone |
| `ALARM_FREQ` | 1000 | pitch in Hz |
| `ALARM_LEN` / `ALARM_LONG_LEN` | 150 / 600 | short and long beep, in ms |
| `ALARM_GAP` | 150 | ms between beeps in a signal |
| `ALARM_REPEAT_GAP` | 5 | seconds between repeats |

## Measurements

Two runs of a 12-thread load on the same machine, differing only in what the
fan happened to be doing at the start:

| run | fan at start | package peak |
|---|---|---|
| fan crawling 1125 → 1783 | ~1780 RPM | **91°C** |
| fan already spun up | ~2570 RPM | **81°C** |

At 90°C the stock curve was holding 1783 RPM out of the ~4800 the fan sustains
at level 2 under load, and only reached 2600-2990 near the end of the eighth
minute.

With the three-zone daemon running (`T_HOT=87`, `T_HOT_HYST=10`), the same
`openssl` load peaked at **87°C** instead of 91°C. A typical cycle:

```
  sec   temp    RPM    zone
  241    87C   2207    BIOS   ← equilibrium of the stock curve
  244    86C   4850    MAX    ← threshold crossed, fan snaps to full
  253    83C   4761    MAX
  262    79C   4735    MAX
  266    77C   4716    MAX
  269    76C   4428    BIOS   ← below 77, handed back
```

Four such episodes over seven minutes of load, ~20 s each, each shedding about
ten degrees. Reproduce it on your own machine with:

```bash
sudo ./thermal-test.sh
```

On any model other than the 7080 Micro, start with `sudo ./pwm-sweep.sh`: the
level boundaries above were measured, not derived from a datasheet, and yours
may sit elsewhere.

## Overheat protection — off by default

Shipped disabled (`T_PANIC=0`); `install.sh` asks separately whether to enable
it. Shutting a server down is too blunt an action to inherit along with the
defaults.

One rule, with a deadline. When the package reaches `T_PANIC` (95°C) — the fan
is already flat out from the purge zone and still losing — the daemon:

1. **sounds the alarm** — two short beeps on the internal speaker, logged to the
   journal, and holds the fan in purge;
2. **waits** — `PANIC_TIMEOUT` (120 s) for the package to come back down to
   `PANIC_RECOVER` (80°C).

If it gets there, that is the end of it: the alarm was enough, normal zone
control resumes and work carries on. If the timeout runs out with the package
still above `PANIC_RECOVER`, the cooling has lost — one long beep, and
`PANIC_ACTION`.

**Powering off is the default**, not rebooting. A package that could not be
cooled while running will not be cooled by coming straight back up into the same
workload, and nothing drives the fan through POST at all. Set
`PANIC_ACTION=reboot` for a machine that has to come back on its own.

Either way the daemon latches first, by writing `/var/lib/optiplex-fan/panic`,
so a box that dies anywhere in the sequence still comes back in a known state.
It then hands the fan to the BIOS — a stalled shutdown must not leave it on a
manual level — and does `sync` before `systemctl <action> --force`.

**The latch is a file, not a disabled unit.** On the next boot
`optiplex-fan.service` still starts; it reads the flag, controls nothing, leaves
the fan on the stock BIOS curve, and beeps three long beeps to say so. That is
the whole reason it is a file: a disabled unit cannot announce itself. Once you
have dealt with the cause:

```bash
sudo rm /var/lib/optiplex-fan/panic
sudo systemctl restart optiplex-fan
```

**Latched does not mean unwatched.** The daemon keeps reading the package
temperature, and if it reaches `LATCH_T_PANIC` (90°C) — on the stock curve,
with every zone gone, exactly when the box has the least cooling help — it
purges the fan and gives it `LATCH_PANIC_TIMEOUT` (60 s) to get back under
`LATCH_PANIC_RECOVER` (80°C). If it does, the fan is handed back to the BIOS
and the watch resumes. If it does not, the machine is powered off — always,
whatever `PANIC_ACTION` says: this box already proved its workload cannot be
cooled, and a reboot would walk it straight back into that workload with even
the daemon's zones gone. `LATCH_T_PANIC=0` turns the watch off.

Pick the threshold from measurements, not intuition. On this machine a full load
reaches 91°C, so a brake at 85 would have fired 136 seconds into any serious
build or backup. 95°C leaves room above real workloads and still sits below
`crit=100`. The two-minute deadline is what keeps a spike from mattering: a
brief peak is back under 80°C long before it expires.

Note that `--force` skips the normal unmount; the `sync` before it reduces the
risk but does not remove it.

## The audible alarm

Everything above fails safe into the BIOS curve, correctly and completely
silently: the machine that most needed the daemon is exactly the one running the
stock curve — quiet idle gone, boost zone gone, brake gone — with nothing to say
so. `optiplex-fan-alarm.sh` is that missing sentence.

Two patterns, because they mean different things:

| what you hear | what it means |
|---|---|
| two short beeps | trouble now — the daemon is not running, or the brake has just tripped and is purging |
| three long beeps | fan control is **off** — the brake latched, or the daemon failed to start and is latched |
| nothing | the daemon is running normally |

Who makes them: the daemon calls the script directly (`--alert short|long`) for
the panic beeps and for the latched announcement it makes on the way up. On top
of that, `optiplex-fan-alarm.service` waits `ALARM_DELAY` seconds once per boot
and beeps if `optiplex-fan.service` is not running at all — the one case a dead
daemon cannot report on itself. It is a separate unit for exactly that reason.
A latched daemon is running, so the boot check stays quiet and lets the daemon
speak for itself instead of saying the same thing twice.

The signal plays `ALARM_REPEATS` times — three by default — and then the alarm
is done. It is meant to read as an error rather than a notification: short hard
beeps, near full amplitude. Nothing beeps while the daemon is working normally,
so a beep from this box always means something is wrong.

```bash
sudo optiplex-fan-alarm.sh --test          # beep now, whatever the daemon is doing
sudo optiplex-fan-alarm.sh --check         # state, latch and backend, no sound
sudo optiplex-fan-alarm.sh --now           # the boot check, without the delay
sudo optiplex-fan-alarm.sh --alert long    # play a specific pattern
```

**How it makes a sound.** `ALARM_BACKEND=auto` prefers `beep(1)` if it is
installed, then the kernel console bell — `ESC[10;<Hz>]` sets the pitch,
`ESC[11;<ms>]` the duration, `BEL` sounds it, and both are restored to the
kernel defaults afterwards. Both of those are the `pcspkr` driver, which Ubuntu
blacklists by default; a blacklist only suppresses loading by alias, so the
alarm asks for the module by name and gets it.

What `auto` cannot know is whether the other end of that line goes anywhere.
Plenty of machines — the 7080 Micro among them — load the driver, expose a "PC
Speaker" input device, and have no buzzer soldered on. Nothing in `/sys` says
so. That is what the installer's *did you hear it?* question is for: answer no
and it walks the sound card's outputs one at a time, and the one you confirm is
written to the config as `ALARM_BACKEND=alsa` plus `ALARM_ALSA_DEV`.

The `alsa` backend generates the sine itself — `awk` writes raw unsigned 8-bit
samples, `aplay` plays them — so it is the same pitch and length as the other
two backends rather than whatever `speaker-test` happens to emit. Unpinned, it
tries every hardware device `aplay -l` lists (which puts the analog codec, and
so an internal speaker, ahead of HDMI) and only then `default`; hardware first
because at boot this runs as root with no session for `default` to lean on,
where it may fail outright or, worse, succeed into a sleeping monitor.

If the card is busy for a moment — an audio server that has not suspended yet —
the beep fails and the remaining repeats retry it, five seconds apart. If the
box has no buzzer and no card at all, the alarm says so in the journal and stays
mute; `--check` reports `backend: none`, and the installer warns before you
commit to it.

Running `thermal-test.sh` or `pwm-sweep.sh` with the service stopped will not
set the boot check off: it happens once per boot, not continuously.

## Diagnostics

```bash
sudo ./fan-diag.sh
```

Walks the fan through every mode with RPM readings, and reports the
`FanCtrlOvrd` BIOS token if Dell Command | Configure is installed. It installs
nothing, and restores `pwm1_enable=2` on exit including on Ctrl+C.

## If the fan is ever stuck at full speed

`FanCtrlOvrd=Enabled` pins the fan to full speed in firmware, below the OS — no
daemon overrides it and a reboot will not clear it. It is not the default, but a
BIOS update, a CMOS reset, or a stray command can leave it there. One command
fixes it:

```bash
sudo /opt/dell/dcc/cctk --FanCtrlOvrd=Disabled
```

## Appendix: the BIOS token dead end

A separate line of investigation was whether the BIOS exposes more fan levels
than SMM does. It does not.

The `cctk` binary contains strings for a much richer set of fan tokens —
`FanSpdAutoLvlonCpuZone`, `FanSpdAutoLvlonPcieZone`, `FanSpdCpuMemZone`,
`FanSpdStorageZone` and others, i.e. per-thermal-zone minimum speeds. But
`cctk --help` only lists tokens actually present in *this* BIOS's SMBIOS table,
and of everything fan- or thermal-related exactly one survives:

```
FanCtrlOvrd — Controls the speed of the fan.
  Enabled  - The system fan is set to full speed.
  Disabled - The system run time sets the fan speed to optimal.
```

An always-full-speed switch, not a curve. Installing `cctk` on a modern
distribution is its own adventure: the Dell package is built for Ubuntu 18.04
and needs OpenSSL 1.1, which no longer exists in any repository. The libraries
can be lifted out of the `core18` snap:

```bash
sudo snap install core18
sudo cp /snap/core18/current/usr/lib/x86_64-linux-gnu/libssl.so.1.1    /opt/dell/dcc/
sudo cp /snap/core18/current/usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 /opt/dell/dcc/
sudo ldconfig
sudo /opt/dell/dcc/cctk --Version
```

`cctk` requires root even to read a value.

## License

MIT — see [LICENSE](LICENSE).

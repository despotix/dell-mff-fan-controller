#!/bin/bash
# Removes the fan-control service and restores stock BIOS fan control.
# Usage: sudo ./uninstall.sh
set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

MU_NEED_ROOT="Run with sudo: sudo ./uninstall.sh"
MU_REMOVED="Service removed. BIOS automatic fan control was restored when the service stopped."
MU_ALARM_REMOVED="Boot alarm removed too — nothing will beep at the next boot."
MU_CONF_KEPT="Config /etc/optiplex-fan.conf left in place — remove it by hand if you want: sudo rm /etc/optiplex-fan.conf"
MU_PANIC_KEPT="Panic-brake trace left in place: /var/lib/optiplex-fan/panic"
[ -r "$SRC_DIR/lang/load.sh" ] && . "$SRC_DIR/lang/load.sh"

if [ "$EUID" -ne 0 ]; then
    echo "$MU_NEED_ROOT" >&2
    exit 1
fi

ALARM_WAS=0
systemctl is-enabled --quiet optiplex-fan-alarm.service 2>/dev/null && ALARM_WAS=1

systemctl disable --now optiplex-fan.service 2>/dev/null || true
systemctl disable --now optiplex-fan-alarm.service 2>/dev/null || true
rm -f /etc/systemd/system/optiplex-fan.service
rm -f /etc/systemd/system/optiplex-fan-alarm.service
systemctl daemon-reload
rm -f /usr/local/sbin/optiplex-fan-control.sh
rm -f /usr/local/sbin/optiplex-fan-alarm.sh
rm -f /etc/modules-load.d/dell-smm-hwmon.conf

echo "$MU_REMOVED"
if [ "$ALARM_WAS" = 1 ]; then
    echo "$MU_ALARM_REMOVED"
fi
echo "$MU_CONF_KEPT"
if [ -f /var/lib/optiplex-fan/panic ]; then
    echo "$MU_PANIC_KEPT"
fi

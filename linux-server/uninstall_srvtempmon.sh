#!/bin/bash
#
# uninstall_srvtempmon.sh
#
# Removes the srvtempmon service, scripts, systemd unit, and runtime
# directory. Config (/etc/srvtempmon/config.txt) is kept by default so
# your tuned settings survive a reinstall. Pass --purge to remove it.
# History (/var/lib/srvtempmon/) is also kept by default; pass --purge
# to remove it.
#
# Usage:
#   sudo ./uninstall_srvtempmon.sh [--purge]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/srvtempmon"
DAEMON_DST="/usr/local/sbin/srvtempmon.sh"
STATS_DST="/usr/local/sbin/srvtempstats.sh"
STATS_LINK="/usr/local/sbin/srvtempstats"
SERVICE_FILE="/etc/systemd/system/srvtempmon.service"
RUN_DIR="/run/srvtempmon"
STATE_DIR="/var/lib/srvtempmon"
PURGE=0

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "run as root (sudo $SCRIPT_DIR/uninstall_srvtempmon.sh)" >&2
    exit 1
fi

if systemctl list-unit-files 2>/dev/null | grep -q '^srvtempmon.service'; then
    echo "==> stopping and disabling srvtempmon service"
    systemctl stop srvtempmon.service 2>/dev/null || true
    systemctl disable srvtempmon.service 2>/dev/null || true
fi

if [[ -f "$SERVICE_FILE" ]]; then
    echo "==> removing $SERVICE_FILE"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
fi

for path in "$DAEMON_DST" "$STATS_DST" "$STATS_LINK"; do
    if [[ -e "$path" || -L "$path" ]]; then
        echo "==> removing $path"
        rm -f "$path"
    fi
done

if [[ -d "$RUN_DIR" ]]; then
    echo "==> removing $RUN_DIR"
    rm -rf "$RUN_DIR"
fi

if [[ "$PURGE" -eq 1 ]]; then
    if [[ -d "$CONFIG_DIR" ]]; then
        echo "==> --purge set, removing $CONFIG_DIR"
        rm -rf "$CONFIG_DIR"
    fi
    if [[ -d "$STATE_DIR" ]]; then
        echo "==> --purge set, removing $STATE_DIR (history deleted)"
        rm -rf "$STATE_DIR"
    fi
else
    echo "==> keeping $CONFIG_DIR (pass --purge to remove)"
    echo "==> keeping $STATE_DIR/history.csv (pass --purge to remove)"
fi

echo "==> done"

#!/bin/bash
#
# uninstall_tempmon.sh
#
# Removes the tempmon service, daemon script, and systemd unit.
# Config file (/etc/tempmon/config.txt) is kept by default so a threshold
# you tuned survives a reinstall, pass --purge to remove it too.
#
# Usage:
#   sudo ./uninstall_tempmon.sh [--purge]

set -euo pipefail

CONFIG_DIR="/etc/tempmon"
DAEMON_DST="/usr/local/sbin/tempmon.sh"
SERVICE_FILE="/etc/systemd/system/tempmon.service"
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
    echo "run as root (sudo ./uninstall_tempmon.sh)" >&2
    exit 1
fi

if systemctl list-unit-files | grep -q '^tempmon.service'; then
    echo "==> stopping and disabling tempmon service"
    systemctl stop tempmon.service 2>/dev/null || true
    systemctl disable tempmon.service 2>/dev/null || true
fi

if [[ -f "$SERVICE_FILE" ]]; then
    echo "==> removing $SERVICE_FILE"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
fi

if [[ -f "$DAEMON_DST" ]]; then
    echo "==> removing $DAEMON_DST"
    rm -f "$DAEMON_DST"
fi

if [[ "$PURGE" -eq 1 ]]; then
    if [[ -d "$CONFIG_DIR" ]]; then
        echo "==> --purge set, removing $CONFIG_DIR"
        rm -rf "$CONFIG_DIR"
    fi
else
    echo "==> keeping $CONFIG_DIR (pass --purge to remove it)"
fi

echo "==> done"

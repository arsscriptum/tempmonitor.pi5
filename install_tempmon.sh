#!/bin/bash
#
# install_tempmon.sh
#
# Installs tempmon: a systemd service that polls board temperature and
# broadcasts a wall message to every logged-in tty when it crosses a
# threshold set in /etc/tempmon/config.txt.
#
# Installs:
#   /usr/local/sbin/tempmon.sh            daemon script
#   /usr/local/sbin/tempstats.sh          min/max/current/average reporter
#   /usr/local/sbin/tempstats             symlink to tempstats.sh
#   /etc/tempmon/config.txt               config, only written if missing
#   /etc/systemd/system/tempmon.service   systemd unit
#
# The service creates /run/tempmon (mode 0755) through the unit's
# RuntimeDirectory setting and keeps the current, minimum, maximum and
# average temperature there in world readable files, see tempmon.sh.
# systemd removes that directory when the service stops.
#
# Run as root (or with sudo). Must be run from the directory containing
# tempmon.sh and tempstats.sh.
#
# Usage:
#   sudo ./install_tempmon.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/tempmon"
CONFIG_FILE="$CONFIG_DIR/config.txt"
DAEMON_SRC="$SCRIPT_DIR/tempmon.sh"
DAEMON_DST="/usr/local/sbin/tempmon.sh"
STATS_SRC="$SCRIPT_DIR/tempstats.sh"
STATS_DST="/usr/local/sbin/tempstats.sh"
STATS_LINK="/usr/local/sbin/tempstats"
SERVICE_FILE="/etc/systemd/system/tempmon.service"
RUN_DIR="/run/tempmon"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "run as root (sudo ./install_tempmon.sh)" >&2
    exit 1
fi

if [[ ! -f "$DAEMON_SRC" ]]; then
    echo "tempmon.sh not found next to this script ($DAEMON_SRC)" >&2
    exit 1
fi

if [[ ! -f "$STATS_SRC" ]]; then
    echo "tempstats.sh not found next to this script ($STATS_SRC)" >&2
    exit 1
fi

for src in "$DAEMON_SRC" "$STATS_SRC"; do
    if ! bash -n "$src"; then
        echo "$src has a syntax error, refusing to install" >&2
        exit 1
    fi
done

if ! command -v wall >/dev/null 2>&1; then
    echo "==> wall not found, installing bsdutils"
    apt-get update
    apt-get install -y bsdutils
fi

echo "==> installing daemon script to $DAEMON_DST"
install -m 0755 "$DAEMON_SRC" "$DAEMON_DST"

echo "==> installing stats script to $STATS_DST"
install -m 0755 "$STATS_SRC" "$STATS_DST"
ln -sf "$STATS_DST" "$STATS_LINK"

echo "==> creating $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "==> $CONFIG_FILE already exists, leaving it untouched"
else
    echo "==> writing default $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<'EOF'
# tempmon config
#
# THRESHOLD_C           temperature in Celsius that triggers a wall broadcast
# POLL_INTERVAL_SEC     how often to check the temperature, in seconds
# REPEAT_INTERVAL_SEC   minimum seconds between repeat alerts while the
#                       board stays above threshold
# RUN_DIR               where the run files (temp_cur, temp_min, temp_max,
#                       temp_avg, temp_state) are written, read them with
#                       tempstats. Leave it at the default unless you have
#                       a reason to move them, the systemd unit creates
#                       /run/tempmon for the service.
#
# Edited values take effect on the next poll cycle, no restart needed.

THRESHOLD_C=75
POLL_INTERVAL_SEC=5
REPEAT_INTERVAL_SEC=300
RUN_DIR=/run/tempmon
EOF
    chmod 0644 "$CONFIG_FILE"
fi

echo "==> writing $SERVICE_FILE"
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Board temperature monitor with wall broadcast on threshold
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/tempmon.sh
Restart=on-failure
RestartSec=5

# Creates /run/tempmon owned by root, mode 0755, so the temperature run
# files inside it are readable by every user. Removed when the service stops.
RuntimeDirectory=tempmon
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

echo "==> reloading systemd, enabling and starting tempmon"
systemctl daemon-reload
systemctl enable tempmon.service
systemctl restart tempmon.service

echo "==> waiting for the first run files"
for _ in $(seq 1 20); do
    [[ -f "$RUN_DIR/temp_cur" ]] && break
    sleep 1
done

if [[ -f "$RUN_DIR/temp_cur" ]]; then
    echo "==> run files present in $RUN_DIR"
    ls -l "$RUN_DIR"
else
    echo "==> WARNING: no run files in $RUN_DIR yet, check: journalctl -u tempmon -n 30" >&2
fi

echo "==> done"
echo "config:  $CONFIG_FILE"
echo "stats:   tempstats            (also --short, --json, --watch, --reset)"
echo "files:   $RUN_DIR/{temp_cur,temp_min,temp_max,temp_avg,temp_state}"
echo "status:  systemctl status tempmon"
echo "logs:    journalctl -u tempmon -f"

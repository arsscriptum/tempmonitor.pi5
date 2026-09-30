#!/bin/bash
#
# install_tempmon.sh
#
# Installs tempmon: a systemd service that polls board temperature and
# broadcasts a wall message to every logged-in tty when it crosses a
# threshold set in /etc/tempmon/config.txt.
#
# Installs:
#   /usr/local/sbin/tempmon.sh       daemon script
#   /etc/tempmon/config.txt          config, only written if missing
#   /etc/systemd/system/tempmon.service   systemd unit
#
# Run as root (or with sudo). Must be run from the directory containing
# tempmon.sh.
#
# Usage:
#   sudo ./install_tempmon.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/tempmon"
CONFIG_FILE="$CONFIG_DIR/config.txt"
DAEMON_SRC="$SCRIPT_DIR/tempmon.sh"
DAEMON_DST="/usr/local/sbin/tempmon.sh"
SERVICE_FILE="/etc/systemd/system/tempmon.service"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "run as root (sudo ./install_tempmon.sh)" >&2
    exit 1
fi

if [[ ! -f "$DAEMON_SRC" ]]; then
    echo "tempmon.sh not found next to this script ($DAEMON_SRC)" >&2
    exit 1
fi

if ! command -v wall >/dev/null 2>&1; then
    echo "==> wall not found, installing bsdutils"
    apt-get update
    apt-get install -y bsdutils
fi

echo "==> installing daemon script to $DAEMON_DST"
install -m 0755 "$DAEMON_SRC" "$DAEMON_DST"

echo "==> creating $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "==> $CONFIG_FILE already exists, leaving it untouched"
else
    echo "==> writing default $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<'EOF'
# tempmon config
#
# THRESHOLD_C          temperature in Celsius that triggers a wall broadcast
# POLL_INTERVAL_SEC     how often to check the temperature, in seconds
# REPEAT_INTERVAL_SEC   minimum seconds between repeat alerts while the
#                       board stays above threshold
#
# Edited values take effect on the next poll cycle, no restart needed.

THRESHOLD_C=75
POLL_INTERVAL_SEC=5
REPEAT_INTERVAL_SEC=300
EOF
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

[Install]
WantedBy=multi-user.target
EOF

echo "==> reloading systemd, enabling and starting tempmon"
systemctl daemon-reload
systemctl enable tempmon.service
systemctl restart tempmon.service

echo "==> done"
echo "config:  $CONFIG_FILE"
echo "status:  systemctl status tempmon"
echo "logs:    journalctl -u tempmon -f"

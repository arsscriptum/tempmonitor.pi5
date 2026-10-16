#!/bin/bash
#
# install_srvtempmon.sh
#
# Installs srvtempmon: a systemd service that polls CPU temperature on a Linux
# server using lm-sensors and raises an alert when it crosses a threshold.
# Temperature history is stored in /var/lib/srvtempmon/history.csv and can
# be viewed as an ASCII graph with: srvtempstats --graph
#
# Installs:
#   /usr/local/sbin/srvtempmon.sh         daemon script
#   /usr/local/sbin/srvtempstats.sh       stats and graph reporter
#   /usr/local/sbin/srvtempstats          symlink to srvtempstats.sh
#   /etc/srvtempmon/config.txt            config (written only if missing)
#   /etc/systemd/system/srvtempmon.service  systemd unit
#
# The unit creates:
#   /run/srvtempmon          (RuntimeDirectory, tmpfs, mode 0755, removed on stop)
#   /var/lib/srvtempmon      (StateDirectory, persistent, mode 0750)
#
# Run as root (or with sudo). Must be run from the directory that contains
# srvtempmon.sh and srvtempstats.sh.
#
# Usage:
#   sudo ./install_srvtempmon.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/srvtempmon"
CONFIG_FILE="$CONFIG_DIR/config.txt"
DAEMON_SRC="$SCRIPT_DIR/srvtempmon.sh"
DAEMON_DST="/usr/local/sbin/srvtempmon.sh"
STATS_SRC="$SCRIPT_DIR/srvtempstats.sh"
STATS_DST="/usr/local/sbin/srvtempstats.sh"
STATS_LINK="/usr/local/sbin/srvtempstats"
CONFIG_SRC="$SCRIPT_DIR/config.txt.example"
SERVICE_FILE="/etc/systemd/system/srvtempmon.service"
RUN_DIR="/run/srvtempmon"
STATE_DIR="/var/lib/srvtempmon"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "run as root (sudo ./install_srvtempmon.sh)" >&2
    exit 1
fi

if [[ ! -f "$DAEMON_SRC" ]]; then
    echo "srvtempmon.sh not found next to this script ($DAEMON_SRC)" >&2
    exit 1
fi

if [[ ! -f "$STATS_SRC" ]]; then
    echo "srvtempstats.sh not found next to this script ($STATS_SRC)" >&2
    exit 1
fi

for src in "$DAEMON_SRC" "$STATS_SRC"; do
    if ! bash -n "$src"; then
        echo "$src has a syntax error, refusing to install" >&2
        exit 1
    fi
done

# lm-sensors is required for hardware temperature reading.
if ! command -v sensors >/dev/null 2>&1; then
    echo "==> sensors(1) not found, installing lm-sensors"
    apt-get update -qq
    apt-get install -y lm-sensors
fi

# Run sensors-detect non-interactively to load kernel modules, if not already
# done. This may not find everything without interactive prompting, but covers
# the common case of x86 systems with coretemp.
if ! sensors >/dev/null 2>&1; then
    echo "==> running sensors-detect --auto to load kernel modules"
    sensors-detect --auto >/dev/null 2>&1 || true
fi

# notify-send is optional; only needed for NOTIFICATION_TYPE 2 and 3.
if ! command -v notify-send >/dev/null 2>&1; then
    echo "==> notify-send not found (needed for NOTIFICATION_TYPE 2 and 3)"
    echo "    install with: apt-get install -y libnotify-bin"
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
    for key in SENSOR_CHIP SENSOR_FEATURE HISTORY_FILE HISTORY_DAYS; do
        if ! grep -qE "^[[:space:]]*$key[[:space:]]*=" "$CONFIG_FILE"; then
            echo "    note: $key is not set, srvtempmon will use its default"
        fi
    done
elif [[ -f "$CONFIG_SRC" ]]; then
    echo "==> installing default $CONFIG_FILE from config.txt.example"
    install -m 0644 "$CONFIG_SRC" "$CONFIG_FILE"
else
    echo "==> writing default $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<'EOF'
# srvtempmon config
THRESHOLD_C=80
POLL_INTERVAL_SEC=5
REPEAT_INTERVAL_SEC=300
RUN_DIR=/run/srvtempmon
NOTIFICATION_TYPE=1
NOTIFICATION_QTNOTIFIER=/bin/qtnotifier
SENSOR_CHIP=
SENSOR_FEATURE=
HISTORY_FILE=/var/lib/srvtempmon/history.csv
HISTORY_DAYS=7
EOF
    chmod 0644 "$CONFIG_FILE"
fi

echo "==> writing $SERVICE_FILE"
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Linux server CPU temperature monitor with threshold notification
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/srvtempmon.sh
Restart=on-failure
RestartSec=5

# /run/srvtempmon: tmpfs, world readable, removed when service stops.
RuntimeDirectory=srvtempmon
RuntimeDirectoryMode=0755

# /var/lib/srvtempmon: persistent storage for history.csv.
StateDirectory=srvtempmon
StateDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

echo "==> reloading systemd, enabling and starting srvtempmon"
systemctl daemon-reload
systemctl enable srvtempmon.service
systemctl restart srvtempmon.service

echo "==> waiting for the first run files"
for _ in $(seq 1 20); do
    [[ -f "$RUN_DIR/temp_cur" ]] && break
    sleep 1
done

if [[ -f "$RUN_DIR/temp_cur" ]]; then
    echo "==> run files present in $RUN_DIR"
    ls -l "$RUN_DIR"
else
    echo "==> WARNING: no run files in $RUN_DIR yet" >&2
    echo "    check: journalctl -u srvtempmon -n 30" >&2
fi

echo
echo "==> done"
echo "config:   $CONFIG_FILE"
echo "sensors:  sensors                          (list available sensors)"
echo "select:   SENSOR_CHIP / SENSOR_FEATURE in $CONFIG_FILE"
echo "test:     sudo srvtempmon.sh --test-notify"
echo "stats:    srvtempstats                     (also --short, --json, --watch)"
echo "graph:    srvtempstats --graph             (last 60m, or --graph MINUTES)"
echo "history:  srvtempstats --history           (raw CSV dump)"
echo "files:    $RUN_DIR/{temp_cur,temp_min,temp_max,temp_avg,temp_state}"
echo "history:  $STATE_DIR/history.csv"
echo "status:   systemctl status srvtempmon"
echo "logs:     journalctl -u srvtempmon -f"

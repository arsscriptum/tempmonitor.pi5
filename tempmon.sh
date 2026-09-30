#!/bin/bash
#
# tempmon.sh
#
# Polls board temperature and broadcasts a wall message to every logged-in
# tty when it crosses the threshold set in /etc/tempmon/config.txt, the same
# way shutdown/reboot broadcasts a warning to all terminals. Meant to run as
# a systemd service (tempmon.service), installed by install_tempmon.sh, but
# also runs standalone in the foreground for testing.
#
# Config file format (/etc/tempmon/config.txt), key=value, one per line,
# blank lines and lines starting with # ignored:
#
#   THRESHOLD_C=75
#   POLL_INTERVAL_SEC=5
#   REPEAT_INTERVAL_SEC=300
#
# THRESHOLD_C          temperature in Celsius that triggers a broadcast
# POLL_INTERVAL_SEC     how often to check the temperature
# REPEAT_INTERVAL_SEC   minimum seconds between repeat alerts while the
#                       board stays above threshold, prevents spamming a
#                       wall message on every poll cycle
#
# Config is re-read every poll cycle, so editing the threshold live takes
# effect without restarting the service.

set -uo pipefail

CONFIG_FILE="/etc/tempmon/config.txt"
DEFAULT_THRESHOLD_C=75
DEFAULT_POLL_INTERVAL_SEC=5
DEFAULT_REPEAT_INTERVAL_SEC=300

log() {
    echo "tempmon: $1"
}

read_config() {
    local line
    local key
    local value

    THRESHOLD_C="$DEFAULT_THRESHOLD_C"
    POLL_INTERVAL_SEC="$DEFAULT_POLL_INTERVAL_SEC"
    REPEAT_INTERVAL_SEC="$DEFAULT_REPEAT_INTERVAL_SEC"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "config file $CONFIG_FILE not found, using defaults"
        return
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | xargs)"
        [[ -z "$line" ]] && continue

        key="${line%%=*}"
        value="${line#*=}"
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"

        case "$key" in
            THRESHOLD_C)        THRESHOLD_C="$value" ;;
            POLL_INTERVAL_SEC)  POLL_INTERVAL_SEC="$value" ;;
            REPEAT_INTERVAL_SEC) REPEAT_INTERVAL_SEC="$value" ;;
        esac
    done < "$CONFIG_FILE"
}

get_temp_c() {
    local raw

    if command -v vcgencmd >/dev/null 2>&1; then
        raw="$(vcgencmd measure_temp 2>/dev/null)"
        if [[ "$raw" =~ temp=([0-9.]+) ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        raw="$(cat /sys/class/thermal/thermal_zone0/temp)"
        awk -v milli="$raw" 'BEGIN { printf "%.1f", milli / 1000.0 }'
        return 0
    fi

    return 1
}

temp_ge_threshold() {
    local temp="$1"
    local threshold="$2"
    awk -v t="$temp" -v th="$threshold" 'BEGIN { exit !(t >= th) }'
}

broadcast() {
    local message="$1"

    if command -v wall >/dev/null 2>&1; then
        wall "$message"
    else
        log "wall not available, message not broadcast: $message"
    fi
}

main() {
    local temp
    local now
    local last_alert_epoch
    local alerted

    last_alert_epoch=0
    alerted=0

    log "starting, config file $CONFIG_FILE"

    while true; do
        read_config

        temp="$(get_temp_c)"
        if [[ -z "$temp" ]]; then
            log "unable to read temperature, retrying in ${POLL_INTERVAL_SEC}s"
            sleep "$POLL_INTERVAL_SEC"
            continue
        fi

        now="$(date +%s)"

        if temp_ge_threshold "$temp" "$THRESHOLD_C"; then
            if [[ "$alerted" -eq 0 ]] || (( now - last_alert_epoch >= REPEAT_INTERVAL_SEC )); then
                broadcast "$(printf 'TEMPERATURE WARNING on %s: %s C, threshold %s C exceeded at %s' "$(hostname)" "$temp" "$THRESHOLD_C" "$(date '+%Y-%m-%d %H:%M:%S')")"
                log "alert sent, temp=${temp}C threshold=${THRESHOLD_C}C"
                last_alert_epoch="$now"
                alerted=1
            fi
        else
            if [[ "$alerted" -eq 1 ]]; then
                broadcast "$(printf 'TEMPERATURE NORMAL on %s: %s C, back under threshold %s C at %s' "$(hostname)" "$temp" "$THRESHOLD_C" "$(date '+%Y-%m-%d %H:%M:%S')")"
                log "recovered, temp=${temp}C threshold=${THRESHOLD_C}C"
            fi
            alerted=0
        fi

        sleep "$POLL_INTERVAL_SEC"
    done
}

main

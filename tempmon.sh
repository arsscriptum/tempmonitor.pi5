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
#   RUN_DIR=/run/tempmon
#
# THRESHOLD_C           temperature in Celsius that triggers a broadcast
# POLL_INTERVAL_SEC     how often to check the temperature
# REPEAT_INTERVAL_SEC   minimum seconds between repeat alerts while the
#                       board stays above threshold, prevents spamming a
#                       wall message on every poll cycle
# RUN_DIR               directory for the runtime files below
#
# Config is re-read every poll cycle, so editing the threshold live takes
# effect without restarting the service. Values that are not valid numbers
# are ignored and the built-in default is used instead.
#
# Runtime (run) files, rewritten every poll cycle, world readable (0644):
#
#   $RUN_DIR/temp_cur     current temperature, Celsius, one decimal
#   $RUN_DIR/temp_min     lowest temperature seen this window
#   $RUN_DIR/temp_max     highest temperature seen this window
#   $RUN_DIR/temp_avg     mean of every sample this window
#   $RUN_DIR/temp_state   key=value details (sample count, epochs, state)
#
# Each file holds a single bare number and a newline, so it is trivially
# consumable: cat /run/tempmon/temp_cur. Writes are atomic (write to a
# temp file, then rename), so a reader never sees a partial value.
#
# Read them with tempstats.sh, which formats all of the above.
#
# Delete temp_min (tempstats.sh --reset does this) to restart the min/max/
# average window, the daemon reseeds from the next sample.
#
# Set TEMPMON_RUN_DIR in the environment to override RUN_DIR, useful for
# running the daemon as a normal user during testing:
#
#   TEMPMON_RUN_DIR=/tmp/tempmon ./tempmon.sh

set -uo pipefail

CONFIG_FILE="/etc/tempmon/config.txt"
DEFAULT_THRESHOLD_C=75
DEFAULT_POLL_INTERVAL_SEC=5
DEFAULT_REPEAT_INTERVAL_SEC=300
DEFAULT_RUN_DIR="/run/tempmon"

# Accumulators for the current min/max/average window.
STAT_SAMPLES=0
STAT_SUM=0
STAT_MIN=""
STAT_MAX=""
STAT_AVG=""
STAT_MIN_EPOCH=0
STAT_MAX_EPOCH=0
STAT_START_EPOCH=0
RUN_DIR_READY=""

log() {
    echo "tempmon: $1"
}

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

read_config() {
    local line
    local key
    local value

    THRESHOLD_C="$DEFAULT_THRESHOLD_C"
    POLL_INTERVAL_SEC="$DEFAULT_POLL_INTERVAL_SEC"
    REPEAT_INTERVAL_SEC="$DEFAULT_REPEAT_INTERVAL_SEC"
    RUN_DIR="$DEFAULT_RUN_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="$(echo "$line" | xargs)"
            [[ -z "$line" ]] && continue

            key="${line%%=*}"
            value="${line#*=}"
            key="$(echo "$key" | xargs)"
            value="$(echo "$value" | xargs)"

            case "$key" in
                THRESHOLD_C)
                    is_number "$value" && THRESHOLD_C="$value" ;;
                POLL_INTERVAL_SEC)
                    is_number "$value" && (( $(printf '%.0f' "$value") > 0 )) \
                        && POLL_INTERVAL_SEC="$value" ;;
                REPEAT_INTERVAL_SEC)
                    is_number "$value" && REPEAT_INTERVAL_SEC="$value" ;;
                RUN_DIR)
                    [[ "$value" == /* ]] && RUN_DIR="$value" ;;
            esac
        done < "$CONFIG_FILE"
    else
        log "config file $CONFIG_FILE not found, using defaults"
    fi

    # Environment override wins, for standalone testing as a normal user.
    if [[ -n "${TEMPMON_RUN_DIR:-}" ]]; then
        RUN_DIR="$TEMPMON_RUN_DIR"
    fi

    CUR_FILE="$RUN_DIR/temp_cur"
    MIN_FILE="$RUN_DIR/temp_min"
    MAX_FILE="$RUN_DIR/temp_max"
    AVG_FILE="$RUN_DIR/temp_avg"
    STATE_FILE="$RUN_DIR/temp_state"
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
        [[ "$raw" =~ ^-?[0-9]+$ ]] || return 1
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

# Create the run directory, world readable so any user can read the stats.
# Non-fatal: monitoring still works if it cannot be created, we just log once.
ensure_run_dir() {
    if [[ "$RUN_DIR_READY" == "$RUN_DIR" ]]; then
        return 0
    fi

    if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
        log "cannot create run directory $RUN_DIR, run files disabled"
        return 1
    fi

    chmod 0755 "$RUN_DIR" 2>/dev/null || true
    RUN_DIR_READY="$RUN_DIR"
    log "run files in $RUN_DIR (temp_cur, temp_min, temp_max, temp_avg, temp_state)"
    return 0
}

# Atomic, world readable write: temp file in the same directory, then rename.
write_run_file() {
    local path="$1"
    local content="$2"
    local tmp="${path}.tmp.$$"

    if ! printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi

    chmod 0644 "$tmp" 2>/dev/null || true

    if ! mv -f "$tmp" "$path" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi

    return 0
}

reset_stats() {
    local now="$1"

    STAT_SAMPLES=0
    STAT_SUM=0
    STAT_MIN=""
    STAT_MAX=""
    STAT_AVG=""
    STAT_MIN_EPOCH=0
    STAT_MAX_EPOCH=0
    STAT_START_EPOCH="$now"
}

# Restore accumulators from a previous run so a service restart does not
# throw away the window. Anything missing or malformed starts a fresh window.
load_stats() {
    local now="$1"
    local line key value
    local samples="" sum="" start="" min_epoch="" max_epoch=""

    reset_stats "$now"

    [[ -r "$STATE_FILE" && -r "$MIN_FILE" && -r "$MAX_FILE" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            SAMPLES)    samples="$value" ;;
            SUM_C)      sum="$value" ;;
            START_EPOCH) start="$value" ;;
            MIN_EPOCH)  min_epoch="$value" ;;
            MAX_EPOCH)  max_epoch="$value" ;;
        esac
    done < "$STATE_FILE"

    local min max
    min="$(tr -d '[:space:]' < "$MIN_FILE")"
    max="$(tr -d '[:space:]' < "$MAX_FILE")"

    is_number "$min" || return 0
    is_number "$max" || return 0
    is_number "$sum" || return 0
    [[ "$samples" =~ ^[0-9]+$ ]] || return 0
    (( samples > 0 )) || return 0
    [[ "$start" =~ ^[0-9]+$ ]] || start="$now"
    [[ "$min_epoch" =~ ^[0-9]+$ ]] || min_epoch="$start"
    [[ "$max_epoch" =~ ^[0-9]+$ ]] || max_epoch="$start"

    STAT_SAMPLES="$samples"
    STAT_SUM="$sum"
    STAT_MIN="$min"
    STAT_MAX="$max"
    STAT_MIN_EPOCH="$min_epoch"
    STAT_MAX_EPOCH="$max_epoch"
    STAT_START_EPOCH="$start"

    log "resumed stats window: ${STAT_SAMPLES} samples, min ${STAT_MIN}C, max ${STAT_MAX}C"
}

# One awk call per poll cycle does the whole float update.
update_stats() {
    local temp="$1"
    local now="$2"
    local out new_min new_max

    out="$(awk -v t="$temp" -v sum="$STAT_SUM" -v mn="${STAT_MIN:-0}" \
               -v mx="${STAT_MAX:-0}" -v n="$STAT_SAMPLES" 'BEGIN {
        first = (n == 0)
        sum += t
        n += 1
        if (first || t < mn) { mn = t; newmin = 1 }
        if (first || t > mx) { mx = t; newmax = 1 }
        printf "%.4f %.1f %.1f %d %.2f %d %d", sum, mn, mx, n, sum / n, newmin + 0, newmax + 0
    }')"

    read -r STAT_SUM STAT_MIN STAT_MAX STAT_SAMPLES STAT_AVG new_min new_max <<< "$out"

    [[ "$new_min" == "1" ]] && STAT_MIN_EPOCH="$now"
    [[ "$new_max" == "1" ]] && STAT_MAX_EPOCH="$now"

    return 0
}

write_stats() {
    local temp="$1"
    local now="$2"
    local alerted="$3"

    ensure_run_dir || return 1

    write_run_file "$CUR_FILE" "$temp"
    write_run_file "$MIN_FILE" "$STAT_MIN"
    write_run_file "$MAX_FILE" "$STAT_MAX"
    write_run_file "$AVG_FILE" "$STAT_AVG"

    write_run_file "$STATE_FILE" "\
CUR_C=$temp
MIN_C=$STAT_MIN
MAX_C=$STAT_MAX
AVG_C=$STAT_AVG
SAMPLES=$STAT_SAMPLES
SUM_C=$STAT_SUM
START_EPOCH=$STAT_START_EPOCH
UPDATED_EPOCH=$now
MIN_EPOCH=$STAT_MIN_EPOCH
MAX_EPOCH=$STAT_MAX_EPOCH
THRESHOLD_C=$THRESHOLD_C
POLL_INTERVAL_SEC=$POLL_INTERVAL_SEC
ALERTED=$alerted
HOSTNAME=$(hostname)
PID=$$"
}

broadcast() {
    local message="$1"

    if command -v wall >/dev/null 2>&1; then
        wall "$message"
    else
        log "wall not available, message not broadcast: $message"
    fi
}

cleanup() {
    log "stopping"
    exit 0
}

main() {
    local temp
    local now
    local last_alert_epoch
    local alerted

    last_alert_epoch=0
    alerted=0

    trap cleanup INT TERM

    log "starting, config file $CONFIG_FILE"

    read_config
    ensure_run_dir
    load_stats "$(date +%s)"

    while true; do
        read_config

        temp="$(get_temp_c)"
        if [[ -z "$temp" ]]; then
            log "unable to read temperature, retrying in ${POLL_INTERVAL_SEC}s"
            sleep "$POLL_INTERVAL_SEC"
            continue
        fi

        now="$(date +%s)"

        # tempstats.sh --reset removes the run files, that restarts the window.
        if [[ "$STAT_SAMPLES" -gt 0 && ! -f "$MIN_FILE" ]]; then
            log "run files cleared, starting a new min/max/average window"
            reset_stats "$now"
        fi

        update_stats "$temp" "$now"

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

        write_stats "$temp" "$now" "$alerted"

        sleep "$POLL_INTERVAL_SEC"
    done
}

main

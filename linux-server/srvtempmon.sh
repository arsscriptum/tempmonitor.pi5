#!/bin/bash
#
# srvtempmon.sh
#
# Polls CPU temperature on a Linux server using lm-sensors and raises an
# alert when it crosses the threshold set in /etc/srvtempmon/config.txt.
# Temperature readings are appended to a history file so that srvtempstats
# --graph can display a time-series chart.
#
# Falls back to /sys/class/thermal/thermal_zone0/temp when sensors(1) is not
# available (some virtualised hosts, containers, etc.).
#
# Config file (/etc/srvtempmon/config.txt), key=value, one per line,
# blank lines and lines starting with # ignored:
#
#   THRESHOLD_C=80
#   POLL_INTERVAL_SEC=5
#   REPEAT_INTERVAL_SEC=300
#   RUN_DIR=/run/srvtempmon
#   NOTIFICATION_TYPE=1
#   NOTIFICATION_QTNOTIFIER=/bin/qtnotifier
#   SENSOR_CHIP=
#   SENSOR_FEATURE=
#   HISTORY_FILE=/var/lib/srvtempmon/history.csv
#   HISTORY_DAYS=7
#
# THRESHOLD_C           temperature in Celsius that triggers an alert
# POLL_INTERVAL_SEC     how often to check the temperature
# REPEAT_INTERVAL_SEC   minimum seconds between repeat alerts while the
#                       server stays above threshold
# RUN_DIR               directory for the runtime files (temp_cur, temp_min,
#                       temp_max, temp_avg, temp_state), world readable (0644)
#
# NOTIFICATION_TYPE     where alerts go. Two bit field, bit 0 is tty, bit 1
#                       is desktop:
#                         0  no notification, log only
#                         1  text message on every tty
#                         2  desktop notification in every graphical session
#                         3  both
#
# NOTIFICATION_QTNOTIFIER
#                       absolute path to a desktop notifier binary, called as:
#                         <notifier> "<title>" "<message>"
#                       Falls back to notify-send if not executable.
#
# SENSOR_CHIP           lm-sensors chip name, e.g. coretemp-isa-0000.
#                       Leave empty for auto-detection (highest reading across
#                       all chips). Run: sensors -u  to list chip names.
#
# SENSOR_FEATURE        Feature label within the chip, e.g. "Package id 0".
#                       Leave empty to auto-select the highest reading.
#                       Run: sensors  to list feature labels.
#
# HISTORY_FILE          Path to the history CSV (epoch:temp_c:label lines).
#                       Must survive reboots for meaningful graphs.
#                       Default: /var/lib/srvtempmon/history.csv
#
# HISTORY_DAYS          How many days of history to keep. Default: 7.
#                       Old entries are pruned at startup and every
#                       HISTORY_PRUNE_EVERY samples thereafter.
#
# Config is re-read every poll cycle; edits take effect without restart.
#
# Runtime files (rewritten each poll cycle, mode 0644):
#   $RUN_DIR/temp_cur     current temperature, Celsius, one decimal
#   $RUN_DIR/temp_min     lowest temperature seen this window
#   $RUN_DIR/temp_max     highest temperature seen this window
#   $RUN_DIR/temp_avg     mean of every sample this window
#   $RUN_DIR/temp_state   key=value details (sample count, epochs, state)
#
# Delete temp_min (or run srvtempstats --reset) to restart the window.
#
# Environment overrides:
#   SRVTEMPMON_CONFIG    read this config file instead of the default
#   SRVTEMPMON_RUN_DIR   use this run directory instead of RUN_DIR
#
# Usage:
#   srvtempmon.sh                 poll forever (the service entry point)
#   srvtempmon.sh --test-notify   send one test alert and exit
#   srvtempmon.sh --help

set -uo pipefail

CONFIG_FILE="${SRVTEMPMON_CONFIG:-/etc/srvtempmon/config.txt}"

DEFAULT_THRESHOLD_C=80
DEFAULT_POLL_INTERVAL_SEC=5
DEFAULT_REPEAT_INTERVAL_SEC=300
DEFAULT_NOTIFICATION_TYPE=1
DEFAULT_NOTIFICATION_QTNOTIFIER=/bin/qtnotifier
DEFAULT_RUN_DIR="/run/srvtempmon"
DEFAULT_SENSOR_CHIP=""
DEFAULT_SENSOR_FEATURE=""
DEFAULT_HISTORY_FILE="/var/lib/srvtempmon/history.csv"
DEFAULT_HISTORY_DAYS=7

NOTIFY_BIT_TTY=1
NOTIFY_BIT_GUI=2

STAT_SAMPLES=0
STAT_SUM=0
STAT_MIN=""
STAT_MAX=""
STAT_AVG=""
STAT_MIN_EPOCH=0
STAT_MAX_EPOCH=0
STAT_START_EPOCH=0
RUN_DIR_READY=""

ALERTED=0
LAST_ALERT_EPOCH=0
GUI_WARNED=0

HISTORY_DIR_READY=""
PRUNE_COUNTER=0
PRUNE_EVERY=1000

# Label of the sensor that produced the last reading; set by get_temp_c.
SENSOR_LABEL=""

HOST_NAME="$(hostname 2>/dev/null || echo unknown)"

log() {
    echo "srvtempmon: $1"
}

is_number() {
    [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

read_config() {
    local line key value

    THRESHOLD_C="$DEFAULT_THRESHOLD_C"
    POLL_INTERVAL_SEC="$DEFAULT_POLL_INTERVAL_SEC"
    REPEAT_INTERVAL_SEC="$DEFAULT_REPEAT_INTERVAL_SEC"
    RUN_DIR="$DEFAULT_RUN_DIR"
    NOTIFICATION_TYPE="$DEFAULT_NOTIFICATION_TYPE"
    NOTIFICATION_QTNOTIFIER="$DEFAULT_NOTIFICATION_QTNOTIFIER"
    SENSOR_CHIP="$DEFAULT_SENSOR_CHIP"
    SENSOR_FEATURE="$DEFAULT_SENSOR_FEATURE"
    HISTORY_FILE="$DEFAULT_HISTORY_FILE"
    HISTORY_DAYS="$DEFAULT_HISTORY_DAYS"

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
                    is_number "$value" \
                        && REPEAT_INTERVAL_SEC="$(printf '%.0f' "$value")" ;;
                RUN_DIR)
                    [[ "$value" == /* ]] && RUN_DIR="$value" ;;
                NOTIFICATION_TYPE)
                    [[ "$value" =~ ^[0-3]$ ]] && NOTIFICATION_TYPE="$value" ;;
                NOTIFICATION_QTNOTIFIER)
                    [[ "$value" == /* ]] && NOTIFICATION_QTNOTIFIER="$value" ;;
                SENSOR_CHIP)
                    SENSOR_CHIP="$value" ;;
                SENSOR_FEATURE)
                    SENSOR_FEATURE="$value" ;;
                HISTORY_FILE)
                    [[ "$value" == /* ]] && HISTORY_FILE="$value" ;;
                HISTORY_DAYS)
                    [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) \
                        && HISTORY_DAYS="$value" ;;
            esac
        done < "$CONFIG_FILE"
    else
        log "config file $CONFIG_FILE not found, using defaults"
    fi

    if [[ -n "${SRVTEMPMON_RUN_DIR:-}" ]]; then
        RUN_DIR="$SRVTEMPMON_RUN_DIR"
    fi

    CUR_FILE="$RUN_DIR/temp_cur"
    MIN_FILE="$RUN_DIR/temp_min"
    MAX_FILE="$RUN_DIR/temp_max"
    AVG_FILE="$RUN_DIR/temp_avg"
    STATE_FILE="$RUN_DIR/temp_state"
}

# Read CPU temperature using lm-sensors, or fall back to thermal_zone sysfs.
# Sets the global SENSOR_LABEL to the source of the reading.
get_temp_c() {
    local chip_arg out highest label

    if command -v sensors >/dev/null 2>&1; then
        [[ -n "$SENSOR_CHIP" ]] && chip_arg="$SENSOR_CHIP" || chip_arg=""

        if [[ -n "$SENSOR_FEATURE" ]]; then
            # Specific feature: find a line whose label matches exactly.
            out=$(sensors ${chip_arg:+"$chip_arg"} 2>/dev/null | awk \
                -v feat="$SENSOR_FEATURE" '
                {
                    n = index($0, ":")
                    if (n == 0) next
                    label = substr($0, 1, n - 1)
                    gsub(/^[ \t]+|[ \t]+$/, "", label)
                    if (label != feat) next
                    line = substr($0, n + 1)
                    # Grab first signed numeric token; strip degree symbol etc.
                    sub(/^[^+\-0-9]*/, "", line)
                    sub(/[^0-9.+-].*/, "", line)
                    sub(/^[+]/, "", line)
                    if (line ~ /^-?[0-9]+\.[0-9]+$/ && line + 0 > -50 \
                            && line + 0 < 200) {
                        printf "%s\t%s\n", line, label
                        exit
                    }
                }')
        else
            # Auto: highest of Package id / Core / Tdie / Tccd temps across
            # all reported chips.
            out=$(sensors ${chip_arg:+"$chip_arg"} 2>/dev/null | awk '
                /^[[:space:]]*(Package id |Core [0-9]|Tdie|Tccd[0-9]|Physical id )/ {
                    lbl = $0
                    sub(/:.*$/, "", lbl)
                    gsub(/^[ \t]+|[ \t]+$/, "", lbl)
                    line = $0
                    sub(/^[^:]*:[[:space:]]*/, "", line)
                    sub(/[^0-9.+-].*/, "", line)
                    sub(/^[+]/, "", line)
                    if (line ~ /^-?[0-9]+\.[0-9]+$/ && line + 0 > 0 \
                            && line + 0 < 200) {
                        if (max == "" || line + 0 > max + 0) {
                            max = line; maxlbl = lbl
                        }
                    }
                }
                END { if (max != "") printf "%s\t%s\n", max, maxlbl }')
        fi

        highest="${out%%$'\t'*}"
        label="${out#*$'\t'}"
        if is_number "$highest"; then
            SENSOR_LABEL="$label"
            echo "$highest"
            return 0
        fi
    fi

    # Fallback: thermal_zone sysfs (containers, VMs, or if sensors not installed)
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        local raw
        raw="$(cat /sys/class/thermal/thermal_zone0/temp)"
        [[ "$raw" =~ ^-?[0-9]+$ ]] || return 1
        SENSOR_LABEL="thermal_zone0"
        awk -v milli="$raw" 'BEGIN { printf "%.1f", milli / 1000.0 }'
        return 0
    fi

    return 1
}

temp_ge_threshold() {
    local temp="$1" threshold="$2"
    awk -v t="$temp" -v th="$threshold" 'BEGIN { exit !(t >= th) }'
}

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
    log "run files in $RUN_DIR"
    return 0
}

write_run_file() {
    local path="$1" content="$2"
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
            SAMPLES)     samples="$value" ;;
            SUM_C)       sum="$value" ;;
            START_EPOCH) start="$value" ;;
            MIN_EPOCH)   min_epoch="$value" ;;
            MAX_EPOCH)   max_epoch="$value" ;;
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

update_stats() {
    local temp="$1" now="$2"
    local out new_min new_max

    out="$(awk -v t="$temp" -v sum="$STAT_SUM" -v mn="${STAT_MIN:-0}" \
               -v mx="${STAT_MAX:-0}" -v n="$STAT_SAMPLES" 'BEGIN {
        first = (n == 0)
        sum += t; n += 1
        if (first || t < mn) { mn = t; newmin = 1 }
        if (first || t > mx) { mx = t; newmax = 1 }
        printf "%.4f %.1f %.1f %d %.2f %d %d", sum, mn, mx, n, sum / n, \
            newmin + 0, newmax + 0
    }')"

    read -r STAT_SUM STAT_MIN STAT_MAX STAT_SAMPLES STAT_AVG new_min new_max \
        <<< "$out"

    [[ "$new_min" == "1" ]] && STAT_MIN_EPOCH="$now"
    [[ "$new_max" == "1" ]] && STAT_MAX_EPOCH="$now"
}

write_stats() {
    local temp="$1" now="$2" alerted="$3"

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
NOTIFICATION_TYPE=$NOTIFICATION_TYPE
ALERTED=$alerted
SENSOR_LABEL=${SENSOR_LABEL:-}
HISTORY_FILE=$HISTORY_FILE
HOSTNAME=$HOST_NAME
PID=$$"
}

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

ensure_history_dir() {
    local hdir
    hdir="$(dirname "$HISTORY_FILE")"
    if [[ "$HISTORY_DIR_READY" == "$hdir" ]]; then
        return 0
    fi
    if ! mkdir -p "$hdir" 2>/dev/null; then
        log "cannot create history directory $hdir, history disabled"
        return 1
    fi
    chmod 0755 "$hdir" 2>/dev/null || true
    HISTORY_DIR_READY="$hdir"
    return 0
}

write_history() {
    local epoch="$1" temp="$2"

    ensure_history_dir || return 1

    if [[ ! -f "$HISTORY_FILE" ]]; then
        printf '# srvtempmon history: epoch:temp_c:sensor_label\n' \
            > "$HISTORY_FILE" 2>/dev/null || return 1
    fi

    printf '%s:%.1f:%s\n' "$epoch" "$temp" "${SENSOR_LABEL:-cpu}" \
        >> "$HISTORY_FILE" 2>/dev/null
}

prune_history() {
    local cutoff tmp

    [[ -f "$HISTORY_FILE" ]] || return 0
    [[ "$HISTORY_DAYS" =~ ^[0-9]+$ ]] || return 0

    cutoff=$(( $(date +%s) - HISTORY_DAYS * 86400 ))
    tmp="${HISTORY_FILE}.prune.$$"

    if awk -F: -v cutoff="$cutoff" '
        /^#/ { print; next }
        NF >= 2 && $1 + 0 >= cutoff { print }
    ' "$HISTORY_FILE" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$HISTORY_FILE" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Notifications (identical logic to tempmon.sh)
# ---------------------------------------------------------------------------

notify_wants() {
    local bit="$1"
    [[ "$NOTIFICATION_TYPE" =~ ^[0-9]+$ ]] || return 1
    (( (NOTIFICATION_TYPE & bit) != 0 ))
}

tty_notify() {
    local title="$1" detail="$2"
    local msg t sent=0

    msg="$(printf '\r\n\007*** %s ***\r\n%s\r\n\r\n' "$title" "$detail")"

    for t in /dev/pts/[0-9]* /dev/tty[0-9]*; do
        [[ -w "$t" ]] || continue
        printf '%s' "$msg" > "$t" 2>/dev/null && sent=$(( sent + 1 ))
    done

    if (( sent == 0 )); then
        log "no writable terminal found, tty notification skipped"
        return 1
    fi
    return 0
}

gui_notifier_path() {
    if [[ -n "$NOTIFICATION_QTNOTIFIER" && -x "$NOTIFICATION_QTNOTIFIER" ]]; then
        printf '%s\n' "$NOTIFICATION_QTNOTIFIER"
        return 0
    fi
    command -v notify-send 2>/dev/null && return 0
    return 1
}

gui_sessions() {
    local sid key value uid user type state display

    command -v loginctl >/dev/null 2>&1 || return 0

    while read -r sid; do
        [[ -n "$sid" ]] || continue
        uid=""; user=""; type=""; state=""; display=""
        while IFS='=' read -r key value; do
            case "$key" in
                User)    uid="$value" ;;
                Name)    user="$value" ;;
                Type)    type="$value" ;;
                State)   state="$value" ;;
                Display) display="$value" ;;
            esac
        done < <(loginctl show-session "$sid" \
                     -p User -p Name -p Type -p State -p Display 2>/dev/null)
        case "$type" in x11|wayland|mir) ;; *) continue ;; esac
        case "$state" in active|online) ;; *) continue ;; esac
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        [[ -n "$user" ]] || continue
        printf '%s %s %s\n' "$uid" "$user" "${display:-}"
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
}

gui_notify_session() {
    local uid="$1" user="$2" display="$3" notifier="$4"
    local title="$5" detail="$6" urgency="$7"
    local -a env_args cmd

    env_args=(
        "XDG_RUNTIME_DIR=/run/user/$uid"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"
    )
    [[ -n "$display" ]] && env_args+=( "DISPLAY=$display" )

    if [[ "$(basename "$notifier")" == "notify-send" ]]; then
        cmd=( "$notifier" -a srvtempmon -u "$urgency" "$title" "$detail" )
    else
        cmd=( "$notifier" "$title" "$detail" )
    fi

    if [[ "$(id -u)" == "$uid" ]]; then
        env "${env_args[@]}" "${cmd[@]}" >/dev/null 2>&1
        return $?
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- env "${env_args[@]}" "${cmd[@]}" >/dev/null 2>&1
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo -n -u "$user" env "${env_args[@]}" "${cmd[@]}" >/dev/null 2>&1
        return $?
    fi
    return 1
}

gui_notify() {
    local title="$1" detail="$2" urgency="$3"
    local notifier uid user display sent=0 seen=0

    if ! notifier="$(gui_notifier_path)"; then
        if (( GUI_WARNED == 0 )); then
            log "no desktop notifier found, gui notifications disabled"
            GUI_WARNED=1
        fi
        return 1
    fi

    while read -r uid user display; do
        [[ -n "$uid" ]] || continue
        seen=$(( seen + 1 ))
        if gui_notify_session "$uid" "$user" "$display" "$notifier" \
                              "$title" "$detail" "$urgency"; then
            sent=$(( sent + 1 ))
        else
            log "desktop notification to $user (uid $uid) failed"
        fi
    done < <(gui_sessions)

    if (( seen == 0 )); then
        if (( GUI_WARNED == 0 )); then
            log "no active graphical session found, gui notification skipped"
            GUI_WARNED=1
        fi
        return 1
    fi
    (( sent > 0 ))
}

notify() {
    local title="$1" detail="$2" urgency="${3:-normal}"
    notify_wants "$NOTIFY_BIT_TTY" && tty_notify "$title" "$detail"
    notify_wants "$NOTIFY_BIT_GUI" && gui_notify "$title" "$detail" "$urgency"
    return 0
}

stamp_of() {
    local now="$1"
    date -d "@$now" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

raise_alarm() {
    local temp="$1" now="$2"
    log "threshold exceeded, temp=${temp}C threshold=${THRESHOLD_C}C type=${NOTIFICATION_TYPE}"
    notify "TEMPERATURE WARNING on $HOST_NAME" \
           "$(printf '%s C, threshold %s C exceeded at %s (sensor: %s)' \
                     "$temp" "$THRESHOLD_C" "$(stamp_of "$now")" \
                     "${SENSOR_LABEL:-unknown}")" \
           critical
    LAST_ALERT_EPOCH="$now"
}

clear_alarm() {
    local temp="$1" now="$2"
    log "recovered, temp=${temp}C threshold=${THRESHOLD_C}C"
    notify "TEMPERATURE NORMAL on $HOST_NAME" \
           "$(printf '%s C, back under threshold %s C at %s' \
                     "$temp" "$THRESHOLD_C" "$(stamp_of "$now")")" \
           normal
}

test_notify() {
    local temp now

    read_config
    log "notification test: NOTIFICATION_TYPE=$NOTIFICATION_TYPE"

    if notify_wants "$NOTIFY_BIT_GUI"; then
        local notifier
        notifier="$(gui_notifier_path 2>/dev/null)" \
            && log "desktop notifier: $notifier"
        log "graphical sessions: $(gui_sessions | wc -l)"
    fi

    SENSOR_LABEL=""
    now="$(date +%s)"
    temp="$(get_temp_c)" || temp="0.0"

    notify "SRVTEMPMON TEST on $HOST_NAME" \
           "$(printf 'test notification, current temp %s C (sensor: %s)' \
                     "$temp" "${SENSOR_LABEL:-unknown}")" \
           normal

    log "notification test done"
}

usage() {
    cat <<'USAGE'
usage: srvtempmon.sh [--test-notify|--help]

  (no argument)   poll CPU temperature forever, alerting on threshold
  --test-notify   send one test alert through the configured
                  NOTIFICATION_TYPE, then exit
  --help          this message

config: /etc/srvtempmon/config.txt
USAGE
}

cleanup() {
    log "stopping"
    exit 0
}

main() {
    local temp now

    trap cleanup INT TERM

    log "starting, config file $CONFIG_FILE"

    read_config
    ensure_run_dir
    ensure_history_dir
    load_stats "$(date +%s)"
    prune_history

    log "threshold ${THRESHOLD_C}C, poll ${POLL_INTERVAL_SEC}s, type ${NOTIFICATION_TYPE}"
    log "history: $HISTORY_FILE (${HISTORY_DAYS}d)"

    if command -v sensors >/dev/null 2>&1; then
        if [[ -n "$SENSOR_CHIP" ]]; then
            log "sensor chip: $SENSOR_CHIP${SENSOR_FEATURE:+, feature: $SENSOR_FEATURE}"
        else
            log "sensor: auto (highest Package/Core from all chips)"
        fi
    else
        log "sensors(1) not found, using thermal_zone sysfs"
    fi

    while true; do
        read_config

        SENSOR_LABEL=""
        temp="$(get_temp_c)"
        if [[ -z "$temp" ]]; then
            log "unable to read temperature, retrying in ${POLL_INTERVAL_SEC}s"
            sleep "$POLL_INTERVAL_SEC"
            continue
        fi

        now="$(date +%s)"

        if [[ "$STAT_SAMPLES" -gt 0 && ! -f "$MIN_FILE" ]]; then
            log "run files cleared, starting a new min/max/average window"
            reset_stats "$now"
        fi

        update_stats "$temp" "$now"
        write_history "$now" "$temp"

        PRUNE_COUNTER=$(( PRUNE_COUNTER + 1 ))
        if (( PRUNE_COUNTER >= PRUNE_EVERY )); then
            prune_history
            PRUNE_COUNTER=0
        fi

        if temp_ge_threshold "$temp" "$THRESHOLD_C"; then
            if (( ALERTED == 0 )) \
               || (( now - LAST_ALERT_EPOCH >= REPEAT_INTERVAL_SEC )); then
                raise_alarm "$temp" "$now"
            fi
            ALERTED=1
        else
            if (( ALERTED == 1 )); then
                clear_alarm "$temp" "$now"
            fi
            ALERTED=0
        fi

        write_stats "$temp" "$now" "$ALERTED"

        sleep "$POLL_INTERVAL_SEC"
    done
}

case "${1:-}" in
    --test-notify) test_notify ;;
    --help|-h)     usage ;;
    "")            main ;;
    *)
        echo "srvtempmon: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
esac

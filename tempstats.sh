#!/bin/bash
#
# tempstats.sh
#
# Reports the board temperature statistics that tempmon.sh maintains in its
# run files: current, minimum, maximum and average, plus the sample count
# and the age of the window.
#
# Installed next to the daemon in /usr/local/sbin by install_tempmon.sh,
# also symlinked as tempstats for convenience. Reading needs no privileges,
# the run files are world readable.
#
# Usage:
#   tempstats                 full report
#   tempstats --short         one line: cur/min/max/avg
#   tempstats --json          machine readable
#   tempstats --cur           just the current temperature, bare number
#   tempstats --min           just the minimum
#   tempstats --max           just the maximum
#   tempstats --avg           just the average
#   tempstats --watch         refresh the report until interrupted
#   tempstats --interval SEC  refresh period for --watch, default 2
#   tempstats --reset         restart the min/max/average window (root)
#   tempstats --run-dir DIR   read run files from DIR instead of the default
#
# Exit status:
#   0  statistics reported
#   1  usage error
#   2  no run files and no readable sensor, nothing to report
#   3  run files missing, values shown come straight from the sensor
#
# If tempmon.sh is not running there are no run files, so only the current
# temperature can be reported, read directly from the sensor.

set -euo pipefail

CONFIG_FILE="/etc/tempmon/config.txt"
DEFAULT_RUN_DIR="/run/tempmon"
RUN_DIR=""
MODE="report"
FIELD=""
WATCH=0
INTERVAL=2

usage() {
    sed -n '4,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "tempstats: $1" >&2
    exit "${2:-1}"
}

is_number() {
    [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

# Run directory resolution: --run-dir, then TEMPMON_RUN_DIR, then the
# RUN_DIR key in the config file, then the built-in default. Kept in step
# with tempmon.sh so both agree on where the run files live.
resolve_run_dir() {
    local line key value

    [[ -n "$RUN_DIR" ]] && return 0

    if [[ -n "${TEMPMON_RUN_DIR:-}" ]]; then
        RUN_DIR="$TEMPMON_RUN_DIR"
        return 0
    fi

    if [[ -r "$CONFIG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="$(echo "$line" | xargs)"
            [[ -z "$line" ]] && continue
            key="$(echo "${line%%=*}" | xargs)"
            value="$(echo "${line#*=}" | xargs)"
            if [[ "$key" == "RUN_DIR" && "$value" == /* ]]; then
                RUN_DIR="$value"
            fi
        done < "$CONFIG_FILE"
    fi

    [[ -n "$RUN_DIR" ]] || RUN_DIR="$DEFAULT_RUN_DIR"
}

# Same probe order as tempmon.sh, used when the run files are not there.
get_temp_c() {
    local raw

    if command -v vcgencmd >/dev/null 2>&1; then
        raw="$(vcgencmd measure_temp 2>/dev/null || true)"
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

read_num_file() {
    local path="$1"
    local value

    [[ -r "$path" ]] || return 1
    value="$(tr -d '[:space:]' < "$path")"
    is_number "$value" || return 1
    echo "$value"
}

read_state() {
    local line key value

    [[ -r "$STATE_FILE" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            SAMPLES)            ST_SAMPLES="$value" ;;
            START_EPOCH)        ST_START="$value" ;;
            UPDATED_EPOCH)      ST_UPDATED="$value" ;;
            MIN_EPOCH)          ST_MIN_EPOCH="$value" ;;
            MAX_EPOCH)          ST_MAX_EPOCH="$value" ;;
            THRESHOLD_C)        ST_THRESHOLD="$value" ;;
            POLL_INTERVAL_SEC)  ST_POLL="$value" ;;
            ALERTED)            ST_ALERTED="$value" ;;
            HOSTNAME)           ST_HOST="$value" ;;
            PID)                ST_PID="$value" ;;
        esac
    done < "$STATE_FILE"

    return 0
}

fmt_epoch() {
    local epoch="${1:-}"
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
        date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-"
    else
        echo "-"
    fi
}

fmt_duration() {
    local secs="${1:-0}"
    [[ "$secs" =~ ^[0-9]+$ ]] || { echo "-"; return; }
    printf '%dh %dm %ds' $(( secs / 3600 )) $(( secs % 3600 / 60 )) $(( secs % 60 ))
}

daemon_state() {
    if [[ "$HAVE_RUN_FILES" -eq 1 ]] && [[ "${ST_PID:-}" =~ ^[0-9]+$ ]] \
       && [[ -d "/proc/$ST_PID" ]]; then
        echo "running (pid $ST_PID)"
        return
    fi

    if command -v systemctl >/dev/null 2>&1; then
        echo "$(systemctl is-active tempmon.service 2>/dev/null || echo unknown)"
        return
    fi

    echo "unknown"
}

collect() {
    STATE_FILE="$RUN_DIR/temp_state"

    ST_SAMPLES=""; ST_START=""; ST_UPDATED=""; ST_MIN_EPOCH=""
    ST_MAX_EPOCH=""; ST_THRESHOLD=""; ST_POLL=""; ST_ALERTED=""
    ST_HOST=""; ST_PID=""

    CUR="$(read_num_file "$RUN_DIR/temp_cur" || true)"
    MIN="$(read_num_file "$RUN_DIR/temp_min" || true)"
    MAX="$(read_num_file "$RUN_DIR/temp_max" || true)"
    AVG="$(read_num_file "$RUN_DIR/temp_avg" || true)"

    HAVE_RUN_FILES=0
    if [[ -n "$CUR" && -n "$MIN" && -n "$MAX" ]]; then
        HAVE_RUN_FILES=1
        read_state || true
    fi

    # No run files, or a stale current reading: go straight to the sensor.
    LIVE=0
    if [[ "$HAVE_RUN_FILES" -eq 0 ]]; then
        CUR="$(get_temp_c || true)"
        is_number "$CUR" || die "no run files in $RUN_DIR and no readable sensor" 2
        LIVE=1
    fi
}

print_report() {
    local host="${ST_HOST:-$(hostname)}"
    local now age

    now="$(date +%s)"

    echo "tempmon stats on ${host}"
    printf '  run files:   %s\n' "$RUN_DIR"
    printf '  daemon:      %s\n' "$(daemon_state)"

    if [[ "$LIVE" -eq 1 ]]; then
        printf '  current:     %s C  (read live, daemon is not writing run files)\n' "$CUR"
        echo
        echo "  no min/max/average available, start the daemon: systemctl start tempmon"
        return
    fi

    printf '  current:     %s C\n' "$CUR"
    printf '  minimum:     %s C   at %s\n' "$MIN" "$(fmt_epoch "${ST_MIN_EPOCH:-}")"
    printf '  maximum:     %s C   at %s\n' "$MAX" "$(fmt_epoch "${ST_MAX_EPOCH:-}")"
    printf '  average:     %s C   over %s samples\n' "${AVG:-?}" "${ST_SAMPLES:-?}"

    if [[ "${ST_START:-}" =~ ^[0-9]+$ ]] && [[ "${ST_UPDATED:-}" =~ ^[0-9]+$ ]]; then
        age=$(( ST_UPDATED - ST_START ))
        (( age < 0 )) && age=0
        printf '  window:      %s   since %s\n' "$(fmt_duration "$age")" "$(fmt_epoch "$ST_START")"
    fi

    if [[ "${ST_UPDATED:-}" =~ ^[0-9]+$ ]]; then
        printf '  last sample: %s   (%ss ago)\n' "$(fmt_epoch "$ST_UPDATED")" "$(( now - ST_UPDATED ))"
    fi

    if is_number "${ST_THRESHOLD:-}"; then
        local state="OK"
        [[ "${ST_ALERTED:-0}" == "1" ]] && state="ALERT, above threshold"
        printf '  threshold:   %s C   state: %s\n' "$ST_THRESHOLD" "$state"
    fi
}

print_short() {
    printf 'cur=%s min=%s max=%s avg=%s samples=%s\n' \
        "${CUR:-?}" "${MIN:--}" "${MAX:--}" "${AVG:--}" "${ST_SAMPLES:-0}"
}

json_num() {
    if is_number "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi
}

json_int() {
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

print_json() {
    printf '{'
    printf '"hostname":"%s",' "${ST_HOST:-$(hostname)}"
    printf '"run_dir":"%s",' "$RUN_DIR"
    printf '"live_read":%s,' "$( [[ "$LIVE" -eq 1 ]] && echo true || echo false )"
    printf '"current_c":%s,' "$(json_num "${CUR:-}")"
    printf '"min_c":%s,' "$(json_num "${MIN:-}")"
    printf '"max_c":%s,' "$(json_num "${MAX:-}")"
    printf '"avg_c":%s,' "$(json_num "${AVG:-}")"
    printf '"samples":%s,' "$(json_int "${ST_SAMPLES:-}")"
    printf '"threshold_c":%s,' "$(json_num "${ST_THRESHOLD:-}")"
    printf '"alerted":%s,' "$( [[ "${ST_ALERTED:-0}" == "1" ]] && echo true || echo false )"
    printf '"start_epoch":%s,' "$(json_int "${ST_START:-}")"
    printf '"updated_epoch":%s,' "$(json_int "${ST_UPDATED:-}")"
    printf '"min_epoch":%s,' "$(json_int "${ST_MIN_EPOCH:-}")"
    printf '"max_epoch":%s' "$(json_int "${ST_MAX_EPOCH:-}")"
    printf '}\n'
}

print_field() {
    local value
    case "$FIELD" in
        cur) value="${CUR:-}" ;;
        min) value="${MIN:-}" ;;
        max) value="${MAX:-}" ;;
        avg) value="${AVG:-}" ;;
    esac

    if ! is_number "$value"; then
        die "$FIELD not available, is tempmon running? (run files: $RUN_DIR)" 2
    fi

    echo "$value"
}

do_reset() {
    local f removed=0

    if [[ ! -d "$RUN_DIR" ]]; then
        die "run directory $RUN_DIR does not exist, nothing to reset" 2
    fi

    for f in temp_cur temp_min temp_max temp_avg temp_state; do
        if [[ -e "$RUN_DIR/$f" ]]; then
            if ! rm -f "$RUN_DIR/$f"; then
                die "cannot remove $RUN_DIR/$f, try again as root"
            fi
            removed=$(( removed + 1 ))
        fi
    done

    if (( removed == 0 )); then
        echo "tempstats: no run files in $RUN_DIR, nothing to reset"
    else
        echo "tempstats: cleared $removed run file(s) in $RUN_DIR"
        echo "tempstats: a new min/max/average window starts on the next poll"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        -s|--short)     MODE="short" ;;
        -j|--json)      MODE="json" ;;
        --cur|--current) MODE="field"; FIELD="cur" ;;
        --min)          MODE="field"; FIELD="min" ;;
        --max)          MODE="field"; FIELD="max" ;;
        --avg|--average) MODE="field"; FIELD="avg" ;;
        --reset)        MODE="reset" ;;
        -w|--watch)     WATCH=1 ;;
        -i|--interval)
            [[ $# -ge 2 ]] || die "--interval needs a value"
            [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--interval must be a number: $2"
            INTERVAL="$2"
            shift
            ;;
        --run-dir)
            [[ $# -ge 2 ]] || die "--run-dir needs a value"
            [[ -n "$2" ]] || die "--run-dir must not be empty"
            RUN_DIR="$2"
            shift
            ;;
        *)
            die "unknown argument: $1 (try --help)"
            ;;
    esac
    shift
done

resolve_run_dir

if [[ "$MODE" == "reset" ]]; then
    do_reset
    exit 0
fi

emit() {
    case "$MODE" in
        report) print_report ;;
        short)  print_short ;;
        json)   print_json ;;
        field)  print_field ;;
    esac
}

if [[ "$WATCH" -eq 1 ]]; then
    trap 'echo; exit 0' INT TERM
    while true; do
        collect
        clear 2>/dev/null || true
        emit
        sleep "$INTERVAL"
    done
fi

collect
emit

# Signal with exit 3 that the numbers did not come from the daemon.
[[ "$LIVE" -eq 1 ]] && exit 3
exit 0

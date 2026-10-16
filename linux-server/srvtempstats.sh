#!/bin/bash
#
# srvtempstats.sh
#
# Reports CPU temperature statistics maintained by srvtempmon.sh and can
# display an ASCII time-series graph from the history file.
#
# Usage:
#   srvtempstats                       full report
#   srvtempstats --short               one line: cur/min/max/avg
#   srvtempstats --json                machine readable
#   srvtempstats --cur                 just the current temperature, bare number
#   srvtempstats --min                 just the minimum
#   srvtempstats --max                 just the maximum
#   srvtempstats --avg                 just the average
#   srvtempstats --watch               refresh the report until interrupted
#   srvtempstats --interval SEC        refresh period for --watch, default 2
#   srvtempstats --reset               restart the min/max/average window (root)
#   srvtempstats --sensors             list available hardware sensors
#   srvtempstats --graph [MINUTES]     ASCII time-series graph, default 60m
#   srvtempstats --history             dump the raw history CSV
#   srvtempstats --run-dir DIR         read run files from DIR
#
# Exit status:
#   0  statistics reported
#   1  usage error
#   2  no run files and no readable sensor, nothing to report
#   3  run files missing, value shown came straight from the sensor

set -euo pipefail

CONFIG_FILE="/etc/srvtempmon/config.txt"
DEFAULT_RUN_DIR="/run/srvtempmon"
DEFAULT_HISTORY_FILE="/var/lib/srvtempmon/history.csv"
RUN_DIR=""
HISTORY_FILE=""
MODE="report"
FIELD=""
WATCH=0
INTERVAL=2
GRAPH_MINUTES=60

usage() {
    sed -n '4,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "srvtempstats: $1" >&2
    exit "${2:-1}"
}

is_number() {
    [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

resolve_paths() {
    local line key value

    if [[ -z "$RUN_DIR" ]]; then
        if [[ -n "${SRVTEMPMON_RUN_DIR:-}" ]]; then
            RUN_DIR="$SRVTEMPMON_RUN_DIR"
        elif [[ -r "$CONFIG_FILE" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"
                line="$(echo "$line" | xargs)"
                [[ -z "$line" ]] && continue
                key="$(echo "${line%%=*}" | xargs)"
                value="$(echo "${line#*=}" | xargs)"
                [[ "$key" == "RUN_DIR" && "$value" == /* ]] && RUN_DIR="$value"
            done < "$CONFIG_FILE"
        fi
        [[ -n "$RUN_DIR" ]] || RUN_DIR="$DEFAULT_RUN_DIR"
    fi

    if [[ -z "$HISTORY_FILE" ]]; then
        if [[ -r "$CONFIG_FILE" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"
                line="$(echo "$line" | xargs)"
                [[ -z "$line" ]] && continue
                key="$(echo "${line%%=*}" | xargs)"
                value="$(echo "${line#*=}" | xargs)"
                [[ "$key" == "HISTORY_FILE" && "$value" == /* ]] \
                    && HISTORY_FILE="$value"
            done < "$CONFIG_FILE"
        fi
        [[ -n "$HISTORY_FILE" ]] || HISTORY_FILE="$DEFAULT_HISTORY_FILE"
    fi
}

get_temp_c() {
    local raw

    if command -v sensors >/dev/null 2>&1; then
        local highest
        highest=$(sensors 2>/dev/null | awk '
            /^[[:space:]]*(Package id |Core [0-9]|Tdie|Tccd[0-9]|Physical id )/ {
                line = $0
                sub(/^[^:]*:[[:space:]]*/, "", line)
                sub(/[^0-9.+-].*/, "", line)
                sub(/^[+]/, "", line)
                if (line ~ /^-?[0-9]+\.[0-9]+$/ && line + 0 > 0 \
                        && line + 0 < 200) {
                    if (max == "" || line + 0 > max + 0) max = line
                }
            }
            END { if (max != "") print max }')
        if is_number "$highest"; then
            echo "$highest"; return 0
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
    local path="$1" value
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
            SAMPLES)           ST_SAMPLES="$value" ;;
            START_EPOCH)       ST_START="$value" ;;
            UPDATED_EPOCH)     ST_UPDATED="$value" ;;
            MIN_EPOCH)         ST_MIN_EPOCH="$value" ;;
            MAX_EPOCH)         ST_MAX_EPOCH="$value" ;;
            THRESHOLD_C)       ST_THRESHOLD="$value" ;;
            POLL_INTERVAL_SEC) ST_POLL="$value" ;;
            ALERTED)           ST_ALERTED="$value" ;;
            SENSOR_LABEL)      ST_SENSOR="$value" ;;
            HISTORY_FILE)      ST_HISTFILE="$value" ;;
            HOSTNAME)          ST_HOST="$value" ;;
            PID)               ST_PID="$value" ;;
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
        echo "$(systemctl is-active srvtempmon.service 2>/dev/null || echo unknown)"
        return
    fi
    echo "unknown"
}

collect() {
    STATE_FILE="$RUN_DIR/temp_state"

    ST_SAMPLES=""; ST_START=""; ST_UPDATED=""; ST_MIN_EPOCH=""
    ST_MAX_EPOCH=""; ST_THRESHOLD=""; ST_POLL=""; ST_ALERTED=""
    ST_SENSOR=""; ST_HISTFILE=""; ST_HOST=""; ST_PID=""

    CUR="$(read_num_file "$RUN_DIR/temp_cur" || true)"
    MIN="$(read_num_file "$RUN_DIR/temp_min" || true)"
    MAX="$(read_num_file "$RUN_DIR/temp_max" || true)"
    AVG="$(read_num_file "$RUN_DIR/temp_avg" || true)"

    HAVE_RUN_FILES=0
    if [[ -n "$CUR" && -n "$MIN" && -n "$MAX" ]]; then
        HAVE_RUN_FILES=1
        read_state || true
    fi

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

    echo "srvtempmon stats on ${host}"
    printf '  run files:   %s\n' "$RUN_DIR"
    printf '  daemon:      %s\n' "$(daemon_state)"

    if [[ "$LIVE" -eq 1 ]]; then
        printf '  current:     %s C  (live read, daemon not running)\n' "$CUR"
        echo
        echo "  no min/max/average available, start the daemon: systemctl start srvtempmon"
        return
    fi

    printf '  current:     %s C\n' "$CUR"
    printf '  minimum:     %s C   at %s\n' "$MIN" "$(fmt_epoch "${ST_MIN_EPOCH:-}")"
    printf '  maximum:     %s C   at %s\n' "$MAX" "$(fmt_epoch "${ST_MAX_EPOCH:-}")"
    printf '  average:     %s C   over %s samples\n' "${AVG:-?}" "${ST_SAMPLES:-?}"

    if [[ "${ST_START:-}" =~ ^[0-9]+$ ]] && [[ "${ST_UPDATED:-}" =~ ^[0-9]+$ ]]; then
        age=$(( ST_UPDATED - ST_START ))
        (( age < 0 )) && age=0
        printf '  window:      %s   since %s\n' \
            "$(fmt_duration "$age")" "$(fmt_epoch "$ST_START")"
    fi

    if [[ "${ST_UPDATED:-}" =~ ^[0-9]+$ ]]; then
        printf '  last sample: %s   (%ss ago)\n' \
            "$(fmt_epoch "$ST_UPDATED")" "$(( now - ST_UPDATED ))"
    fi

    if is_number "${ST_THRESHOLD:-}"; then
        local state="OK"
        [[ "${ST_ALERTED:-0}" == "1" ]] && state="ALERT, above threshold"
        printf '  threshold:   %s C   state: %s\n' "$ST_THRESHOLD" "$state"
    fi

    [[ -n "${ST_SENSOR:-}" ]] \
        && printf '  sensor:      %s\n' "$ST_SENSOR"

    local hfile="${ST_HISTFILE:-$HISTORY_FILE}"
    if [[ -f "$hfile" ]]; then
        local lines
        lines=$(grep -vc '^#' "$hfile" 2>/dev/null || echo 0)
        printf '  history:     %s entries in %s\n' "$lines" "$hfile"
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

json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

print_json() {
    printf '{'
    printf '"hostname":%s,' "$(json_str "${ST_HOST:-$(hostname)}")"
    printf '"run_dir":%s,' "$(json_str "$RUN_DIR")"
    printf '"live_read":%s,' "$( [[ "$LIVE" -eq 1 ]] && echo true || echo false )"
    printf '"current_c":%s,' "$(json_num "${CUR:-}")"
    printf '"min_c":%s,' "$(json_num "${MIN:-}")"
    printf '"max_c":%s,' "$(json_num "${MAX:-}")"
    printf '"avg_c":%s,' "$(json_num "${AVG:-}")"
    printf '"samples":%s,' "$(json_int "${ST_SAMPLES:-}")"
    printf '"threshold_c":%s,' "$(json_num "${ST_THRESHOLD:-}")"
    printf '"alerted":%s,' "$( [[ "${ST_ALERTED:-0}" == "1" ]] && echo true || echo false )"
    printf '"sensor_label":%s,' "$(json_str "${ST_SENSOR:-}")"
    printf '"history_file":%s,' "$(json_str "${ST_HISTFILE:-$HISTORY_FILE}")"
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
        die "$FIELD not available, is srvtempmon running? (run files: $RUN_DIR)" 2
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
            rm -f "$RUN_DIR/$f" \
                || die "cannot remove $RUN_DIR/$f, try again as root"
            removed=$(( removed + 1 ))
        fi
    done
    if (( removed == 0 )); then
        echo "srvtempstats: no run files in $RUN_DIR, nothing to reset"
    else
        echo "srvtempstats: cleared $removed run file(s) in $RUN_DIR"
        echo "srvtempstats: a new min/max/average window starts on the next poll"
    fi
}

do_sensors() {
    if ! command -v sensors >/dev/null 2>&1; then
        die "sensors(1) not found, install lm-sensors: apt-get install lm-sensors" 2
    fi
    echo "Available hardware sensors:"
    echo "(Use SENSOR_CHIP and SENSOR_FEATURE in the config to select a specific one)"
    echo
    sensors
}

do_history() {
    local hfile="${1:-$HISTORY_FILE}"
    if [[ ! -f "$hfile" ]]; then
        die "history file $hfile does not exist" 2
    fi
    cat "$hfile"
}

# ASCII time-series graph of the last GRAPH_MINUTES minutes from history.
do_graph() {
    local hfile="${ST_HISTFILE:-$HISTORY_FILE}"
    local now minutes width height host

    minutes="$GRAPH_MINUTES"
    now="$(date +%s)"
    host="${ST_HOST:-$(hostname)}"

    if [[ ! -f "$hfile" ]]; then
        die "history file $hfile does not exist (is srvtempmon running?)" 2
    fi

    # Graph width: terminal width minus the y-axis label area (8 chars).
    width=$(( $(tput cols 2>/dev/null || echo 80) - 9 ))
    (( width < 20 )) && width=20
    (( width > 200 )) && width=200
    height=15

    local window_secs=$(( minutes * 60 ))
    local start_epoch=$(( now - window_secs ))

    # Label for the time axis
    local time_label
    if (( minutes >= 1440 )); then
        time_label="last $((minutes / 1440))d"
    elif (( minutes >= 60 )); then
        time_label="last $((minutes / 60))h"
    else
        time_label="last ${minutes}m"
    fi

    echo "CPU temperature ${time_label} on ${host}  ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo

    awk -F: \
        -v start="$start_epoch" \
        -v now="$now" \
        -v win="$window_secs" \
        -v W="$width" \
        -v H="$height" \
        -v hfile="$hfile" \
    '
    /^#/ { next }
    NF < 2 { next }
    {
        ep = $1 + 0
        tmp = $2 + 0
        if (ep < start || ep > now) next
        if (tmp <= 0 || tmp > 200) next

        b = int((ep - start) * W / win)
        if (b >= W) b = W - 1

        cnt[b]++
        sum[b] += tmp
        if (!(b in bmin) || tmp < bmin[b]) bmin[b] = tmp
        if (!(b in bmax) || tmp > bmax[b]) bmax[b] = tmp
        if (gmin == "" || tmp < gmin) gmin = tmp
        if (gmax == "" || tmp > gmax) gmax = tmp
        total++
    }
    END {
        if (total + 0 == 0) {
            print "  no data in this time window"
            exit 1
        }

        # Use average per bucket as the plotted value
        for (b = 0; b < W; b++) {
            if (cnt[b] > 0) data[b] = sum[b] / cnt[b]
        }

        # Add vertical padding
        pad = (gmax - gmin) * 0.08
        if (pad < 1) pad = 1
        ymin = gmin - pad
        ymax = gmax + pad
        if (ymin < 0) ymin = 0
        range = ymax - ymin
        if (range < 1) range = 1

        # Build character grid: row 0 = bottom, row H = top
        for (row = 0; row <= H; row++) {
            for (col = 0; col < W; col++) {
                grid[row][col] = " "
            }
        }

        for (col = 0; col < W; col++) {
            if (!(col in data)) continue
            d = data[col]
            r = int((d - ymin) / range * H + 0.5)
            if (r < 0) r = 0
            if (r > H) r = H
            grid[r][col] = "*"
        }

        # Print rows top to bottom
        for (row = H; row >= 0; row--) {
            row_temp = ymin + (row * range / H)
            if (row == H || row == 0 || row % int(H / 4) == 0) {
                printf "%5.1f |", row_temp
            } else {
                printf "      |"
            }
            for (col = 0; col < W; col++) {
                printf "%s", grid[row][col]
            }
            printf "\n"
        }

        # X axis line
        printf "      +"
        for (col = 0; col < W; col++) printf "-"
        printf "\n"

        # X axis time labels
        printf "      "
        label_step = int(W / 5)
        if (label_step < 1) label_step = 1
        prev_end = 0
        for (col = 0; col < W; col++) {
            if (col % label_step == 0 && col >= prev_end) {
                secs_from_start = int(col * win / W)
                mins_ago = int((win - secs_from_start) / 60)
                if (mins_ago == 0) {
                    lbl = "now"
                } else if (mins_ago >= 60) {
                    lbl = sprintf("-%dh%dm", int(mins_ago/60), mins_ago%60)
                } else {
                    lbl = sprintf("-%dm", mins_ago)
                }
                printf "%s", lbl
                prev_end = col + length(lbl)
            } else if (col < prev_end) {
                # skip, already covered by label
            } else {
                printf " "
            }
        }
        printf "\n"

        printf "\n  samples: %d   min: %.1fC   max: %.1fC   avg: %.1fC\n",
            total, gmin, gmax, (total > 0 ? sum_all/total : 0)
    }
    ' "$hfile"
}

# A thin wrapper so do_graph can also print the grand avg.
do_graph_wrapper() {
    local hfile="${ST_HISTFILE:-$HISTORY_FILE}"
    local now minutes width height host

    minutes="$GRAPH_MINUTES"
    now="$(date +%s)"
    host="${ST_HOST:-$(hostname)}"

    if [[ ! -f "$hfile" ]]; then
        die "history file $hfile does not exist (is srvtempmon running?)" 2
    fi

    width=$(( $(tput cols 2>/dev/null || echo 80) - 9 ))
    (( width < 20 )) && width=20
    (( width > 200 )) && width=200
    height=15

    local window_secs=$(( minutes * 60 ))
    local start_epoch=$(( now - window_secs ))

    local time_label
    if (( minutes >= 1440 )); then
        time_label="last $((minutes / 1440))d"
    elif (( minutes >= 60 )); then
        time_label="last $((minutes / 60))h"
    else
        time_label="last ${minutes}m"
    fi

    echo "CPU temperature ${time_label} on ${host}  ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo

    awk -F: \
        -v start="$start_epoch" \
        -v now_ep="$now" \
        -v win="$window_secs" \
        -v W="$width" \
        -v H="$height" \
    '
    /^#/ { next }
    NF < 2 { next }
    {
        ep = $1 + 0
        tmp = $2 + 0
        if (ep < start || ep > now_ep) next
        if (tmp <= 0 || tmp > 200) next

        b = int((ep - start) * W / win)
        if (b >= W) b = W - 1

        cnt[b]++
        sum[b] += tmp
        if (gmin == "" || tmp < gmin) gmin = tmp
        if (gmax == "" || tmp > gmax) gmax = tmp
        total_sum += tmp
        total++
    }
    END {
        if (total + 0 == 0) {
            print "  no data in this time window"
            exit 0
        }

        for (b = 0; b < W; b++) {
            if (cnt[b] > 0) data[b] = sum[b] / cnt[b]
        }

        pad = (gmax - gmin) * 0.08
        if (pad < 1) pad = 1
        ymin = gmin - pad
        ymax = gmax + pad
        if (ymin < 0) ymin = 0
        range = ymax - ymin
        if (range < 1) range = 1

        for (row = H; row >= 0; row--) {
            row_temp = ymin + (row * range / H)
            if (row == H || row == 0 || row % (int(H / 4) > 0 ? int(H / 4) : 1) == 0) {
                printf "%5.1f |", row_temp
            } else {
                printf "      |"
            }
            for (col = 0; col < W; col++) {
                if (col in data) {
                    d = data[col]
                    r = int((d - ymin) / range * H + 0.5)
                    if (r < 0) r = 0; if (r > H) r = H
                    printf "%s", (r == row ? "*" : " ")
                } else {
                    printf " "
                }
            }
            printf "\n"
        }

        printf "      +"
        for (col = 0; col < W; col++) printf "-"
        printf "\n"

        # Build label array at evenly-spaced columns, skipping col 0 for "now"
        printf "      "
        step = int(W / 5)
        if (step < 1) step = 1
        cursor = 0
        for (col = 0; col < W; col++) {
            if (col % step == 0) {
                secs_in = col * win / W
                mago = int((win - secs_in) / 60)
                # Skip zero-ago labels here; "now" is printed at the right edge
                if (mago == 0) { printf " "; cursor++; continue }
                if (mago >= 60) lbl = sprintf("-%dh%02dm", int(mago/60), mago%60)
                else lbl = sprintf("-%dm", mago)
                printf "%s", lbl
                cursor += length(lbl)
                # Pad to next step boundary
                for (i = cursor; i < col + step; i++) { printf " "; cursor++ }
            } else if (cursor <= col) {
                printf " "; cursor++
            }
        }
        # Right-pad then print "now"
        for (i = cursor; i < W - 3; i++) printf " "
        printf "now\n\n"

        printf "  samples: %d   min: %.1fC   max: %.1fC   avg: %.1fC\n",
            total, gmin, gmax, total_sum / total
    }
    ' "$hfile"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)         usage; exit 0 ;;
        -s|--short)        MODE="short" ;;
        -j|--json)         MODE="json" ;;
        --cur|--current)   MODE="field"; FIELD="cur" ;;
        --min)             MODE="field"; FIELD="min" ;;
        --max)             MODE="field"; FIELD="max" ;;
        --avg|--average)   MODE="field"; FIELD="avg" ;;
        --reset)           MODE="reset" ;;
        --sensors)         MODE="sensors" ;;
        --history)         MODE="history" ;;
        --graph)
            MODE="graph"
            # Optional numeric argument: minutes
            if [[ $# -ge 2 && "${2:-}" =~ ^[0-9]+$ ]]; then
                GRAPH_MINUTES="$2"; shift
            fi
            ;;
        -w|--watch)        WATCH=1 ;;
        -i|--interval)
            [[ $# -ge 2 ]] || die "--interval needs a value"
            [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--interval must be a number: $2"
            INTERVAL="$2"; shift ;;
        --run-dir)
            [[ $# -ge 2 ]] || die "--run-dir needs a value"
            [[ -n "$2" ]] || die "--run-dir must not be empty"
            RUN_DIR="$2"; shift ;;
        --history-file)
            [[ $# -ge 2 ]] || die "--history-file needs a value"
            HISTORY_FILE="$2"; shift ;;
        *)
            die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

resolve_paths

if [[ "$MODE" == "reset" ]]; then
    do_reset
    exit 0
fi

if [[ "$MODE" == "sensors" ]]; then
    do_sensors
    exit 0
fi

if [[ "$MODE" == "history" ]]; then
    do_history "$HISTORY_FILE"
    exit 0
fi

if [[ "$MODE" == "graph" ]]; then
    # Collect to populate ST_HOST / ST_HISTFILE if daemon is running.
    collect 2>/dev/null || true
    do_graph_wrapper
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

[[ "$LIVE" -eq 1 ]] && exit 3
exit 0

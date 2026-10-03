#!/bin/bash
#
# tempmon.sh
#
# Polls board temperature and raises an alert when it crosses the threshold
# set in /etc/tempmon/config.txt. Depending on NOTIFICATION_TYPE the alert
# goes to every logged-in tty (the way shutdown/reboot warns all terminals),
# to every active graphical session as a desktop notification, to both, or
# nowhere at all (log only). Meant to run as a systemd service
# (tempmon.service), installed by install_tempmon.sh, but also runs
# standalone in the foreground for testing.
#
# Config file format (/etc/tempmon/config.txt), key=value, one per line,
# blank lines and lines starting with # ignored:
#
#   THRESHOLD_C=75
#   POLL_INTERVAL_SEC=5
#   REPEAT_INTERVAL_SEC=300
#   RUN_DIR=/run/tempmon
#   NOTIFICATION_TYPE=1
#   NOTIFICATION_QTNOTIFIER=/bin/qtnotifier
#
# THRESHOLD_C           temperature in Celsius that triggers an alert
# POLL_INTERVAL_SEC     how often to check the temperature
# REPEAT_INTERVAL_SEC   minimum seconds between repeat alerts while the
#                       board stays above threshold, prevents spamming a
#                       notification on every poll cycle
# RUN_DIR               directory for the runtime files below
#
# NOTIFICATION_TYPE     where alerts go. Two bit field, bit 0 is tty, bit 1
#                       is desktop, so:
#
#                         0  no notification, log only
#                         1  text message on every tty
#                         2  desktop notification in every graphical session
#                         3  both
#
#                       Anything outside 0-3 is ignored and the default is
#                       used. Type 0 still logs every threshold crossing, so
#                       journalctl -u tempmon remains a full record.
#
# NOTIFICATION_QTNOTIFIER
#                       absolute path to a desktop notifier binary, used for
#                       type 2 and 3. Called as:
#
#                         <notifier> "<title>" "<message>"
#
#                       If that path is not executable tempmon falls back to
#                       notify-send, called as:
#
#                         notify-send -a tempmon -u <urgency> "<title>" "<msg>"
#
#                       If neither exists the desktop half of the alert is
#                       skipped and a warning is logged once. Install
#                       libnotify-bin to get notify-send.
#
# Desktop notifications are delivered per session: tempmon walks every
# active x11/wayland session reported by loginctl and runs the notifier as
# that session's user with DISPLAY, XDG_RUNTIME_DIR and
# DBUS_SESSION_BUS_ADDRESS pointing at that session. Running as root (the
# service does) this needs runuser or sudo. Running as a normal user only
# your own sessions are reachable, which is what you want for testing.
#
# Config is re-read every poll cycle, so editing the threshold or the
# notification type live takes effect without restarting the service.
# Values that are not valid are ignored and the built-in default is used
# instead.
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
# Set TEMPMON_RUN_DIR in the environment to override RUN_DIR, and
# TEMPMON_CONFIG to read a different config file, both useful for running the
# daemon as a normal user during testing:
#
#   TEMPMON_RUN_DIR=/tmp/tempmon ./tempmon.sh
#   TEMPMON_CONFIG=./my.txt TEMPMON_RUN_DIR=/tmp/tempmon ./tempmon.sh --test-notify
#
# Usage:
#   tempmon.sh                 poll forever (the service entry point)
#   tempmon.sh --test-notify   send one test alert through the configured
#                              NOTIFICATION_TYPE and exit, no polling. Use
#                              this to verify notifications without waiting
#                              for the board to get hot.
#   tempmon.sh --help

set -uo pipefail

CONFIG_FILE="${TEMPMON_CONFIG:-/etc/tempmon/config.txt}"
DEFAULT_THRESHOLD_C=75
DEFAULT_POLL_INTERVAL_SEC=5
DEFAULT_REPEAT_INTERVAL_SEC=300
DEFAULT_NOTIFICATION_TYPE=1
DEFAULT_NOTIFICATION_QTNOTIFIER=/bin/qtnotifier
DEFAULT_RUN_DIR="/run/tempmon"

# Bits of NOTIFICATION_TYPE. 3 is simply TTY|GUI.
NOTIFY_BIT_TTY=1
NOTIFY_BIT_GUI=2

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

# Alert state, global so the repeat throttle survives across poll cycles.
# (These used to be assigned inside a command substitution, where the
# assignment was lost with the subshell and the throttle never worked.)
ALERTED=0
LAST_ALERT_EPOCH=0

# Set once we have logged that no desktop notifier exists, so a misconfigured
# notifier does not fill the journal with one warning per alert.
GUI_WARNED=0

HOST_NAME="$(hostname 2>/dev/null || echo unknown)"

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
    NOTIFICATION_TYPE="$DEFAULT_NOTIFICATION_TYPE"
    NOTIFICATION_QTNOTIFIER="$DEFAULT_NOTIFICATION_QTNOTIFIER"

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
                    # Normalised to an integer, it is used in (( )) below.
                    is_number "$value" \
                        && REPEAT_INTERVAL_SEC="$(printf '%.0f' "$value")" ;;
                RUN_DIR)
                    [[ "$value" == /* ]] && RUN_DIR="$value" ;;
                NOTIFICATION_TYPE)
                    [[ "$value" =~ ^[0-3]$ ]] && NOTIFICATION_TYPE="$value" ;;
                NOTIFICATION_QTNOTIFIER)
                    [[ "$value" == /* ]] && NOTIFICATION_QTNOTIFIER="$value" ;;
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
NOTIFICATION_TYPE=$NOTIFICATION_TYPE
ALERTED=$alerted
HOSTNAME=$HOST_NAME
PID=$$"
}

# ---------------------------------------------------------------------------
# Notifications
#
# notify() is the single entry point. It takes a title, a detail line and an
# urgency, then fans out to whichever channels NOTIFICATION_TYPE selects.
# Every caller goes through it, so alerts and recoveries always honour the
# configured type.
# ---------------------------------------------------------------------------

# True when NOTIFICATION_TYPE has the given bit set. Type 3 has both.
notify_wants() {
    local bit="$1"

    [[ "$NOTIFICATION_TYPE" =~ ^[0-9]+$ ]] || return 1
    (( (NOTIFICATION_TYPE & bit) != 0 ))
}

# Broadcast to every attached terminal by writing straight to the tty
# device nodes. This deliberately does not use wall: on current util-linux
# (Ubuntu 25.10 and the systemd releases built without utmp support) wall
# enumerates targets from utmp, which no longer exists, so it reaches no one
# and exits cleanly. Writing to the device nodes needs no utmp. As root the
# write lands regardless of each terminal's mesg bit; as a normal user only
# the terminals you own are writable, which is what you want for testing.
tty_notify() {
    local title="$1"
    local detail="$2"
    local msg
    local t
    local sent=0

    # CR+LF on every line so the text renders cleanly even on a terminal in
    # raw mode, and a BEL so an idle session gets an audible nudge. This is
    # the banner wall used to print, formatted by hand.
    msg="$(printf '\r\n\007*** %s ***\r\n%s\r\n\r\n' "$title" "$detail")"

    # Pseudo-terminals (ssh, tmux, terminal emulators) plus the hardware
    # virtual consoles. The [0-9]* globs match only numbered nodes, so they
    # skip /dev/pts/ptmx, the bare /dev/tty, and named serial lines such as
    # /dev/ttyAMA0 and /dev/ttyS0, none of which should be broadcast to.
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

# Resolve the desktop notifier: the configured binary first, then
# notify-send. Prints the path, or fails if there is nothing usable.
gui_notifier_path() {
    if [[ -n "$NOTIFICATION_QTNOTIFIER" && -x "$NOTIFICATION_QTNOTIFIER" ]]; then
        printf '%s\n' "$NOTIFICATION_QTNOTIFIER"
        return 0
    fi

    command -v notify-send 2>/dev/null && return 0

    return 1
}

# Every active graphical session, one "uid user display" line each.
gui_sessions() {
    local sid key value
    local uid user type state display

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

        # Only graphical sessions can show a desktop notification, and only
        # a live one is worth notifying (a closing session has no bus).
        case "$type" in
            x11|wayland|mir) ;;
            *) continue ;;
        esac
        case "$state" in
            active|online) ;;
            *) continue ;;
        esac

        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        [[ -n "$user" ]] || continue

        printf '%s %s %s\n' "$uid" "$user" "${display:-}"
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
}

# Run one notifier invocation inside a given user's session.
gui_notify_session() {
    local uid="$1"
    local user="$2"
    local display="$3"
    local notifier="$4"
    local title="$5"
    local detail="$6"
    local urgency="$7"
    local -a env_args
    local -a cmd

    env_args=(
        "XDG_RUNTIME_DIR=/run/user/$uid"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"
    )
    [[ -n "$display" ]] && env_args+=( "DISPLAY=$display" )

    if [[ "$(basename "$notifier")" == "notify-send" ]]; then
        cmd=( "$notifier" -a tempmon -u "$urgency" "$title" "$detail" )
    else
        cmd=( "$notifier" "$title" "$detail" )
    fi

    # Already the session's owner (standalone testing): run it directly.
    if [[ "$(id -u)" == "$uid" ]]; then
        env "${env_args[@]}" "${cmd[@]}" >/dev/null 2>&1
        return $?
    fi

    # Otherwise we need to drop privileges into that session.
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

# Desktop notification in every active graphical session.
gui_notify() {
    local title="$1"
    local detail="$2"
    local urgency="$3"
    local notifier uid user display
    local sent=0
    local seen=0

    if ! notifier="$(gui_notifier_path)"; then
        if (( GUI_WARNED == 0 )); then
            log "no desktop notifier found (tried $NOTIFICATION_QTNOTIFIER and notify-send), gui notifications disabled, install libnotify-bin or set NOTIFICATION_QTNOTIFIER"
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
            log "desktop notification to $user (session uid $uid) failed"
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

# Fan one event out to the channels NOTIFICATION_TYPE selects.
notify() {
    local title="$1"
    local detail="$2"
    local urgency="${3:-normal}"

    if notify_wants "$NOTIFY_BIT_TTY"; then
        tty_notify "$title" "$detail"
    fi

    if notify_wants "$NOTIFY_BIT_GUI"; then
        gui_notify "$title" "$detail" "$urgency"
    fi

    return 0
}

stamp_of() {
    local now="$1"
    date -d "@$now" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || date '+%Y-%m-%d %H:%M:%S'
}

raise_alarm() {
    local temp="$1"
    local now="$2"

    log "threshold exceeded, temp=${temp}C threshold=${THRESHOLD_C}C notification_type=${NOTIFICATION_TYPE}"

    notify "TEMPERATURE WARNING on $HOST_NAME" \
           "$(printf '%s C, threshold %s C exceeded at %s' \
                     "$temp" "$THRESHOLD_C" "$(stamp_of "$now")")" \
           critical

    LAST_ALERT_EPOCH="$now"
}

clear_alarm() {
    local temp="$1"
    local now="$2"

    log "recovered, temp=${temp}C threshold=${THRESHOLD_C}C"

    notify "TEMPERATURE NORMAL on $HOST_NAME" \
           "$(printf '%s C, back under threshold %s C at %s' \
                     "$temp" "$THRESHOLD_C" "$(stamp_of "$now")")" \
           normal
}

# --test-notify: exercise the configured notification path once and exit.
test_notify() {
    local temp now

    read_config

    log "notification test: NOTIFICATION_TYPE=$NOTIFICATION_TYPE"
    case "$NOTIFICATION_TYPE" in
        0) log "type 0, log only, nothing will be sent" ;;
        1) log "type 1, tty broadcast to terminal devices" ;;
        2) log "type 2, desktop notification only" ;;
        3) log "type 3, tty broadcast and desktop notification" ;;
    esac

    if notify_wants "$NOTIFY_BIT_GUI"; then
        local notifier
        if notifier="$(gui_notifier_path)"; then
            log "desktop notifier: $notifier"
        fi
        log "graphical sessions: $(gui_sessions | wc -l)"
    fi

    now="$(date +%s)"
    temp="$(get_temp_c)"
    [[ -n "$temp" ]] || temp="0.0"

    notify "TEMPMON TEST on $HOST_NAME" \
           "$(printf 'test notification, current temp %s C, threshold %s C at %s' \
                     "$temp" "$THRESHOLD_C" "$(stamp_of "$now")")" \
           normal

    log "notification test done"
    return 0
}

usage() {
    cat <<'USAGE'
usage: tempmon.sh [--test-notify|--help]

  (no argument)   poll the board temperature forever, alerting on threshold
  --test-notify   send one test alert through the configured
                  NOTIFICATION_TYPE, then exit
  --help          this message

config: /etc/tempmon/config.txt
USAGE
}

cleanup() {
    log "stopping"
    exit 0
}

main() {
    local temp
    local now

    trap cleanup INT TERM

    log "starting, config file $CONFIG_FILE"

    read_config
    ensure_run_dir
    load_stats "$(date +%s)"

    log "notification type $NOTIFICATION_TYPE, threshold ${THRESHOLD_C}C"

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
        echo "tempmon: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
esac

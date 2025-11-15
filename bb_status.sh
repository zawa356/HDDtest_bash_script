#!/usr/bin/env bash
# bb_status.sh - summarize HDD acceptance test status and ETA
# Requirements:
#   - Logs under /var/log/hddtest/YYYYMMDD_HHMM
#   - Files:
#       smart-before_<dev>.txt
#       2_badblocks_badlist_<dev>.txt
#       2_badblocks_<dev>.log
#       smart-after_<dev>.txt
#   - badblocks processes running as root

set -u

BASE_DIR="/var/log/hddtest"
BB_FACTOR_DEFAULT=8  # 4 patterns x (write + read)

###############################################################
# Function: find_latest_logdir
# Purpose : Find the latest hddtest directory by mtime
###############################################################
find_latest_logdir() {
    local base="$1"

    # Pick newest subdirectory under base (by mtime)
    # Trailing slash is removed at the end.
    local latest
    latest=$(ls -1dt "${base}"/*/ 2>/dev/null | head -n1 || true)
    latest="${latest%/}"
    echo "$latest"
}

###############################################################
# Function: get_devices_from_logs
# Purpose : Collect device list from all known log file types
###############################################################
get_devices_from_logs() {
    local logdir="$1"
    local devs=()

    # smart-before_<dev>.txt
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        devs+=("$(basename "$path" | sed 's/.*smart-before_//' | sed 's/.txt//')")
    done < <(ls "${logdir}"/smart-before_*.txt 2>/dev/null || true)

    # 2_badblocks_badlist_<dev>.txt
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        devs+=("$(basename "$path" | sed 's/.*2_badblocks_badlist_//' | sed 's/.txt//')")
    done < <(ls "${logdir}"/2_badblocks_badlist_*.txt 2>/dev/null || true)

    # 2_badblocks_<dev>.log
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        devs+=("$(basename "$path" | sed 's/.*2_badblocks_//' | sed 's/.log//')")
    done < <(ls "${logdir}"/2_badblocks_*.log 2>/dev/null || true)

    # smart-after_<dev>.txt
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        devs+=("$(basename "$path" | sed 's/.*smart-after_//' | sed 's/.txt//')")
    done < <(ls "${logdir}"/smart-after_*.txt 2>/dev/null || true)

    # unique
    if ((${#devs[@]} > 0)); then
        printf '%s\n' "${devs[@]}" | grep -v '^$' | sort -u
    fi
}

###############################################################
# Function: get_badblocks_pid
# Purpose : Get badblocks PID for a device (if running)
# Return  : PID to stdout, exit 0 if found; empty and exit 1 otherwise
###############################################################
get_badblocks_pid() {
    local dev="$1"
    local pid
    for pid in $(pgrep badblocks 2>/dev/null); do
        if tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null \
            | grep -E -q "/dev/${dev}($| )"; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

###############################################################
# Function: get_badblocks_progress
# Purpose : Estimate badblocks progress using /proc/<pid>/io
# Args    : <dev> <pid> [factor]
# Return  : percentage (0-100)
###############################################################
get_badblocks_progress() {
    local dev="$1"
    local pid="$2"
    local factor="${3:-$BB_FACTOR_DEFAULT}"

    if [[ -z "$pid" ]]; then
        echo "0"
        return
    fi

    local size io pct
    size=$(blockdev --getsize64 "/dev/${dev}" 2>/dev/null || echo 0)
    if [[ -z "$size" || "$size" -eq 0 ]]; then
        echo "0"
        return
    fi

    if [[ ! -r "/proc/${pid}/io" ]]; then
        echo "0"
        return
    fi

    io=$(awk '/read_bytes/ {r=$2} /write_bytes/ {w=$2} END{print (r+w)}' "/proc/${pid}/io")
    [[ -z "$io" ]] && io=0

    pct=$(( io * 100 / (size * factor) ))
    # clamp
    if ((pct < 0)); then pct=0; fi
    if ((pct > 100)); then pct=100; fi
    echo "${pct}"
}

###############################################################
# Function: get_smart_states
# Purpose : Determine SMART_SHORT / SMART_LONG state
# Return  : "<short_state> <long_state>"
###############################################################
get_smart_states() {
    local dev="$1"
    local logdir="$2"

    local state_short="pending"
    local state_long="pending"

    [[ -f "${logdir}/smart-before_${dev}.txt" ]] && state_short="done"
    [[ -f "${logdir}/smart-after_${dev}.txt"  ]] && state_long="done"

    echo "${state_short} ${state_long}"
}

###############################################################
# Function: compute_overall_state
# Purpose : Compute high-level state from phase states
# Args    : <short_state> <bb_state> <long_state>
# Return  : one word state
###############################################################
compute_overall_state() {
    local short="$1"
    local bb="$2"
    local long="$3"

    if [[ "$short" == "done" && "$bb" == "done" && "$long" == "done" ]]; then
        echo "DONE"
    elif [[ "$bb" == "running" ]]; then
        echo "BADBLOCKS_RUNNING"
    elif [[ "$short" == "done" && "$bb" == "done" && "$long" == "pending" ]]; then
        echo "SMART_LONG_PENDING"
    elif [[ "$short" == "done" && "$bb" == "pending" ]]; then
        echo "BADBLOCKS_PENDING"
    elif [[ "$short" == "pending" ]]; then
        echo "SMART_SHORT_PENDING"
    else
        echo "UNKNOWN"
    fi
}

###############################################################
# Function: calc_eta
# Purpose : Calculate ETA (hours) based on PID and progress
# Args    : <pid> <pct>
# Return  : "<hours>h" or "-"
###############################################################
calc_eta() {
    local pid="$1"
    local pct="$2"

    if [[ -z "$pid" || "$pct" == "0" || "$pct" == "done" ]]; then
        echo "-"
        return
    fi

    local start_str start_epoch now elapsed eta eta_h

    start_str=$(ps -p "$pid" -o lstart= 2>/dev/null)
    if [[ -z "$start_str" ]]; then
        echo "-"
        return
    fi

    start_epoch=$(date -d "$start_str" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ "$start_epoch" -eq 0 ]]; then
        echo "-"
        return
    fi

    elapsed=$(( now - start_epoch ))
    if ((elapsed <= 0)); then
        echo "-"
        return
    fi

    eta=$(( elapsed * (100 - pct) / pct ))
    eta_h=$(( eta / 3600 ))

    echo "${eta_h}h"
}

###############################################################
# Main
###############################################################

LOGDIR=""

if [[ $# -ge 1 ]]; then
    LOGDIR="$1"
else
    LOGDIR=$(find_latest_logdir "$BASE_DIR")
fi

if [[ -z "$LOGDIR" || ! -d "$LOGDIR" ]]; then
    echo "No hddtest log directory found under ${BASE_DIR}" >&2
    exit 1
fi

DEVICES=()
while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    DEVICES+=("$dev")
done < <(get_devices_from_logs "$LOGDIR")

if ((${#DEVICES[@]} == 0)); then
    echo "No device logs found in ${LOGDIR}" >&2
    exit 1
fi

echo "Log directory : ${LOGDIR}"
echo "Base dir      : ${BASE_DIR}"
echo

printf "%-6s %-18s %-12s %-12s %-12s %-8s %-8s %-8s\n" \
    "DEV" "STATE" "SMART_SHORT" "BADBLOCKS" "SMART_LONG" "BB_PCT" "PID" "ETA"

completed=0
running_bb=0
total_devs=${#DEVICES[@]}
overall_eta_h=0
have_eta=0

for dev in "${DEVICES[@]}"; do
    # SMART states
    read -r state_short state_long <<<"$(get_smart_states "$dev" "$LOGDIR")"

    # BADBLOCKS state
    bb_pid=""
    bb_state="pending"
    bb_pct="0"
    bb_eta="-"

    if bb_pid=$(get_badblocks_pid "$dev"); then
        bb_state="running"
        bb_pct=$(get_badblocks_progress "$dev" "$bb_pid" "$BB_FACTOR_DEFAULT")
        bb_eta=$(calc_eta "$bb_pid" "$bb_pct")
        ((running_bb++))
        if [[ "$bb_eta" != "-" ]]; then
            local_eta=${bb_eta%h}
            if [[ "$have_eta" -eq 0 || "$local_eta" -gt "$overall_eta_h" ]]; then
                overall_eta_h="$local_eta"
                have_eta=1
            fi
        fi
    elif [[ -f "${LOGDIR}/2_badblocks_${dev}.log" ]]; then
        bb_state="done"
        bb_pct="100"
    else
        bb_state="pending"
        bb_pct="0"
    fi

    overall_state=$(compute_overall_state "$state_short" "$bb_state" "$state_long")
    [[ "$overall_state" == "DONE" ]] && ((completed++))

    printf "%-6s %-18s %-12s %-12s %-12s %-8s %-8s %-8s\n" \
        "$dev" "$overall_state" "$state_short" "$bb_state" "$state_long" "$bb_pct" "${bb_pid:-"-"}" "$bb_eta"
done

echo
printf "Summary: %d / %d devices DONE\n" "$completed" "$total_devs"
printf "         %d devices with badblocks running\n" "$running_bb"
if [[ "$have_eta" -eq 1 ]]; then
    printf "         Estimated overall remaining time (badblocks only): ~%dh\n" "$overall_eta_h"
else
    printf "         Estimated overall remaining time (badblocks only): -\n"
fi

#!/usr/bin/env bash
# ============================================================================
# HDD/SAS Acceptance Test (Ubuntu)
# v1.14
# - FIX: DRY RUN label showed even in normal run (use numeric check via dry_label())
# - Confirm page: Run/Details/Back + scrollable Details (fits 80x24)
# - xargs warning fixed (-0 with -I and -P)
# - SMART-only mode, Back navigation, SAS/SCSI-aware SMART parsing
# - Archives, env snapshot, filelists/hashes, demo loop devices
# ============================================================================

set -u
export LC_ALL=C
export LANG=C
export NCURSES_NO_UTF8_ACS=1

# --- Defaults (per your preference) ---
BB_PARALLEL_DEFAULT=4
BB_OPTS_DEFAULT="-w -p 2 -b 4096 -c 10240"

# --- Globals ---
TS="$(date +%Y%m%d_%H%M)"
BASE_DIR="/var/log/hddtest/${TS}"
CSV="${BASE_DIR}/9_summary_${TS}.csv"
MD="${BASE_DIR}/9_summary_${TS}.md"
DIFF_CSV="${BASE_DIR}/9_smart_diff_${TS}.csv"
TRACE="${BASE_DIR}/9_trace.log"

BB_PARALLEL="${BB_PARALLEL_DEFAULT}"
BB_OPTS="${BB_OPTS_DEFAULT}"

DRYRUN=0
DRYTAG=""
DESTRUCTIVE=0
RUN_PLAN=()
RUN_LABELS=()
SMART_ONLY_FLAG=0
DEMO=0
ALLOW_SMART_SIM_ON_LOOP=0

TARGETS=()
SELECTED_TEST_TOKENS=""

die(){ echo "[FATAL] $*" | tee -a "${TRACE}" >&2; exit 1; }
info(){ echo "[INFO]  $*" | tee -a "${TRACE}"; }
warn(){ echo "[WARN]  $*" | tee -a "${TRACE}"; }
dry_label(){ [ "${DRYRUN}" -eq 1 ] && echo " (DRY RUN)" || true; }

parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n) DRYRUN=1 ;;
      --smart-only) SMART_ONLY_FLAG=1 ;;
      --badblocks-parallel) shift; BB_PARALLEL="${1:-$BB_PARALLEL_DEFAULT}" ;;
      --demo) DEMO=1; ALLOW_SMART_SIM_ON_LOOP=1 ;;
    esac
    shift || true
  done
  [ "${DRYRUN}" -eq 1 ] && DRYTAG=" (DRY RUN)" || DRYTAG=""
}

require_root(){
  if [ "$(id -u)" -ne 0 ]; then
    echo "[INFO] Re-exec with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

ensure_dirs(){
  mkdir -p "${BASE_DIR}" || die "Cannot create: ${BASE_DIR}"
  : > "${TRACE}"
  if [ ! -s "${CSV}" ]; then
    echo "timestamp,device,phase,result,PowerOnHours,GrownDefects,UncorrectedErrors,Temperature,logfile" > "${CSV}"
  fi
  if [ ! -s "${MD}" ]; then
    echo "# HDD Burn-in Summary (${TS})${DRYTAG}" > "${MD}"
    echo "" >> "${MD}"
    echo "| Device | Phase | Result | PowerOnHours | GrownDefects | UncorrectedErrors | Temperature | Log |" >> "${MD}"
    echo "|--------|-------|--------|--------------|--------------|-------------------|-------------|-----|" >> "${MD}"
  fi
  : > "${DIFF_CSV}"
}

apt_install_if_missing(){
  local req_bins=(smartctl badblocks lsblk findmnt whiptail zip lspci diff sha256sum losetup truncate tput)
  local missing_pkgs=()
  local b
  for b in "${req_bins[@]}"; do
    if ! command -v "$b" >/dev/null 2>&1; then
      case "$b" in
        smartctl)   missing_pkgs+=("smartmontools");;
        badblocks)  missing_pkgs+=("e2fsprogs");;
        lsblk|findmnt|losetup|truncate) missing_pkgs+=("util-linux");;
        tput)       missing_pkgs+=("ncurses-bin");;
        whiptail)   missing_pkgs+=("whiptail");;
        zip)        missing_pkgs+=("zip");;
        lspci)      missing_pkgs+=("pciutils");;
        diff)       missing_pkgs+=("diffutils");;
        sha256sum)  missing_pkgs+=("coreutils");;
      esac
    fi
  done
  if [ ${#missing_pkgs[@]} -gt 0 ]; then
    info "Installing: ${missing_pkgs[*]}"
    apt-get update -y || die "apt update failed"
    apt-get install -y "${missing_pkgs[@]}" || die "apt install failed"
  fi
}

root_device(){
  local src; src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  echo "${src}" | sed -E 's/p?[0-9]+$//'
}

mounted_parents(){
  lsblk -P -o NAME,MOUNTPOINT | awk '
  {
    name=""; mpt="";
    for(i=1;i<=NF;i++){ split($i,a,"="); k=a[1]; v=a[2]; gsub(/^"|"$/, "", v);
      if(k=="NAME") name=v; else if(k=="MOUNTPOINT") mpt=v; }
    if(mpt!=""){
      parent=name; gsub(/p[0-9]+$/,"",parent); gsub(/[0-9]+$/,"",parent);
      print "/dev/" parent;
    }
  }' | sort -u
}

list_all_disks_pairs(){
  lsblk -d -P -o NAME,SIZE,MODEL,SERIAL,TRAN,TYPE | awk '
  {
    name=size=model=serial=tran=type="";
    for(i=1;i<=NF;i++){ split($i,a,"="); k=a[1]; v=a[2]; gsub(/^"|"$/,"",v);
      if(k=="NAME") name=v; else if(k=="SIZE") size=v; else if(k=="MODEL") model=v;
      else if(k=="SERIAL") serial=v; else if(k=="TRAN") tran=v; else if(k=="TYPE") type=v; }
    if(type=="disk"){
      dev="/dev/" name;
      printf "%s|%s  %s  %s  %s\n", dev, size, tran, model, serial;
    }
  }'
}

get_transport(){ lsblk -ndo TRAN "$1" 2>/dev/null | head -1; }
is_loop_dev(){ [[ "$1" == /dev/loop* ]] ; }

build_candidate_list(){
  local rootd; rootd="$(root_device)"
  local mounted; mounted="$(mounted_parents | tr '\n' ' ')"
  local out=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    local dev="${row%%|*}" label="${row#*|}"
    if [ -n "${rootd}" ] && [ "${dev}" = "${rootd}" ]; then continue; fi
    if grep -qw "${dev}" <<<"${mounted}"; then continue; fi
    out+="${dev}|${label}"$'\n'
  done < <(list_all_disks_pairs)
  printf "%s" "${out}"
}

# --- UI helpers (fits 80x24) ---
ui_dims(){ # echo H W LH
  local cols lines; cols=$(tput cols 2>/dev/null || echo 80); lines=$(tput lines 2>/dev/null || echo 24)
  local W=$((cols-6)); [ $W -gt 90 ] && W=90; [ $W -lt 60 ] && W=60
  local H=$((lines-4)); [ $H -gt 20 ] && H=20; [ $H -lt 14 ] && H=14
  local LH=$((H-8));   [ $LH -lt 8 ] && LH=8; [ $LH -gt 12 ] && LH=12
  echo "$H $W $LH"
}

title(){ echo "HDD Acceptance Test${DRYTAG}"; }
ui_msgbox(){ read H W _ < <(ui_dims); whiptail --title "$(title)" --ok-button "OK" --msgbox "$1" "$H" "$W"; }
ui_yesno(){ read H W _ < <(ui_dims); whiptail --title "$(title)" --yes-button "${2:-Yes}" --no-button "${3:-Back}" --yesno "$1" "$H" "$W"; }
ui_checklist(){ read H W LH < <(ui_dims); whiptail --title "$(title)" --ok-button "Next" --cancel-button "Back" --checklist "$1" "$H" "$W" "$LH" "${@:2}" 3>&1 1>&2 2>&3; }
ui_radiolist(){ read H W LH < <(ui_dims); whiptail --title "$(title)" --ok-button "Select" --cancel-button "Back" --radiolist "$1" "$H" "$W" "$LH" "${@:2}" 3>&1 1>&2 2>&3; }
ui_textbox(){ read H W _ < <(ui_dims); whiptail --title "$(title)" --textbox "$1" "$H" "$W"; }

splash(){
  ui_msgbox \
"HDD/SAS burn-in (sequence)
0) Full SMART baseline
1) SMART Short
2) badblocks (destructive, 2 passes, 4K, 10240)
3) SMART Long
4) Full SMART after tests
5) SMART diff (0 vs 4)

Output dir: ${BASE_DIR}
OS/mounted disks are excluded.
$( [ ${DRYRUN} -eq 1 ] && echo 'NOTE: DRY RUN - no device I/O.' )"
}

select_disks(){
  local candidates; candidates="$(build_candidate_list)"
  [ -z "${candidates}" ] && die "No candidate disks (OS/mounted are excluded)."
  local args=()
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    local dev="${row%%|*}" label="${row#*|}"
    args+=("${dev}" "${label}" "OFF")
  done <<< "${candidates}"

  while :; do
    local sel; sel=$(ui_checklist \
"Select target disks (SPACE to toggle). BADBLOCKS will erase data if chosen.
$( [ ${DRYRUN} -eq 1 ] && echo 'NOTE: DRY RUN - logs only, no I/O.' )" \
      "${args[@]}")
    case $? in
      0)
        sel="$(echo "${sel}" | sed 's/"//g')"
        mapfile -t TARGETS < <(tr ' ' '\n' <<< "${sel}")
        if [ ${#TARGETS[@]} -gt 0 ]; then
          info "Selected devices: ${TARGETS[*]}"
          return 0
        fi
        ui_msgbox "No disks selected. Please select at least one."
        ;;
      1|255)
        TARGETS=( "__BACK__" ); return 0 ;;
    esac
  done
}

select_mode(){
  while :; do
    local sel; sel=$(ui_radiolist \
"Choose operation mode:
 - Test mode (choose tests): run burn-in or parts of it
 - SMART report only: collect current SMART (sequence 0 only)" \
      "MODE_TESTS"       "Test mode (choose tests)"  "ON" \
      "MODE_SMART_ONLY"  "SMART report only"         "OFF")
    case $? in
      0) echo "${sel}"; return 0 ;;
      1|255) echo "__BACK__"; return 0 ;;
    esac
  done
}

select_tests(){
  local args=(
    "FULL_ALL"    "Run ALL (0..5) - includes destructive badblocks" "OFF"
    "SMART_PRE"   "0) Full SMART baseline"                          "OFF"
    "SMART_SHORT" "1) SMART Short self-test"                        "OFF"
    "BADBLOCKS"   "2) badblocks (destructive write/read)"           "OFF"
    "SMART_LONG"  "3) SMART Long self-test"                         "OFF"
    "SMART_POST"  "4) Full SMART after tests"                       "OFF"
    "SMART_DIFF"  "5) SMART diff (requires 0 and 4)"                "OFF"
  )
  while :; do
    local sel; sel=$(ui_checklist \
"Choose tests (SPACE to toggle). Multiple selections allowed.
Tip: If SMART_DIFF is selected, 0 and 4 will be auto-added.
FULL_ALL is exclusive and overrides other choices." \
      "${args[@]}")
    case $? in
      0) sel="$(echo "${sel}" | sed 's/"//g')"; echo "${sel}"; return 0 ;;
      1|255) echo "__BACK__"; return 0 ;;
    esac
  done
}

has_seq(){ local t="$1" s; for s in "${RUN_PLAN[@]}"; do [ "$s" = "$t" ] && return 0; done; return 1; }

build_plan_from_tests(){
  local tokens="$*"; SELECTED_TEST_TOKENS="${tokens}"
  local plan=() labels=()
  if grep -qw "FULL_ALL" <<<"${tokens}"; then
    plan=(0 1 2 3 4 5)
  else
    grep -qw "SMART_PRE"   <<<"${tokens}" && plan+=("0")
    grep -qw "SMART_SHORT" <<<"${tokens}" && plan+=("1")
    grep -qw "BADBLOCKS"   <<<"${tokens}" && plan+=("2")
    grep -qw "SMART_LONG"  <<<"${tokens}" && plan+=("3")
    grep -qw "SMART_POST"  <<<"${tokens}" && plan+=("4")
    if grep -qw "SMART_DIFF" <<<"${tokens}"; then
      plan+=("5")
      [[ " ${plan[*]} " =~ " 0 " ]] || plan+=("0")
      [[ " ${plan[*]} " =~ " 4 " ]] || plan+=("4")
    fi
  fi
  local OLDIFS="$IFS"; IFS=$'\n'
  plan=($(printf "%s\n" "${plan[@]}" | sort -n | uniq))
  IFS="$OLDIFS"

  local s; labels=()
  for s in "${plan[@]}"; do
    case "$s" in
      0) labels+=("0:SMART_PRE");;
      1) labels+=("1:SMART_SHORT");;
      2) labels+=("2:BADBLOCKS");;
      3) labels+=("3:SMART_LONG");;
      4) labels+=("4:SMART_POST");;
      5) labels+=("5:SMART_DIFF");;
    esac
  done
  RUN_PLAN=("${plan[@]}")
  RUN_LABELS=("${labels[@]}")
  DESTRUCTIVE=0; for s in "${RUN_PLAN[@]}"; do [ "$s" = "2" ] && { DESTRUCTIVE=1; break; }; done
  info "Plan seq: $(printf '%s ' "${RUN_PLAN[@]}")"
}

# --- Confirm with Details (scrollable) ---
confirm_plan(){
  local count="${#TARGETS[@]}"
  local preview="$(printf "%s " "${TARGETS[@]:0:3}")"
  [ "${count}" -gt 3 ] && preview="${preview}... (+$((count-3)) more)"
  local plan_text; plan_text="$(printf "%s\n" "${RUN_LABELS[@]}")"

  while :; do
    local choice; choice=$(ui_radiolist \
"Targets (${count}): ${preview}
Plan (sequence):
${plan_text}

$( [ ${DESTRUCTIVE} -eq 1 ] && echo 'WARNING: Includes badblocks (destructive).' )
$( [ ${DRYRUN} -eq 1 ] && echo 'NOTE: DRY RUN - no device I/O.' )

Select action:" \
      "RUN"     "Run now"                         "ON" \
      "DETAILS" "Show full details (scrollable)"  "OFF" \
      "BACK"    "Go back"                         "OFF")
    case $? in
      0)
        case "${choice}" in
          RUN) return 0 ;;
          DETAILS)
            local tmp="${BASE_DIR}/_confirm_details.txt"
            {
              echo "=== Targets (${count}) ==="
              printf "%s\n" "${TARGETS[@]}"
              echo
              echo "=== Plan (sequence) ==="
              printf "%s\n" "${RUN_LABELS[@]}"
              echo
              echo "Selected tokens: ${SELECTED_TEST_TOKENS:-<none>}"
              echo "Destructive(badblocks): ${DESTRUCTIVE}"
              echo "Dry-run: ${DRYRUN}"
            } > "${tmp}"
            ui_textbox "${tmp}"
            ;;
          BACK) return 1 ;;
        esac
        ;;
      1|255) return 1 ;;
    esac
  done
}

confirm_destruction_if_needed(){
  [ "${DESTRUCTIVE}" -eq 0 ] && return 0
  local devs; devs="$(printf "%s\n" "${TARGETS[@]}")"
  local msg="DESTRUCTIVE TEST WARNING!

The following disks will be ERASED by badblocks:
${devs}

$( [ ${DRYRUN} -eq 1 ] && echo 'NOTE: DRY RUN is enabled. No device I/O.' )

Proceed?"
  ui_yesno "${msg}" "Proceed" "Back"
}

# --- SMART helpers ---
smart_start_and_eta(){
  local dev="$1" type="$2" log="$3"
  local out rc
  if [ "${type}" = "short" ]; then
    out="$(smartctl -t short -d auto "${dev}" 2>&1)"; rc=$?
  else
    out="$(smartctl -t long  -d auto "${dev}" 2>&1)"; rc=$?
  fi
  echo "${out}" >> "${log}"
  local eta=0
  if grep -qi "Please wait" <<< "${out}"; then
    if [[ "${out}" =~ ([0-9]+)[[:space:]]*seconds ]]; then
      eta="${BASHREMATCH[1]}"
    elif [[ "${out}" =~ ([0-9]+)[[:space:]]*minutes ]]; then
      eta=$(( ${BASHREMATCH[1]} * 60 ))
    fi
  fi
  echo "${eta}"
  return $rc
}
smart_in_progress(){
  smartctl -a -d auto "${1}" 2>/dev/null | \
    grep -Eiq 'Self[- ]?test (execution )?status.*in progress|Self[- ]?test( routine)? in progress|Background (short|long|extended) self[- ]?test in progress'
}
smart_snapshot(){ smartctl -a -d auto "$1" >> "$3" 2>&1 || true; }
smart_extra(){
  local dev="$1" log="$2" tran="$3"
  {
    echo "--- smartctl -H ---";             smartctl -H -d auto "${dev}" || true
    echo "--- smartctl -l error ---";       smartctl -l error -d auto "${dev}" || true
    echo "--- smartctl -l selftest ---";    smartctl -l selftest -d auto "${dev}" || true
    echo "--- smartctl -x ---";             smartctl -x -d auto "${dev}" || true
    if [ "${tran}" = "sas" ] || [ "${tran}" = "scsi" ]; then
      echo "--- smartctl(SCSI) extras ---"
      smartctl -a -d scsi "${dev}" || true
      smartctl -x -d scsi "${dev}" || true
      smartctl -H -d scsi "${dev}" || true
      smartctl -l error -d scsi "${dev}" || true
      smartctl -l selftest -d scsi "${dev}" || true
    fi
  } >> "${log}" 2>&1
}
smart_wait_for_completion(){
  [ "${DRYRUN}" -eq 1 ] && return 0
  local dev="$1" kind="$2" eta="$3" waited=0
  local poll=30 max=$(( eta>0 ? eta+120 : 7200 ))
  sleep 10
  while :; do
    if smart_in_progress "${dev}"; then
      sleep "${poll}"; waited=$(( waited + poll ))
      if [ "${waited}" -ge "${max}" ]; then
        warn "${dev}: ${kind} wait reached cap (${max}s); continue."
        break
      fi
    else
      sleep 5
      smart_in_progress "${dev}" || break
    fi
  done
}

# --- parsing helpers (SAS/SCSI-aware) ---
scsi_uncorrected_sum(){
  awk '
    BEGIN{inerr=0; readu=""; writeu=""}
    /Error counter log:/ {inerr=1; next}
    inerr && /^read:/  {readu=$NF}
    inerr && /^write:/ {writeu=$NF; exit}
    END{
      if (readu ~ /^[0-9]+$/ && writeu ~ /^[0-9]+$/) { print readu+writeu }
      else if (readu ~ /^[0-9]+$/) { print readu }
      else if (writeu ~ /^[0-9]+$/) { print writeu }
      else { print "N/A" }
    }' "$1"
}
extract_field_block(){
  local file="$1"
  local poh defects uncorr temp overall
  poh="$(grep -m1 -E 'number of hours powered up|Power_On_Hours' "$file" | awk '{for(i=1;i<=NF;i++) if ($i ~ /[0-9]+(\.[0-9]+)?/) {print $i; exit}}')"
  defects="$(grep -m1 -E 'Grown Defect|Elements in grown defect list|Grown defects during certifi' "$file" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')"
  temp="$(grep -m1 -E 'Current Drive Temperature|Temperature_Celsius' "$file" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')"
  overall="$(grep -m1 -E 'SMART overall-health self-assessment test result|SMART Health Status' "$file" | sed -E 's/.*result: *//; s/.*Status: *//')"
  uncorr="$(scsi_uncorrected_sum "$file")"
  if [ -z "${uncorr}" ] || [ "${uncorr}" = "N/A" ]; then
    uncorr="$(grep -A5 -m1 -i 'Error counter log' "$file" | grep -m1 -E 'uncorrect(ed)?' | awk '{for(i=NF;i>=1;i--) if ($i ~ /^[0-9]+$/){print $i; exit}}')"
    [ -z "${uncorr}" ] && uncorr="N/A"
  fi
  echo "${poh:-N/A},${defects:-N/A},${uncorr:-N/A},${temp:-N/A},${overall:-N/A}"
}
extract_summary_fields(){
  local file="$1"
  local poh defects uncorr temp
  poh="$(grep -m1 -E 'number of hours powered up|Power_On_Hours' "$file" | awk '{for(i=1;i<=NF;i++) if ($i ~ /[0-9]+(\.[0-9]+)?/) {print $i; exit}}')"
  defects="$(grep -m1 -E 'Grown Defect|Elements in grown defect list|Grown defects during certifi' "$file" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')"
  temp="$(grep -m1 -E 'Current Drive Temperature|Temperature_Celsius' "$file" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')"
  uncorr="$(scsi_uncorrected_sum "$file")"
  [ -z "${uncorr}" ] && uncorr="N/A"
  echo "${poh:-N/A},${defects:-N/A},${uncorr:-N/A},${temp:-N/A}"
}

ensure_nonempty_log(){ local log="$1" phase="$2" dev="$3"; [ -s "${log}" ] || echo "[WARN] ${phase} produced no tool output on ${dev}." >> "${log}"; }
append_csv_row(){ echo "$(date +%F_%T),$1,$2,$3,$5,$6,$7,$8,$4" >> "${CSV}"; }
append_md_row(){ echo "| $1 | $2 | $3 | $4 | $5 | $6 | $7 | $(basename "$8") |" >> "${MD}"; }

simulate_smart_full(){
  local dev="$1" log="$2" tag="$3"; local poh="12345.67" temp="33"
  [ "$tag" = "POST" ] && poh="12346.00" && temp="34"
  cat >> "${log}" <<EOF
=== SIMULATED FULL SMART (${tag}) for ${dev} at $(date) ===
Device: SIMULATED MODEL  SAS
SMART overall-health self-assessment test result: PASSED
number of hours powered up = ${poh}
Current Drive Temperature:     ${temp} C
Elements in grown defect list: 0
Error counter log:
read: 0 0 0 0 0 0 0
write: 0 0 0 0 0 0 0
=== END SIMULATED ===
EOF
}

# --- Phase runners ---
do_pre_smart_all(){
  info "Seq0: SMART baseline$(dry_label)"
  local dev
  for dev in "${TARGETS[@]}"; do (
    local b log tran fields poh def unc tmp
    b=$(basename "${dev}"); log="${BASE_DIR}/0_smart_pre_${b}.log"; tran="$(get_transport "${dev}")"
    echo "=== SMART FULL BASELINE ${dev} $(date) ===" > "${log}"
    if [ "${DRYRUN}" -eq 1 ] || ( is_loop_dev "${dev}" && [ "${ALLOW_SMART_SIM_ON_LOOP}" -eq 1 ] ); then
      simulate_smart_full "${dev}" "${log}" "PRE"
    else
      smart_snapshot "${dev}" "pre/auto" "${log}"
      smart_extra "${dev}" "${log}" "${tran}"
    fi
    ensure_nonempty_log "${log}" "SMART_PRE" "${dev}"
    fields="$(extract_summary_fields "${log}")"; IFS=, read -r poh def unc tmp <<< "${fields}"
    append_csv_row "${dev}" "SMART_PRE" "done" "${log}" "${poh}" "${def}" "${unc}" "${tmp}"
    append_md_row  "${dev}" "SMART_PRE" "done" "${poh}" "${def}" "${unc}" "${tmp}" "${log}"
  ) & done; wait
}

do_short_all(){
  info "Seq1: SMART Short$(dry_label)"
  local dev
  for dev in "${TARGETS[@]}"; do (
    local b log tran fields poh def unc tmp eta
    b=$(basename "${dev}"); log="${BASE_DIR}/1_smart_short_${b}.log"; tran="$(get_transport "${dev}")"
    echo "=== SMART SHORT START ${dev} $(date) ===" > "${log}"
    if [ "${DRYRUN}" -eq 1 ] || ( is_loop_dev "${dev}" && [ "${ALLOW_SMART_SIM_ON_LOOP}" -eq 1 ] ); then
      simulate_smart_full "${dev}" "${log}" "SHORT"
    else
      smart_snapshot "${dev}" "short/baseline" "${log}"
      eta="$(smart_start_and_eta "${dev}" "short" "${log}")"
      smart_wait_for_completion "${dev}" "short" "${eta}"
      smart_snapshot "${dev}" "short/post" "${log}"
      smart_extra "${dev}" "${log}" "${tran}"
    fi
    ensure_nonempty_log "${log}" "SMART_SHORT" "${dev}"
    fields="$(extract_summary_fields "${log}")"; IFS=, read -r poh def unc tmp <<< "${fields}"
    append_csv_row "${dev}" "SMART_SHORT" "done" "${log}" "${poh}" "${def}" "${unc}" "${tmp}"
    append_md_row  "${dev}" "SMART_SHORT" "done" "${poh}" "${def}" "${unc}" "${tmp}" "${log}"
  ) & done; wait
}

do_badblocks_parallel(){
  info "Seq2: badblocks P=${BB_PARALLEL}$(dry_label) opts=${BB_OPTS}"
  export BASE_DIR BB_OPTS DRYRUN
  run_bb(){
    local dev="$1"
    local b=$(basename "${dev}")
    local log="${BASE_DIR}/2_badblocks_${b}.log"
    local badlist="${BASE_DIR}/2_badblocks_badlist_${b}.txt"
    if [ "${DRYRUN}" -eq 1 ]; then
      echo "=== SIMULATED BADBLOCKS START ${dev} $(date) ===" > "${log}"
      echo "[dry-run] badblocks ${BB_OPTS} -o ${badlist} ${dev}" >> "${log}"
      echo "=== SIMULATED BADBLOCKS END ${dev} $(date) rc=0 ===" >> "${log}"
      : > "${badlist}"
      return 0
    fi
    echo "=== BADBLOCKS START ${dev} $(date) ===" > "${log}"
    badblocks ${BB_OPTS} -o "${badlist}" "${dev}" >> "${log}" 2>&1; local rc=$?
    echo "=== BADBLOCKS END ${dev} $(date) rc=${rc} ===" >> "${log}"
    [ -s "${log}" ] || echo "[WARN] badblocks produced no output on ${dev}" >> "${log}"
    return $rc
  }
  export -f run_bb
  printf "%s\0" "${TARGETS[@]}" | xargs -0 -I{} -P"${BB_PARALLEL}" bash -c 'run_bb "$@"' _ {}
}

do_long_all(){
  info "Seq3: SMART Long$(dry_label)"
  local dev
  for dev in "${TARGETS[@]}"; do (
    local b log tran fields poh def unc tmp eta
    b=$(basename "${dev}"); log="${BASE_DIR}/3_smart_long_${b}.log"; tran="$(get_transport "${dev}")"
    echo "=== SMART LONG START ${dev} $(date) ===" > "${log}"
    if [ "${DRYRUN}" -eq 1 ] || ( is_loop_dev "${dev}" && [ "${ALLOW_SMART_SIM_ON_LOOP}" -eq 1 ] ); then
      simulate_smart_full "${dev}" "${log}" "LONG"
    else
      smart_snapshot "${dev}" "long/baseline" "${log}"
      eta="$(smart_start_and_eta "${dev}" "long" "${log}")"
      smart_wait_for_completion "${dev}" "long" "${eta}"
      smart_snapshot "${dev}" "long/post" "${log}"
      smart_extra "${dev}" "${log}" "${tran}"
    fi
    ensure_nonempty_log "${log}" "SMART_LONG" "${dev}"
    fields="$(extract_summary_fields "${log}")"; IFS=, read -r poh def unc tmp <<< "${fields}"
    append_csv_row "${dev}" "SMART_LONG" "done" "${log}" "${poh}" "${def}" "${unc}" "${tmp}"
    append_md_row  "${dev}" "SMART_LONG" "done" "${poh}" "${def}" "${unc}" "${tmp}" "${log}"
  ) & done; wait
}

do_post_smart_all(){
  info "Seq4: SMART after tests$(dry_label)"
  local dev
  for dev in "${TARGETS[@]}"; do (
    local b log tran
    b=$(basename "${dev}"); log="${BASE_DIR}/4_smart_post_${b}.log"; tran="$(get_transport "${dev}")"
    echo "=== SMART FULL POST ${dev} $(date) ===" > "${log}"
    if [ "${DRYRUN}" -eq 1 ] || ( is_loop_dev "${dev}" && [ "${ALLOW_SMART_SIM_ON_LOOP}" -eq 1 ] ); then
      simulate_smart_full "${dev}" "${log}" "POST"
    else
      smart_snapshot "${dev}" "post/auto" "${log}"
      smart_extra "${dev}" "${log}" "${tran}"
    fi
    ensure_nonempty_log "${log}" "SMART_POST" "${dev}"
  ) & done; wait
}

do_smart_diff_all(){
  info "Seq5: SMART DIFF (0 vs 4)"
  if [ ! -s "${DIFF_CSV}" ]; then
    echo "device,POH_before,POH_after,POH_delta,GrownDefects_before,GrownDefects_after,GD_delta,Uncorr_before,Uncorr_after,Uncorr_delta,Temp_before,Temp_after,Temp_delta,Overall_before,Overall_after" > "${DIFF_CSV}"
  fi
  numa(){ awk -v b="$1" -v a="$2" 'BEGIN{ if (b ~ /^[0-9.]+$/ && a ~ /^[0-9.]+$/){ printf("%.2f", a-b) } else { print "N/A" } }'; }
  local dev
  for dev in "${TARGETS[@]}"; do (
    local b pre post diffout pre_blk post_blk poh_b def_b unc_b tmp_b ov_b poh_a def_a unc_a tmp_a ov_a dpoh ddef dunc dtmp
    b=$(basename "${dev}"); pre="${BASE_DIR}/0_smart_pre_${b}.log"; post="${BASE_DIR}/4_smart_post_${b}.log"; diffout="${BASE_DIR}/5_smart_diff_${b}.txt"
    if [ -f "${pre}" ] && [ -f "${post}" ]; then
      diff -u "${pre}" "${post}" > "${diffout}" 2>/dev/null || true
      pre_blk="$(extract_field_block "${pre}")"; post_blk="$(extract_field_block "${post}")"
      IFS=, read -r poh_b def_b unc_b tmp_b ov_b <<< "${pre_blk}"
      IFS=, read -r poh_a def_a unc_a tmp_a ov_a <<< "${post_blk}"
      dpoh="$(numa "${poh_b}" "${poh_a}")"; ddef="$(numa "${def_b}" "${def_a}")"; dunc="$(numa "${unc_b}" "${unc_a}")"; dtmp="$(numa "${tmp_b}" "${tmp_a}")"
      echo "$dev,$poh_b,$poh_a,$dpoh,$def_b,$def_a,$ddef,$unc_b,$unc_a,$dunc,$tmp_b,$tmp_a,$dtmp,$ov_b,$ov_a" >> "${DIFF_CSV}"
    else
      echo "Pre/Post SMART logs missing; diff skipped." > "${diffout}"
    fi
  ) & done; wait
}

# --- Metadata & archives ---
generate_env_and_selection(){
  {
    echo "=== Environment Snapshot (${TS}) ==="
    echo "--- uname -a ---"; uname -a
    echo "--- lspci -nn | grep -Ei 'sas|raid|scsi|lsi|broadcom|avago' ---"; lspci -nn | grep -Ei 'sas|raid|scsi|lsi|broadcom|avago' || true
    echo "--- smartctl --version ---"; smartctl --version
    if has_seq 2; then
      echo "--- badblocks -V ---"; ( badblocks -V || echo "badblocks -V: N/A or unsupported" )
    else
      echo "--- badblocks version ---"; echo "badblocks: skipped (badblocks test not selected)"
    fi
    echo "--- lsblk -a -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,TRAN ---"
    lsblk -a -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,TRAN
  } > "${BASE_DIR}/0_env.txt" 2>&1
  printf "%s\n" "${TARGETS[@]}" > "${BASE_DIR}/0_selected_disks.txt"
}

generate_plan_file(){
  {
    echo "Timestamp: ${TS}"
    echo "Dry-run  : ${DRYRUN}"
    echo "Destructive(badblocks): ${DESTRUCTIVE}"
    echo "Selected tokens: ${SELECTED_TEST_TOKENS:-<none>}"
    echo "Plan (sequence numbers): $(printf '%s ' "${RUN_PLAN[@]}")"
    echo "Plan labels:"; printf " - %s\n" "${RUN_LABELS[@]}"
    echo "Targets:"; printf " - %s\n" "${TARGETS[@]}"
  } > "${BASE_DIR}/9_plan.txt"
}

generate_all_concat(){
  ( cd "${BASE_DIR}" && cat 0_env.txt 0_selected_disks.txt 0_smart_pre_* 1_smart_short_* 2_badblocks_* 3_smart_long_* 4_smart_post_* 5_smart_diff_* 2>/dev/null ) > "${BASE_DIR}/8_all_logs_concat.txt" || true
}

generate_listings_and_hashes(){
  ls -laR "${BASE_DIR}" > "${BASE_DIR}/9_filelist_lslR.txt"
  find "${BASE_DIR}" -type f | sort > "${BASE_DIR}/9_filelist_paths.txt"
  ( cd "${BASE_DIR}" && sha256sum $(find . -maxdepth 1 -type f -printf "%P\n" 2>/dev/null) > 9_sha256sums_root.txt ) 2>/dev/null || true
  ( cd "${BASE_DIR}" && sha256sum $(find . -type f -printf "%P\n" 2>/dev/null) > 9_sha256sums_all.txt ) 2>/dev/null || true
}

make_archives_into_basedir(){
  local parent tgz zipf
  parent="$(dirname "${BASE_DIR}")"
  tgz="${parent}/9_hddtest_${TS}.tar.gz"; zipf="${parent}/9_hddtest_${TS}.zip"
  ( cd "${parent}" && tar czf "$(basename "${tgz}")" "${TS}" ) || warn "tar.gz creation failed"
  ( cd "${parent}" && zip -r -q "$(basename "${zipf}")" "${TS}" ) || warn "zip creation failed"
  [ -f "${tgz}" ] && mv -f "${tgz}" "${BASE_DIR}/"
  [ -f "${zipf}" ] && mv -f "${zipf}" "${BASE_DIR}/"
  ( cd "${BASE_DIR}" && sha256sum "9_hddtest_${TS}.tar.gz" 2>/dev/null >> 9_sha256sums_root.txt ) || true
  ( cd "${BASE_DIR}" && sha256sum "9_hddtest_${TS}.zip"    2>/dev/null >> 9_sha256sums_root.txt ) || true
}

finish_screen(){
  local flagged="0"
  if ls "${BASE_DIR}"/2_badblocks_badlist_* >/dev/null 2>&1; then
    if grep -q . "${BASE_DIR}"/2_badblocks_badlist_* 2>/dev/null; then flagged="1"; fi
  fi
  ui_msgbox \
"All tasks finished${DRYTAG}.

Key outputs:
- ${CSV}
- ${MD}
- ${DIFF_CSV}
- ${BASE_DIR}/9_plan.txt
- ${BASE_DIR}/8_all_logs_concat.txt
- ${BASE_DIR}/9_trace.log
- ${BASE_DIR}/9_hddtest_${TS}.tar.gz
- ${BASE_DIR}/9_hddtest_${TS}.zip

Bad sectors detected: ${flagged}"
}

# --- Demo helpers (loop devices) ---
demo_setup(){
  [ "${DEMO}" -eq 1 ] || return 0
  info "Demo: creating loop devices"
  truncate -s 200M /tmp/hddtest_demo0.img
  truncate -s 200M /tmp/hddtest_demo1.img
  losetup -fP /tmp/hddtest_demo0.img
  losetup -fP /tmp/hddtest_demo1.img
}
demo_teardown(){
  [ "${DEMO}" -eq 1 ] || return 0
  info "Demo: removing loop devices"
  losetup -D
  rm -f /tmp/hddtest_demo0.img /tmp/hddtest_demo1.img
}

# --- State machine ---
main_flow(){
  splash
  local state="DISK"
  local mode="" tests=""

  while :; do
    case "${state}" in
      DISK)
        select_disks
        if [ "${TARGETS[*]:-}" = "__BACK__" ]; then
          ui_yesno "Exit the program?" "Exit" "Back" && exit 0 || continue
        fi
        state="MODE"
        ;;
      MODE)
        if [ "${SMART_ONLY_FLAG}" -eq 1 ]; then
          mode="MODE_SMART_ONLY"
        else
          mode="$(select_mode)"
          [ "${mode}" = "__BACK__" ] && { state="DISK"; continue; }
        fi
        if [ "${mode}" = "MODE_SMART_ONLY" ]; then
          RUN_PLAN=(0); RUN_LABELS=("0:SMART_PRE"); DESTRUCTIVE=0
          state="CONFIRM"
        else
          state="TESTS"
        fi
        ;;
      TESTS)
        tests="$(select_tests)"
        [ "${tests}" = "__BACK__" ] && { state="MODE"; continue; }
        build_plan_from_tests ${tests}
        state="CONFIRM"
        ;;
      CONFIRM)
        generate_plan_file
        if ! confirm_plan; then
          if [ "${mode}" = "MODE_SMART_ONLY" ]; then state="MODE"; else state="TESTS"; fi
          continue
        fi
        if [ "${DESTRUCTIVE}" -eq 1 ]; then
          if ! confirm_destruction_if_needed; then state="TESTS"; continue; fi
        fi
        state="RUN"
        ;;
      RUN)
        generate_env_and_selection
        demo_setup

        has_seq 0 && do_pre_smart_all
        has_seq 1 && do_short_all
        has_seq 2 && do_badblocks_parallel
        has_seq 3 && do_long_all
        has_seq 4 && do_post_smart_all
        has_seq 5 && do_smart_diff_all

        generate_all_concat
        generate_listings_and_hashes
        make_archives_into_basedir
        demo_teardown
        finish_screen
        exit 0
        ;;
    esac
  done
}

main(){
  local ORIG_ARGS=("$@")
  parse_args "$@"
  require_root "${ORIG_ARGS[@]}"
  ensure_dirs
  apt_install_if_missing
  main_flow
}
main "$@"

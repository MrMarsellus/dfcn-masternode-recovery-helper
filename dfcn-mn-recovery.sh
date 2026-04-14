#!/usr/bin/env bash

set -u

SCRIPT_VERSION="0.2.0"

DEFAULT_DEFCON_USER="defcon"
DEFAULT_DEFCON_HOME="/home/defcon"
DEFAULT_DATA_DIR="/home/defcon/.defcon"
DEFAULT_CONF_FILE="/home/defcon/.defcon/defcon.conf"
DEFAULT_CLI="/usr/local/bin/defcon-cli"
DEFAULT_DAEMON="/usr/local/bin/defcond"
DEFAULT_SERVICE="defcond"
DEFAULT_PORT="8192"
DEFAULT_ADDNODE_FILE="./trusted_addnodes.txt"

MANAGED_START="# BEGIN DFCN RECOVERY HELPER MANAGED ADDNODES"
MANAGED_END="# END DFCN RECOVERY HELPER MANAGED ADDNODES"

MAX_RANDOM_CANDIDATES=30
MAX_GOOD_ADDNODES=20

print_line() {
  echo "------------------------------------------------------------"
}

info() {
  echo "[INFO] $1"
}

warn() {
  echo "[WARN] $1"
}

error() {
  echo "[ERROR] $1"
}

success() {
  echo "[OK] $1"
}

ask_yes_no() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

run_cli() {
  "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" "$@"
}

show_intro() {
  print_line
  echo "DeFCoN Masternode Recovery Helper v${SCRIPT_VERSION}"
  echo "Cautious recovery helper for DeFCoN masternodes"
  print_line
  echo "This tool is designed to help recover a problematic masternode."
  echo "It does NOT guarantee that a PoSe-banned node will recover."
  echo "It will guide you carefully and ask before critical actions."
  print_line
}

show_defaults() {
  echo "Current defaults:"
  echo "DEFCON user     : ${DEFAULT_DEFCON_USER}"
  echo "DEFCON home     : ${DEFAULT_DEFCON_HOME}"
  echo "Data directory  : ${DEFAULT_DATA_DIR}"
  echo "Config file     : ${DEFAULT_CONF_FILE}"
  echo "CLI binary      : ${DEFAULT_CLI}"
  echo "Daemon binary   : ${DEFAULT_DAEMON}"
  echo "Service name    : ${DEFAULT_SERVICE}"
  echo "Default port    : ${DEFAULT_PORT}"
  echo "Addnode file    : ${DEFAULT_ADDNODE_FILE}"
  print_line
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Please run this script as root."
    exit 1
  fi
}

check_files() {
  if [ ! -f "${DEFAULT_ADDNODE_FILE}" ]; then
    error "trusted_addnodes.txt was not found in the current directory."
    echo "Place the file next to this script and run it again."
    exit 1
  fi

  if [ ! -f "${DEFAULT_CONF_FILE}" ]; then
    error "Config file not found at: ${DEFAULT_CONF_FILE}"
    exit 1
  fi
}

check_binaries() {
  if [ ! -x "${DEFAULT_CLI}" ]; then
    error "defcon-cli was not found or is not executable at: ${DEFAULT_CLI}"
    exit 1
  fi

  if [ ! -x "${DEFAULT_DAEMON}" ]; then
    error "defcond was not found or is not executable at: ${DEFAULT_DAEMON}"
    exit 1
  fi

  success "Required binaries were found."
}

load_addnodes() {
  ADDNODES=()

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"

    if [ -n "$line" ]; then
      ADDNODES+=("$line")
    fi
  done < "${DEFAULT_ADDNODE_FILE}"

  if [ "${#ADDNODES[@]}" -eq 0 ]; then
    warn "No trusted addnodes were found in ${DEFAULT_ADDNODE_FILE}."
    warn "Please add at least one trusted node before running recovery."
    exit 1
  fi
}

show_addnodes() {
  print_line
  echo "Trusted addnodes loaded from file:"
  for node in "${ADDNODES[@]}"; do
    echo " - ${node}"
  done
  print_line
}

validate_addnodes() {
  local invalid_count=0

  for node in "${ADDNODES[@]}"; do
    if ! echo "$node" | grep -Eq '^[a-zA-Z0-9._-]+:[0-9]+$'; then
      warn "Invalid addnode format: $node"
      invalid_count=$((invalid_count + 1))
    fi
  done

  if [ "$invalid_count" -gt 0 ]; then
    error "One or more addnodes have an invalid format."
    echo "Expected format: IP:PORT or HOSTNAME:PORT"
    exit 1
  fi

  success "All trusted addnodes have a valid basic format."
}

show_local_status() {
  print_line
  info "Checking local node status..."

  local blockcount="unknown"
  blockcount="$(run_cli getblockcount 2>/dev/null || echo "unavailable")"
  echo "Local block height : ${blockcount}"

  echo
  echo "Masternode status:"
  run_cli masternode status 2>/dev/null || warn "Could not read masternode status."

  echo
  echo "Masternode sync status:"
  run_cli mnsync status 2>/dev/null || warn "Could not read mnsync status."

  print_line
}

check_service_and_process() {
  print_line
  info "Checking service and daemon process..."

  if systemctl list-unit-files | grep -q "^${DEFAULT_SERVICE}\.service"; then
    echo "Service file found : ${DEFAULT_SERVICE}.service"

    if systemctl is-active --quiet "${DEFAULT_SERVICE}"; then
      echo "Service status     : active"
    else
      echo "Service status     : not active"
    fi
  else
    warn "Service file ${DEFAULT_SERVICE}.service was not found."
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    echo "Daemon process     : running"
    pgrep -af "${DEFAULT_DAEMON}"
  else
    echo "Daemon process     : not running"
  fi

  print_line
}

backup_conf() {
  local backup_file
  backup_file="${DEFAULT_CONF_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

  cp "${DEFAULT_CONF_FILE}" "${backup_file}"
  success "Backup created: ${backup_file}"
}

choose_mode() {
  print_line
  echo "Choose mode:"
  echo "1. Recovery mode"
  echo "2. Restore normal mode"
  print_line

  read -r -p "Enter 1 or 2: " SELECTED_MODE

  case "${SELECTED_MODE}" in
    1) MODE="recovery" ;;
    2) MODE="restore" ;;
    *)
      error "Invalid mode selected."
      exit 1
      ;;
  esac
}

pick_random_candidates() {
  CANDIDATES=()

  mapfile -t CANDIDATES < <(printf '%s\n' "${ADDNODES[@]}" | shuf | head -n "${MAX_RANDOM_CANDIDATES}")

  if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    error "No candidate addnodes were selected."
    exit 1
  fi

  print_line
  info "Random candidate addnodes selected for testing:"
  for node in "${CANDIDATES[@]}"; do
    echo " - ${node}"
  done
  print_line
}

check_addnode_candidates() {
  print_line
  info "Checking random trusted addnode candidates..."

  GOOD_ADDNODES=()
  BAD_ADDNODES=()

  for node in "${CANDIDATES[@]}"; do
    local host
    local port
    host="${node%:*}"
    port="${node##*:}"

    info "Testing ${node}"

    if ! timeout 5 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
      warn "Port check failed for ${node}"
      BAD_ADDNODES+=("${node}")
      continue
    fi

    run_cli addnode "${node}" onetry >/dev/null 2>&1 || true
    sleep 3

    if run_cli getpeerinfo 2>/dev/null | grep -q "${host}"; then
      success "Peer check passed for ${node}"
      GOOD_ADDNODES+=("${node}")
    else
      warn "Peer check failed for ${node}"
      BAD_ADDNODES+=("${node}")
    fi

    if [ "${#GOOD_ADDNODES[@]}" -ge "${MAX_GOOD_ADDNODES}" ]; then
      break
    fi
  done

  print_line
  echo "Good trusted addnodes:"
  for node in "${GOOD_ADDNODES[@]}"; do
    echo " - ${node}"
  done

  echo
  echo "Rejected addnodes:"
  for node in "${BAD_ADDNODES[@]}"; do
    echo " - ${node}"
  done
  print_line

  if [ "${#GOOD_ADDNODES[@]}" -eq 0 ]; then
    error "No usable trusted addnodes passed the checks."
    exit 1
  fi

  if [ "${#GOOD_ADDNODES[@]}" -lt 3 ]; then
    warn "Fewer than 3 good addnodes passed the checks."
    warn "Recovery can continue, but confidence is lower."
  fi

  success "Trusted addnode candidate checks completed."
}

stop_daemon_cautious() {
  print_line
  warn "The next step can stop the daemon and service."
  warn "This is required for cleanup or recovery actions."

  if ! ask_yes_no "Do you want to try stopping the masternode daemon now?"; then
    warn "Stop step skipped by user."
    return 0
  fi

  info "Trying systemctl stop..."
  systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl stop did not succeed."
  sleep 10

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    info "Trying RPC stop..."
    run_cli stop >/dev/null 2>&1 || warn "RPC stop did not succeed."
    sleep 5
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon is still running."

    if ask_yes_no "Do you want to try a normal kill on remaining daemon processes?"; then
      pkill -f "${DEFAULT_DAEMON}" || warn "Normal kill did not succeed."
      sleep 5
    fi
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon is still running after normal kill."

    if ask_yes_no "Do you want to try a hard kill (kill -9)?"; then
      pkill -9 -f "${DEFAULT_DAEMON}" || warn "Hard kill did not succeed."
      sleep 3
    fi
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    error "Daemon still appears to be running."
    warn "Please investigate manually before continuing."
    return 1
  fi

  success "Daemon appears to be stopped."
  return 0
}

remove_lock_file() {
  local lock_file="${DEFAULT_DATA_DIR}/.lock"

  if [ -f "${lock_file}" ]; then
    if ask_yes_no "A lock file was found. Remove it?"; then
      rm -f "${lock_file}"
      success "Lock file removed."
    else
      warn "Lock file was not removed."
    fi
  else
    info "No lock file found."
  fi
}

cleanup_recovery_files() {
  print_line
  warn "Cleanup can delete local blockchain, peer and cache data."
  warn "Use this only if you really want to rebuild local state."

  if ! ask_yes_no "Do you want to review cleanup targets now?"; then
    warn "Cleanup step skipped by user."
    return 0
  fi

  echo "Planned cleanup targets:"
  echo " - ${DEFAULT_DATA_DIR}/peers.dat"
  echo " - ${DEFAULT_DATA_DIR}/banlist.dat"
  echo " - ${DEFAULT_DATA_DIR}/mncache.dat"
  echo " - ${DEFAULT_DATA_DIR}/netfulfilled.dat"
  echo " - ${DEFAULT_DATA_DIR}/llmq"
  echo " - ${DEFAULT_DATA_DIR}/evodb"
  echo " - ${DEFAULT_DATA_DIR}/blocks"
  echo " - ${DEFAULT_DATA_DIR}/chainstate"
  echo " - ${DEFAULT_DATA_DIR}/indexes"
  print_line

  if ! ask_yes_no "Do you want to delete these recovery targets now?"; then
    warn "Cleanup cancelled by user."
    return 0
  fi

  rm -f "${DEFAULT_DATA_DIR}/peers.dat"
  rm -f "${DEFAULT_DATA_DIR}/banlist.dat"
  rm -f "${DEFAULT_DATA_DIR}/mncache.dat"
  rm -f "${DEFAULT_DATA_DIR}/netfulfilled.dat"
  rm -rf "${DEFAULT_DATA_DIR}/llmq"
  rm -rf "${DEFAULT_DATA_DIR}/evodb"
  rm -rf "${DEFAULT_DATA_DIR}/blocks"
  rm -rf "${DEFAULT_DATA_DIR}/chainstate"
  rm -rf "${DEFAULT_DATA_DIR}/indexes"

  success "Selected recovery files and directories were removed."
}

write_trusted_addnodes_to_conf() {
  print_line
  warn "The script can now write verified trusted addnodes to defcon.conf."

  if ! ask_yes_no "Do you want to update defcon.conf with the verified trusted addnodes?"; then
    warn "Config update skipped by user."
    return 0
  fi

  cp "${DEFAULT_CONF_FILE}" "${DEFAULT_CONF_FILE}.pre-managed.$(date +%Y%m%d-%H%M%S)"

  awk -v start="${MANAGED_START}" -v end="${MANAGED_END}" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "${DEFAULT_CONF_FILE}" | sed '/^addnode=/d' > "${DEFAULT_CONF_FILE}.tmp"

  {
    echo
    echo "${MANAGED_START}"
    for node in "${GOOD_ADDNODES[@]}"; do
      echo "addnode=${node}"
    done
    echo "${MANAGED_END}"
  } >> "${DEFAULT_CONF_FILE}.tmp"

  mv "${DEFAULT_CONF_FILE}.tmp" "${DEFAULT_CONF_FILE}"
  success "Verified trusted addnodes were written to defcon.conf."
}

restore_normal_mode_conf() {
  print_line
  warn "Restore mode will remove the recovery helper managed addnode section."

  if ! ask_yes_no "Do you want to remove the managed trusted addnode section now?"; then
    warn "Restore step skipped by user."
    return 0
  fi

  cp "${DEFAULT_CONF_FILE}" "${DEFAULT_CONF_FILE}.pre-restore.$(date +%Y%m%d-%H%M%S)"

  awk -v start="${MANAGED_START}" -v end="${MANAGED_END}" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "${DEFAULT_CONF_FILE}" > "${DEFAULT_CONF_FILE}.tmp"

  mv "${DEFAULT_CONF_FILE}.tmp" "${DEFAULT_CONF_FILE}"
  success "Managed trusted addnode section removed from defcon.conf."
}

start_daemon_cautious() {
  print_line
  warn "The script can now try to start the daemon again."

  if ! ask_yes_no "Do you want to start the daemon now?"; then
    warn "Start step skipped by user."
    return 0
  fi

  info "Trying systemctl start..."
  systemctl start "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl start did not succeed."
  sleep 5

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    success "Daemon appears to be running."
    return 0
  fi

  warn "Daemon does not appear to be running yet."
  warn "Trying manual daemon start..."

  "${DEFAULT_DAEMON}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" >/dev/null 2>&1 &
  sleep 5

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    success "Daemon appears to be running after manual start."
    return 0
  fi

  error "Daemon still does not appear to be running."
  return 1
}

show_protx_placeholder() {
  print_line
  echo "Controller wallet step:"
  echo
  echo "Run the following command in the controller wallet console after the VPS node is fully synced:"
  echo
  echo 'protx update_service "PROTX_HASH" "IP:8192" "BLS_SECRET_KEY" "" "FEE_SOURCE_ADDRESS"'
  echo
  echo "Important:"
  echo " - Run this in the controller wallet, not on the VPS."
  echo " - Wait for the ProTx transaction to be confirmed."
  echo " - Only then should you expect the masternode to recover from PoSe-banned state."
  print_line
}

interactive_monitoring_menu() {
  print_line
  echo "The node must now fully synchronize before you continue."
  echo "Use the following menu options to monitor sync progress."
  echo "Only continue with x when all of the following are true:"
  echo "  - Local block height matches the reference block height"
  echo "  - Masternode sync stage is 'MASTERNODE_SYNC_FINISHED'"
  echo "  - 'Blockchain synced' is true"
  echo "  - 'Masternode synced' is true"
  print_line
  echo "Interactive monitoring menu"
  echo "Use the following keys:"
  echo "  g = get block height"
  echo "  s = show mnsync status"
  echo "  p = show sync progress (recommended)"
  echo "  l = show last 30 debug.log lines"
  echo "  x = confirm sync is complete and continue"
  print_line

  while true; do
    read -r -p "Choose action [g/s/p/l/x]: " action

    case "${action}" in
      g|G)
        run_cli getblockcount || warn "getblockcount failed."
        ;;
      s|S)
        run_cli mnsync status || warn "mnsync status failed."
        ;;
      p|P)
        show_sync_progress
        ;;
      l|L)
        tail -n 30 "${DEFAULT_DATA_DIR}/debug.log" || warn "Could not read debug.log."
        ;;
      x|X)
        success "User confirmed sync and monitoring checkpoint."
        break
        ;;
      *)
        warn "Invalid selection."
        ;;
    esac

    print_line
  done
}

show_sync_progress() {
  local block_height
  local sync_json
  local chain_json
  local asset_name
  local is_blockchain_synced
  local is_synced
  local is_failed
  local verification_progress

  block_height="$(run_cli getblockcount 2>/dev/null)"
  sync_json="$(run_cli mnsync status 2>/dev/null)"
  chain_json="$(run_cli getblockchaininfo 2>/dev/null)"

  asset_name="$(echo "$sync_json" | jq -r '.AssetName // "unknown"' 2>/dev/null)"
  is_blockchain_synced="$(echo "$sync_json" | jq -r '.IsBlockchainSynced // "unknown"' 2>/dev/null)"
  is_synced="$(echo "$sync_json" | jq -r '.IsSynced // "unknown"' 2>/dev/null)"
  is_failed="$(echo "$sync_json" | jq -r '.IsFailed // "unknown"' 2>/dev/null)"
  verification_progress="$(echo "$chain_json" | jq -r '.verificationprogress // empty' 2>/dev/null)"

  echo "Sync Progress"
  echo "-------------"
  echo "Local block height: ${block_height:-unknown}"

  if [[ -n "$verification_progress" && "$verification_progress" != "null" ]]; then
    awk -v v="$verification_progress" 'BEGIN { printf "Verification progress: %.2f%%\n", v * 100 }'
  else
    echo "Verification progress: unknown"
  fi

  echo "Masternode sync stage: ${asset_name:-unknown}"
  echo "Blockchain synced: ${is_blockchain_synced:-unknown}"
  echo "Masternode synced: ${is_synced:-unknown}"
  echo "Sync failed: ${is_failed:-unknown}"
  echo

  if [[ "$is_synced" == "true" && "$asset_name" == "MASTERNODE_SYNC_FINISHED" ]]; then
    success "Sync completed. You can continue with the next recovery step."
  else
    warn "Your node is still syncing. Please wait before continuing."
  fi
}

run_recovery_mode() {
  load_addnodes
  show_addnodes
  validate_addnodes
  pick_random_candidates
  check_addnode_candidates
  show_local_status
  check_service_and_process
  backup_conf
  stop_daemon_cautious || exit 1
  remove_lock_file
  cleanup_recovery_files
  write_trusted_addnodes_to_conf
  start_daemon_cautious || exit 1
  interactive_monitoring_menu
  info "Showing final local status snapshot..."
  show_local_status
  show_protx_placeholder
}

check_ready_for_restore() {
  while true; do
    print_line
    info "Checking if masternode is ready for restore mode..."

    local mn_json
    local mn_state
    local mn_status
    local sync_json
    local asset_name
    local is_synced

    mn_json="$(run_cli masternode status 2>/dev/null || echo "")"
    sync_json="$(run_cli mnsync status 2>/dev/null || echo "")"

    mn_state="$(echo "$mn_json" | jq -r '.state // empty' 2>/dev/null)"
    mn_status="$(echo "$mn_json" | jq -r '.status // empty' 2>/dev/null)"

    asset_name="$(echo "$sync_json" | jq -r '.AssetName // empty' 2>/dev/null)"
    is_synced="$(echo "$sync_json" | jq -r '.IsSynced // empty' 2>/dev/null)"

    echo "Masternode state : ${mn_state:-unknown}"
    echo "Masternode status: ${mn_status:-unknown}"
    echo "Sync stage       : ${asset_name:-unknown}"
    echo "IsSynced         : ${is_synced:-unknown}"
    print_line

    if [[ "$mn_state" == "READY" && "$is_synced" == "true" && "$asset_name" == "MASTERNODE_SYNC_FINISHED" ]]; then
      success "Masternode appears to be READY and fully synced. Continuing with restore mode."
      return 0
    fi

    error "Restore normal mode is not recommended yet."
    echo "The masternode does not meet the recommended conditions for restore mode:"
    echo "  - state should be 'READY'"
    echo "  - sync stage should be 'MASTERNODE_SYNC_FINISHED'"
    echo "  - 'IsSynced' should be true"
    print_line
    echo "Choose how to proceed:"
    echo "  1) Check status again"
    echo "  2) Continue with restore mode anyway (not recommended)"
    echo "  3) Exit without making changes"
    print_line

    local choice
    read -r -p "Enter 1, 2 or 3: " choice

    case "$choice" in
      1)
        # simply loop again and re-check
        ;;
      2)
        warn "Continuing with restore mode despite not meeting recommended conditions."
        return 0
        ;;
      3)
        warn "Aborting restore mode at user request."
        exit 1
        ;;
      *)
        warn "Invalid selection. Please choose 1, 2 or 3."
        ;;
    esac
  done
}

run_restore_mode() {
  check_ready_for_restore
  show_local_status
  check_service_and_process
  backup_conf
  stop_daemon_cautious || exit 1
  remove_lock_file
  restore_normal_mode_conf
  start_daemon_cautious || exit 1
  info "Showing final local status snapshot..."
  show_local_status
}

main() {
  show_intro
  check_root
  show_defaults
  check_files
  check_binaries
  choose_mode

  case "${MODE}" in
    recovery)
      run_recovery_mode
      ;;
    restore)
      run_restore_mode
      ;;
    *)
      error "Unknown mode."
      exit 1
      ;;
  esac

  print_line
  echo "Recovery helper run completed."
  echo "Please continue monitoring the node carefully."
  
  if [[ "${MODE}" == "recovery" ]]; then
    print_line
    print_line
    echo "[Note] Once your masternode has been stable for several days, run this script again and select 'Restore normal mode' to revert from recovery settings."
  fi
  
  print_line
  print_line
}

main "$@"

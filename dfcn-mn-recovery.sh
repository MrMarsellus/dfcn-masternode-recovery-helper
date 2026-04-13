#!/usr/bin/env bash

set -u

SCRIPT_VERSION="0.1.0"
DEFAULT_DEFCON_USER="defcon"
DEFAULT_DEFCON_HOME="/home/defcon"
DEFAULT_DATA_DIR="/home/defcon/.defcon"
DEFAULT_CONF_FILE="/home/defcon/.defcon/defcon.conf"
DEFAULT_CLI="/usr/local/bin/defcon-cli"
DEFAULT_DAEMON="/usr/local/bin/defcond"
DEFAULT_SERVICE="defcond"
DEFAULT_PORT="8192"
DEFAULT_ADDNODE_FILE="./trusted_addnodes.txt"

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
    warn "defcon.conf was not found at the default path."
    warn "You may need to adjust the script later for custom environments."
  fi
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
    warn "Please add at least one trusted node before running recovery steps."
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

run_cli() {
  "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" "$@"
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
  if [ ! -f "${DEFAULT_CONF_FILE}" ]; then
    warn "Config file not found, skipping backup."
    return 0
  fi

  local backup_file
  backup_file="${DEFAULT_CONF_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

  cp "${DEFAULT_CONF_FILE}" "${backup_file}"
  success "Backup created: ${backup_file}"
}

stop_daemon_cautious() {
  print_line
  warn "The next step can stop the daemon and service."
  warn "This is required for cleanup or recovery actions."

  if ! ask_yes_no "Do you want to try stopping the masternode daemon now?"; then
    warn "Stop step skipped by user."
    return 0
  fi

  info "Trying RPC stop..."
  run_cli stop >/dev/null 2>&1 || warn "RPC stop did not succeed."

  sleep 5

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    info "Trying systemctl stop..."
    systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl stop did not succeed."
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
    warn "Please investigate manually before continuing with destructive actions."
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

check_addnode_heights() {
  print_line
  info "Checking trusted addnodes..."

  GOOD_ADDNODES=()
  BAD_ADDNODES=()

  for node in "${ADDNODES[@]}"; do
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

  success "Trusted addnode check completed."
}

main() {
  show_intro
  check_root
  show_defaults
  check_files
  load_addnodes
  show_addnodes
  validate_addnodes
  check_addnode_heights
  check_binaries
  show_local_status
  check_service_and_process
  backup_conf
  stop_daemon_cautious
  remove_lock_file
  cleanup_recovery_files

  info "Initial checks completed."
  info "Next versions will add stop/start checks, cleanup, addnode validation and recovery mode."

  print_line
  echo "What you still need to do manually for now:"
  echo "1. Review trusted_addnodes.txt"
  echo "2. Make the script executable on the VPS"
  echo "3. Run it as root"
  echo "4. Later we will extend it with real recovery actions"
  print_line
}

main "$@"

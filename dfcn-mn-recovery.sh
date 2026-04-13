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

main() {
  show_intro
  check_root
  show_defaults
  check_files
  load_addnodes
  show_addnodes

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

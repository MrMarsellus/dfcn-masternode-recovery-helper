#!/usr/bin/env bash

set -u

SCRIPT_VERSION="0.4.4"

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

POSE_BANTIME=86400
POSE_BANLIST_FILE="${DEFAULT_DATA_DIR}/recovery_pose_bans.txt"

POSE_TRACK_STATE_PREPARED="prepared"
POSE_TRACK_STATE_APPLIED="applied"

SERVICE_WAS_DISABLED=0
SERVICE_WAS_MASKED=0

USE_RANDOM_CANDIDATES=1
REFERENCE_HEIGHT=""
ADDNODE_CHECK_MODE="soft"

ADDNODE_TEST_ROUNDS_HARD=5
ADDNODE_MIN_SUCCESS_HARD=3
ADDNODE_MAX_HEIGHT_DIFF=15
ADDNODE_TCP_TIMEOUT=5
ADDNODE_PEER_SLEEP=4

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

run_cli_json() {
  "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" "$@" 2>/dev/null
}

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local IFS=.
  local octets
  read -r -a octets <<< "$ip"

  local octet
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done

  return 0
}

is_number() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

dedupe_addnodes_array() {
  local -A seen=()
  local -a result=()
  local item

  for item in "${ADDNODES[@]}"; do
    if [[ -n "${item}" && -z "${seen[$item]:-}" ]]; then
      seen["$item"]=1
      result+=("$item")
    fi
  done

  ADDNODES=("${result[@]}")
}

dedupe_candidates_array() {
  local -A seen=()
  local -a result=()
  local item

  for item in "${CANDIDATES[@]}"; do
    if [[ -n "${item}" && -z "${seen[$item]:-}" ]]; then
      seen["$item"]=1
      result+=("$item")
    fi
  done

  CANDIDATES=("${result[@]}")
}

dedupe_good_addnodes_array() {
  local -A seen=()
  local -a result=()
  local item

  for item in "${GOOD_ADDNODES[@]}"; do
    if [[ -n "${item}" && -z "${seen[$item]:-}" ]]; then
      seen["$item"]=1
      result+=("$item")
    fi
  done

  GOOD_ADDNODES=("${result[@]}")
}

normalize_node() {
  local node="$1"
  if [[ "$node" != *:* ]]; then
    echo "${node}:${DEFAULT_PORT}"
  else
    echo "$node"
  fi
}

get_local_height() {
  local h
  h="$(run_cli getblockcount 2>/dev/null || true)"
  is_number "$h" || return 1
  echo "$h"
}

prompt_reference_height() {
  local input local_height

  print_line
  echo "Reference block height for addnode checks"
  echo
  echo "Please enter the block height of the correct active chain."
  echo "Use a trusted source, for example the official explorer"
  echo "or another known-good fully synced node."
  echo
  echo "Important"
  echo "- If this VPS is on the wrong fork, its local block height may be wrong."
  echo "- In that case, you should enter the reference block height of the correct chain."
  echo
  echo "If you press Enter without typing a value,"
  echo "the script will automatically use the current local block height."
  echo

  local_height="$(get_local_height || echo "")"
  if ! is_number "$local_height"; then
    error "Could not read local block height from defcon-cli."
    exit 1
  fi

  read -r -p "Reference block height (empty = use local ${local_height}): " input
  input="$(trim "${input:-}")"

  if [[ -z "$input" ]]; then
    REFERENCE_HEIGHT="$local_height"
    info "No value entered. Using local block height as reference: ${REFERENCE_HEIGHT}"
  else
    if ! is_number "$input"; then
      error "Invalid block height. Please enter a numeric value."
      exit 1
    fi
    REFERENCE_HEIGHT="$input"
    info "Using user-defined reference block height: ${REFERENCE_HEIGHT}"
  fi

  print_line
}

prompt_addnode_check_mode() {
  local choice

  print_line
  echo "Addnode check mode"
  echo "  1) Fast / soft check"
  echo "     - one round per node"
  echo "     - basic filtering"
  echo "     - faster, less strict"
  echo
  echo "  2) Intensive / hard check"
  echo "     - 5 rounds per node"
  echo "     - at least 3 rounds must pass"
  echo "     - stricter filtering"
  print_line

  while true; do
    read -r -p "Enter 1 or 2: " choice
    case "$choice" in
      1)
        ADDNODE_CHECK_MODE="soft"
        info "Selected addnode check mode: soft"
        return 0
        ;;
      2)
        ADDNODE_CHECK_MODE="hard"
        info "Selected addnode check mode: hard"
        return 0
        ;;
      *)
        warn "Invalid selection. Please enter 1 or 2."
        ;;
    esac
  done
}

get_peer_json_by_host() {
  local host="$1"
  run_cli getpeerinfo 2>/dev/null | jq -c --arg host "$host" '
    .[] | select(
      (.addr? | tostring | startswith($host + ":")) or
      (.addrbind? | tostring | contains($host)) or
      (.addrlocal? | tostring | contains($host))
    )' | head -n 1
}

get_masternodelist_status_word() {
  local node="$1"
  local status_json

  status_json="$(run_cli masternodelist status "$node" 2>/dev/null || true)"
  if [[ -z "$status_json" || "$status_json" == "{}" ]]; then
    echo ""
    return 1
  fi

  echo "$status_json" | grep -Eo 'ENABLED|POSE_BANNED' | head -n 1 || true
}

get_protx_match() {
  local node="$1"
  run_cli protx list registered true 2>/dev/null \
    | jq -c --arg node "$node" '.[] | select((.state.service // "") == $node)' \
    | head -n 1
}

show_intro() {
  print_line
  echo "DeFCoN Masternode Recovery Helper v${SCRIPT_VERSION}"
  echo "Cautious recovery helper for DeFCoN masternodes"
  print_line
  echo "Available modes:"
  echo "  1) Recovery (without trusted addnodes)"
  echo "  2) Recovery with trusted addnodes"
  echo "  3) Restore normal mode (remove helper-managed addnodes + PoSe-bans)"
  print_line
  echo "Notes:"
  echo " - PoSe evaluation uses 'protx list registered true' to include PoSe-banned nodes."
  echo " - PoSe-banned = state.PoSeBanHeight > 0"
  echo " - PoSe-scored = state.PoSePenalty > 0"
  echo " - Service IP   = state.service (IPv4 only in this helper)."
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
  echo "PoSe bantime    : ${POSE_BANTIME} seconds"
  echo "PoSe ban file   : ${POSE_BANLIST_FILE}"
  print_line
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Please run this script as root."
    exit 1
  fi
}

check_conf_file() {
  if [ ! -f "${DEFAULT_CONF_FILE}" ]; then
    error "Config file not found at: ${DEFAULT_CONF_FILE}"
    exit 1
  fi
}

check_addnode_file() {
  if [ ! -f "${DEFAULT_ADDNODE_FILE}" ]; then
    error "trusted_addnodes.txt was not found in the current directory."
    echo "Place the file next to this script and run it again."
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

  if ! command -v jq >/dev/null 2>&1; then
    error "jq is required but was not found."
    exit 1
  fi

  if ! command -v timeout >/dev/null 2>&1; then
    error "timeout is required but was not found."
    exit 1
  fi

  if ! command -v grep >/dev/null 2>&1; then
    error "grep is required but was not found."
    exit 1
  fi

  if ! command -v awk >/dev/null 2>&1; then
    error "awk is required but was not found."
    exit 1
  fi

  success "Required binaries were found."
}

load_addnodes() {
  ADDNODES=()

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(trim "$line")"

    if [ -n "$line" ]; then
      line="$(echo "$line" | sed -E 's/^[[:space:]]*addnode[[:space:]]+//I')"
      line="$(echo "$line" | awk '{print $1}')"
      line="$(normalize_node "$line")"
      ADDNODES+=("$line")
    fi
  done < "${DEFAULT_ADDNODE_FILE}"

  if [ "${#ADDNODES[@]}" -eq 0 ]; then
    warn "No trusted addnodes were found in ${DEFAULT_ADDNODE_FILE}."
    warn "Please add at least one trusted node before running recovery with addnodes."
    exit 1
  fi
}

show_addnodes() {
  print_line
  echo "Trusted addnodes selected:"
  for node in "${ADDNODES[@]}"; do
    echo " - ${node}"
  done
  print_line
}

validate_addnodes() {
  local invalid_count=0
  local normalized=()
  local node

  for node in "${ADDNODES[@]}"; do
    node="$(normalize_node "$node")"

    if ! echo "$node" | grep -Eq '^[a-zA-Z0-9._-]+:[0-9]+$'; then
      warn "Invalid addnode format: $node"
      invalid_count=$((invalid_count + 1))
      continue
    fi

    normalized+=("$node")
  done

  ADDNODES=("${normalized[@]}")

  if [ "$invalid_count" -gt 0 ]; then
    error "One or more addnodes have an invalid format."
    echo "Expected format: IP:PORT or HOSTNAME:PORT"
    exit 1
  fi

  success "All trusted addnodes have a valid basic format."
}

prompt_addnodes_source() {
  print_line
  echo "Trusted addnodes source:"
  echo "  1) Use existing list from ${DEFAULT_ADDNODE_FILE}"
  echo "  2) Enter addnodes manually (opens nano editor)"
  print_line

  local choice
  while true; do
    read -r -p "Enter 1 or 2: " choice
    case "${choice}" in
      1)
        USE_RANDOM_CANDIDATES=1
        check_addnode_file
        load_addnodes
        dedupe_addnodes_array
        return 0
        ;;
      2)
        USE_RANDOM_CANDIDATES=0
        ADDNODES=()
        print_line

        echo "Opening nano for manual addnode input..."
        echo "Paste your addnodes (one per line) into the editor."
        echo "Save with Ctrl+O, then Enter, then Ctrl+X to exit."
        print_line

        local TMPFILE
        TMPFILE="$(mktemp /tmp/defcon_addnodes.XXXXXX)" || {
          error "Could not create temporary file."
          exit 1
        }

        nano "$TMPFILE"

        mapfile -t lines < "$TMPFILE"
        rm -f "$TMPFILE"

        local max_nodes=30
        local count=0

        for raw in "${lines[@]}"; do
          local line="${raw%%#*}"
          line="$(trim "$line")"

          [ -z "$line" ] && continue

          line="$(echo "$line" | sed -E 's/^[[:space:]]*addnode[[:space:]]+//I')"
          line="$(echo "$line" | awk '{print $1}')"
          line="$(normalize_node "$line")"

          if echo "$line" | grep -Eq '^[A-Za-z0-9._-]+:[0-9]+$'; then
            ADDNODES+=("$line")
            count=$((count + 1))
            if [ "$count" -ge "$max_nodes" ]; then
              break
            fi
          fi
        done

        if [ "${#ADDNODES[@]}" -eq 0 ]; then
          error "No valid addnodes were entered."
          exit 1
        fi

        dedupe_addnodes_array
        echo "Collected ${#ADDNODES[@]} unique addnodes from manual input."
        echo "These nodes will now be validated and tested."
        return 0
        ;;
      *)
        warn "Invalid selection. Please enter 1 or 2."
        ;;
    esac
  done
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

  if systemctl list-unit-files | grep -q "^${DEFAULT_SERVICE}\\.service"; then
    echo "Service file found : ${DEFAULT_SERVICE}.service"

    if systemctl is-active --quiet "${DEFAULT_SERVICE}"; then
      echo "Service status     : active"
    else
      echo "Service status     : not active"
    fi

    if systemctl is-enabled "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      echo "Service enabled    : yes"
    else
      echo "Service enabled    : no"
    fi
  else
    warn "Service file ${DEFAULT_SERVICE}.service was not found."
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    local proc_line pid cmd bin
    proc_line="$(pgrep -af "${DEFAULT_DAEMON}" | head -n1)"
    pid="${proc_line%% *}"
    cmd="${proc_line#* }"
    bin="${cmd%% *}"

    echo "Daemon process     : running"
    echo "Daemon PID         : ${pid}"
    echo "Daemon binary      : ${bin}"
  else
    echo "Daemon process     : not running"
  fi

  print_line
}

ensure_daemon_running() {
  print_line
  info "Checking whether the daemon is already running..."

  local rpc_ok=1
  local service_active=1
  local proc_ok=1
  local service_exists=1

  if timeout 5 "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" getblockcount >/dev/null 2>&1; then
    rpc_ok=0
  fi

  if systemctl list-unit-files | grep -q "^${DEFAULT_SERVICE}\.service"; then
    service_exists=0
    if systemctl is-active --quiet "${DEFAULT_SERVICE}"; then
      service_active=0
    fi
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    proc_ok=0
  fi

  if [ "${rpc_ok}" -eq 0 ]; then
    success "Daemon is already running and RPC is responding."
    check_service_and_process
    return 0
  fi

  print_line
  echo "Startup check summary:"
  echo " - Service file found : $([[ ${service_exists} -eq 0 ]] && echo yes || echo no)"
  echo " - Service active     : $([[ ${service_active} -eq 0 ]] && echo yes || echo no)"
  echo " - Daemon process     : $([[ ${proc_ok} -eq 0 ]] && echo yes || echo no)"
  echo " - RPC responding     : no"
  print_line

  if [ "${service_exists}" -eq 0 ] && { [ "${service_active}" -eq 0 ] || [ "${proc_ok}" -eq 0 ]; }; then
    warn "A service or daemon process was detected, but RPC is not responding."
    echo "This may mean the daemon is starting, stuck, or unhealthy."
    echo "Check with: systemctl status ${DEFAULT_SERVICE}"
    echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
    print_line

    if ask_yes_no "Do you want to try restarting the service now?"; then
      info "Trying systemctl restart ${DEFAULT_SERVICE}..."
      if ! systemctl restart "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
        error "systemctl restart did not succeed."
        echo "Check with: systemctl status ${DEFAULT_SERVICE}"
        echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
        return 1
      fi

      sleep 5

      if timeout 5 "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" getblockcount >/dev/null 2>&1; then
        success "Daemon appears to be running after restart."
        check_service_and_process
        return 0
      fi

      error "RPC is still not responding after restart."
      echo "Check with: systemctl status ${DEFAULT_SERVICE}"
      echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
      return 1
    fi

    warn "User chose not to restart the daemon."
    return 1
  fi

  warn "Daemon is not running."

  if [ "${service_exists}" -ne 0 ]; then
    error "Service file ${DEFAULT_SERVICE}.service was not found."
    echo "Automatic start via systemctl is not possible."
    return 1
  fi

  if ask_yes_no "Do you want to start the daemon now?"; then
    info "Trying systemctl start ${DEFAULT_SERVICE}..."
    if ! systemctl start "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      error "systemctl start did not succeed."
      echo "Check with: systemctl status ${DEFAULT_SERVICE}"
      echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
      return 1
    fi

    sleep 5

    if timeout 5 "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" getblockcount >/dev/null 2>&1; then
      success "Daemon appears to be running after start."
      check_service_and_process
      return 0
    fi

    error "Service was started, but RPC is still not responding."
    echo "Check with: systemctl status ${DEFAULT_SERVICE}"
    echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
    return 1
  fi

  warn "User chose not to start the daemon."
  return 1
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
  echo "1. Recovery (without trusted addnodes)"
  echo "2. Recovery with trusted addnodes"
  echo "3. Restore normal mode (addnodes + PoSe-bans)"
  print_line

  read -r -p "Enter 1, 2 or 3: " SELECTED_MODE

  case "${SELECTED_MODE}" in
    1) MODE="recovery_plain" ;;
    2) MODE="recovery_addnodes" ;;
    3) MODE="restore" ;;
    *)
      error "Invalid mode selected."
      exit 1
      ;;
  esac
}

pick_random_candidates() {
  CANDIDATES=()

  if [ "${USE_RANDOM_CANDIDATES}" -eq 0 ]; then
    # Option 2: keine Random-Auswahl, nutze ADDNODES direkt
    CANDIDATES=("${ADDNODES[@]}")

    dedupe_candidates_array

    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
      error "No candidate addnodes were selected from manual input."
      exit 1
    fi

    print_line
    info "Using ${#CANDIDATES[@]} addnodes from manual input for testing:"
    for node in "${CANDIDATES[@]}"; do
      echo "  - $node"
    done
    print_line
  else
    # Option 1: bisherige Random-Logik aus trustedaddnodes.txt
    mapfile -t CANDIDATES < <(printf '%s\n' "${ADDNODES[@]}" | shuf | head -n "${MAX_RANDOM_CANDIDATES}")

    dedupe_candidates_array

    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
      error "No candidate addnodes were selected."
      exit 1
    fi

    print_line
    info "Random candidate addnodes selected for testing:"
    for node in "${CANDIDATES[@]}"; do
      echo "  - $node"
    done
    print_line
  fi
}

test_node_once_soft_or_hard() {
  local node="$1"
  local host port peer_json peer_height
  local status_word protx_match
  local pose_penalty pose_ban_height revocation_reason last_paid_height

  host="${node%:*}"
  port="${node##*:}"

  info "Testing ${node}"

  if ! timeout "${ADDNODE_TCP_TIMEOUT}" bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
    warn "Port check failed for ${node}"
    return 1
  fi
  success "Port check passed for ${node}"

  run_cli addnode "${node}" onetry >/dev/null 2>&1 || true
  sleep "${ADDNODE_PEER_SLEEP}"

  peer_json="$(get_peer_json_by_host "$host" 2>/dev/null || true)"
  if [[ -z "$peer_json" ]]; then
    warn "Peer check failed for ${node} (not visible in getpeerinfo)"
    return 1
  fi
  success "Peer check passed for ${node}"

  peer_height="$(jq -r '.synced_headers // .startingheight // .synced_blocks // empty' <<< "$peer_json" 2>/dev/null || true)"
  if is_number "$peer_height"; then
    echo "  Peer height      : ${peer_height}"
    echo "  Reference height : ${REFERENCE_HEIGHT}"
    if (( peer_height + ADDNODE_MAX_HEIGHT_DIFF < REFERENCE_HEIGHT )); then
      warn "Height check failed for ${node} (peer is too far behind reference height)"
      return 1
    fi
  else
    warn "Height check failed for ${node} (peer height unknown)"
    return 1
  fi

  status_word="$(get_masternodelist_status_word "$node" || true)"
  if [[ "$status_word" == "POSE_BANNED" ]]; then
    warn "Masternodelist status failed for ${node} (POSE_BANNED)"
    return 1
  fi

  protx_match="$(get_protx_match "$node")"
  if [[ -z "$protx_match" ]]; then
    warn "ProTx lookup failed for ${node} (service not found)"
    return 1
  fi

  pose_penalty="$(jq -r '.state.PoSePenalty // 0' <<< "$protx_match")"
  pose_ban_height="$(jq -r '.state.PoSeBanHeight // -1' <<< "$protx_match")"
  revocation_reason="$(jq -r '.state.revocationReason // 0' <<< "$protx_match")"
  last_paid_height="$(jq -r '.state.lastPaidHeight // 0' <<< "$protx_match")"

  echo "  ProTx PoSePenalty     : ${pose_penalty}"
  echo "  ProTx PoSeBanHeight   : ${pose_ban_height}"
  echo "  ProTx revocationReason: ${revocation_reason}"
  echo "  ProTx lastPaidHeight  : ${last_paid_height}"

  if is_number "$pose_penalty" && (( pose_penalty > 0 )); then
    warn "ProTx check failed for ${node} (PoSePenalty > 0)"
    return 1
  fi

  if is_number "$pose_ban_height" && (( pose_ban_height > 0 )); then
    warn "ProTx check failed for ${node} (PoSeBanHeight > 0)"
    return 1
  fi

  if is_number "$revocation_reason" && (( revocation_reason > 0 )); then
    warn "ProTx check failed for ${node} (revocationReason > 0)"
    return 1
  fi

  if is_number "$last_paid_height" && (( last_paid_height == 0 )); then
    if [[ "$ADDNODE_CHECK_MODE" == "hard" ]]; then
      warn "Reward history check failed for ${node} (lastPaidHeight = 0)"
      return 1
    else
      warn "Reward history warning for ${node} (lastPaidHeight = 0)"
    fi
  fi

  success "Node passed this round: ${node}"
  return 0
}

check_addnode_candidates_soft() {
  local node

  GOOD_ADDNODES=()
  BAD_ADDNODES=()

  print_line
  info "Checking trusted addnode candidates in soft mode..."

  for node in "${CANDIDATES[@]}"; do
    if test_node_once_soft_or_hard "$node"; then
      GOOD_ADDNODES+=("$node")
    else
      BAD_ADDNODES+=("$node")
    fi

    if [ "${#GOOD_ADDNODES[@]}" -ge "${MAX_GOOD_ADDNODES}" ]; then
      break
    fi

    print_line
  done
}

check_addnode_candidates_hard() {
  local node round success_count
  GOOD_ADDNODES=()
  BAD_ADDNODES=()

  print_line
  info "Checking trusted addnode candidates in hard mode..."

  for node in "${CANDIDATES[@]}"; do
    success_count=0

    for ((round=1; round<=ADDNODE_TEST_ROUNDS_HARD; round++)); do
      echo "Round ${round}/${ADDNODE_TEST_ROUNDS_HARD} for ${node}"
      if test_node_once_soft_or_hard "$node"; then
        success_count=$((success_count + 1))
      fi
      echo
    done

    echo "Passed rounds for ${node}: ${success_count}/${ADDNODE_TEST_ROUNDS_HARD}"

    if [ "${success_count}" -ge "${ADDNODE_MIN_SUCCESS_HARD}" ]; then
      GOOD_ADDNODES+=("$node")
      success "Accepted: ${node}"
    else
      BAD_ADDNODES+=("$node")
      warn "Rejected: ${node}"
    fi

    if [ "${#GOOD_ADDNODES[@]}" -ge "${MAX_GOOD_ADDNODES}" ]; then
      break
    fi

    print_line
  done
}

check_addnode_candidates() {
  print_line
  info "Reference block height used for addnode checks: ${REFERENCE_HEIGHT}"
  info "Selected addnode check mode: ${ADDNODE_CHECK_MODE}"

  if [[ "${ADDNODE_CHECK_MODE}" == "hard" ]]; then
    check_addnode_candidates_hard
  else
    check_addnode_candidates_soft
  fi

  print_line
  echo "Good trusted addnodes:"
  if [ "${#GOOD_ADDNODES[@]}" -eq 0 ]; then
    echo "  none"
  else
    for node in "${GOOD_ADDNODES[@]}"; do
      echo "  - $node"
    done
  fi

  echo
  echo "Rejected addnodes:"
  if [ "${#BAD_ADDNODES[@]}" -eq 0 ]; then
    echo "  none"
  else
    for node in "${BAD_ADDNODES[@]}"; do
      echo "  - $node"
    done
  fi
  print_line

  dedupe_good_addnodes_array
  
  if [ "${#GOOD_ADDNODES[@]}" -eq 0 ]; then
    error "No usable trusted addnodes passed the checks."
    exit 1
  fi

  if [ "${#GOOD_ADDNODES[@]}" -lt 3 ]; then
    warn "Fewer than 3 good addnodes passed the checks."
    warn "Recovery with addnodes can continue, but confidence is lower."
  fi

  if [ "${#GOOD_ADDNODES[@]}" -gt "${MAX_GOOD_ADDNODES}" ]; then
    GOOD_ADDNODES=("${GOOD_ADDNODES[@]:0:${MAX_GOOD_ADDNODES}}")
  fi

  success "Trusted addnode candidate checks completed."
}

get_local_service_ip() {
  # Try externalip= from defcon.conf first
  local ip raw_externalip
  raw_externalip="$(grep -E '^[[:space:]]*externalip=' "${DEFAULT_CONF_FILE}" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)"

  if [ -n "${raw_externalip}" ]; then
    ip="${raw_externalip}"

    # If externalip is stored as IP:PORT, strip the port
    if [[ "${ip}" == *:* ]]; then
      ip="${ip%:*}"
    fi

    if is_valid_ipv4 "${ip}"; then
      echo "${ip}"
      return 0
    fi
  fi

  # Fallback: try masternode status -> addr/service
  local mn_json addr
  mn_json="$(run_cli masternode status 2>/dev/null || echo "")"
  addr="$(echo "${mn_json}" | jq -r '.addr // .service // empty' 2>/dev/null || echo "")"

  if [ -n "${addr}" ]; then
    addr="${addr#\[}"   # strip leading '[' if present
    addr="${addr%\]}"   # strip trailing ']' if present
    addr="${addr%:*}"   # drop port
    if is_valid_ipv4 "${addr}"; then
      echo "${addr}"
      return 0
    fi
  fi

  echo ""
  return 1
}

collect_pose_problem_nodes() {
  print_line
  info "Evaluating live deterministic masternode state for PoSe issues (registered true)..."

  # Determine local service IP once, so we can exclude it from the banlist
  local LOCAL_SERVICE_IP
  LOCAL_SERVICE_IP="$(get_local_service_ip || echo "")"
  if [ -n "${LOCAL_SERVICE_IP}" ]; then
    info "Local masternode service IP detected: ${LOCAL_SERVICE_IP}"
  else
    warn "Could not automatically detect local masternode service IP; no local exclusion will be applied."
  fi

  local protx_json
  protx_json="$(run_cli_json protx list registered true)"
  if [ -z "${protx_json}" ]; then
    error "Failed to read deterministic masternode list via 'protx list registered true'."
    return 1
  fi

  POSE_BANNED_IPS=()
  POSE_SCORED_IPS=()
  ALL_POSE_IPS=()

  local tmp_banned tmp_scored tmp_all
  tmp_banned="$(mktemp)"
  tmp_scored="$(mktemp)"
  tmp_all="$(mktemp)"

  while IFS= read -r line; do
    local service pose_penalty pose_ban_height ip
    service="$(echo "$line" | jq -r '.state.service // empty' 2>/dev/null)"
    pose_penalty="$(echo "$line" | jq -r '.state.PoSePenalty // empty' 2>/dev/null)"
    pose_ban_height="$(echo "$line" | jq -r '.state.PoSeBanHeight // empty' 2>/dev/null)"

    if [ -z "${service}" ] || [ "${service}" = "null" ]; then
      continue
    fi

    ip="${service%:*}"
    if ! is_valid_ipv4 "${ip}"; then
      continue
    fi

    # Never add our own service IP to any PoSe list
    if [ -n "${LOCAL_SERVICE_IP}" ] && [ "${ip}" = "${LOCAL_SERVICE_IP}" ]; then
      continue
    fi

    if [[ "${pose_ban_height}" =~ ^-?[0-9]+$ ]] && [ "${pose_ban_height}" -gt 0 ]; then
      echo "${ip}" >> "${tmp_banned}"
      echo "${ip}" >> "${tmp_all}"
    fi

    if [[ "${pose_penalty}" =~ ^-?[0-9]+$ ]] && [ "${pose_penalty}" -gt 0 ]; then
      echo "${ip}" >> "${tmp_scored}"
      echo "${ip}" >> "${tmp_all}"
    fi
  done < <(echo "${protx_json}" | jq -c '.[]')

  if [ -s "${tmp_banned}" ]; then
    mapfile -t POSE_BANNED_IPS < <(sort -u "${tmp_banned}")
  else
    POSE_BANNED_IPS=()
  fi

  if [ -s "${tmp_scored}" ]; then
    mapfile -t POSE_SCORED_IPS < <(sort -u "${tmp_scored}")
  else
    POSE_SCORED_IPS=()
  fi

  if [ -s "${tmp_all}" ]; then
    mapfile -t ALL_POSE_IPS < <(sort -u "${tmp_all}")
  else
    ALL_POSE_IPS=()
  fi

  rm -f "${tmp_banned}" "${tmp_scored}" "${tmp_all}"

  POSE_BANNED_COUNT=${#POSE_BANNED_IPS[@]}
  POSE_SCORED_COUNT=${#POSE_SCORED_IPS[@]}
  ALL_POSE_COUNT=${#ALL_POSE_IPS[@]}
  
  POSE_SCORED_NOT_BANNED_COUNT=0
  if [ "${POSE_SCORED_COUNT}" -ge "${POSE_BANNED_COUNT}" ]; then
    POSE_SCORED_NOT_BANNED_COUNT=$((POSE_SCORED_COUNT - POSE_BANNED_COUNT))
  fi

  if [ "${ALL_POSE_COUNT}" -eq 0 ]; then
    warn "No problematic masternodes were found in 'registered true' list (after excluding local IP)."
    return 1
  fi

  return 0
}

show_pose_problem_nodes_preview() {
  print_line
  echo "Prepared problematic masternode service IPs (from registered true):"
  for ip in "${ALL_POSE_IPS[@]}"; do
    echo " - ${ip}"
  done

  print_line
  echo "PoSe analysis summary (registered true, local IP excluded if detected):"
  echo " - Already PoSe-banned masternode IPs      : ${POSE_BANNED_COUNT}"
  echo " - PoSe-scored MN IPs (not banned yet)     : ${POSE_SCORED_NOT_BANNED_COUNT}"
  echo " - Total problematic masternode IPs to ban : ${ALL_POSE_COUNT}"
  print_line
}

write_pose_banlist_file() {
  local state="$1"
  local tmp_file
  tmp_file="${POSE_BANLIST_FILE}.tmp"

  {
    echo "# DeFCoN Recovery Helper PoSe banlist"
    echo "# Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "# Bantime: ${POSE_BANTIME}"
    echo "# State: ${state}"
    echo "# Source: protx list registered true"
    echo "# IP format: IPv4 only, one per line"
    printf '%s\n' "${ALL_POSE_IPS[@]}"
  } > "${tmp_file}"

  mv "${tmp_file}" "${POSE_BANLIST_FILE}"
  chmod 600 "${POSE_BANLIST_FILE}" >/dev/null 2>&1 || true
}

save_pose_banlist_file_prepared() {
  write_pose_banlist_file "${POSE_TRACK_STATE_PREPARED}"
  success "Temporary PoSe banlist file written (state=prepared): ${POSE_BANLIST_FILE}"
}

update_pose_banlist_state_to_applied() {
  if [ ! -f "${POSE_BANLIST_FILE}" ]; then
    return
  fi

  local tmp_file new_state
  tmp_file="${POSE_BANLIST_FILE}.tmp"
  new_state="${POSE_TRACK_STATE_APPLIED}"

  awk -v new_state="${new_state}" '
    BEGIN { updated=0; }
    /^# State:/ {
      print "# State: " new_state;
      updated=1;
      next;
    }
    { print }
    END {
      if (!updated) {
        print "# State: " new_state;
      }
    }
  ' "${POSE_BANLIST_FILE}" > "${tmp_file}"

  mv "${tmp_file}" "${POSE_BANLIST_FILE}"
  chmod 600 "${POSE_BANLIST_FILE}" >/dev/null 2>&1 || true
}

read_pose_banlist_state() {
  if [ ! -f "${POSE_BANLIST_FILE}" ]; then
    echo ""
    return
  fi
  local state_line
  state_line="$(grep '^# State:' "${POSE_BANLIST_FILE}" 2>/dev/null || true)"
  if [ -z "${state_line}" ]; then
    echo ""
    return
  fi
  echo "${state_line#*State: }" | xargs
}

collect_ips_from_pose_file() {
  local file="$1"
  local target_array="$2"
  local line
  local -a result=()

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    if [ -n "${line}" ] && is_valid_ipv4 "${line}"; then
      result+=("${line}")
    fi
  done < "${file}"

  case "$target_array" in
    PREPARED_POSE_IPS)
      PREPARED_POSE_IPS=("${result[@]}")
      ;;
    TRACKED_POSE_IPS)
      TRACKED_POSE_IPS=("${result[@]}")
      ;;
    *)
      error "Unsupported target array in collect_ips_from_pose_file: ${target_array}"
      return 1
      ;;
  esac
}

prepare_pose_banlist() {
  if [ "${ALL_POSE_COUNT:-0}" -eq 0 ]; then
    warn "No PoSe-based IPs are available for a temporary banlist."
    return 0
  fi

  show_pose_problem_nodes_preview

  echo "This temporary PoSe-based banlist is intended to prevent problematic peers"
  echo "from re-entering later through normal peer discovery during the next sync."
  print_line

  if ! ask_yes_no "Do you want to create the temporary PoSe-based banlist file with all collected IPs?"; then
    warn "PoSe-based banlist file creation skipped by user."
    return 0
  fi

  save_pose_banlist_file_prepared
}

apply_prepared_pose_bans() {
  print_line
  info "Checking whether a prepared PoSe banlist should now be applied..."

  if [ ! -f "${POSE_BANLIST_FILE}" ]; then
    info "No prepared PoSe banlist file found."
    return 0
  fi

  local current_state
  current_state="$(read_pose_banlist_state)"
  if [ -z "${current_state}" ]; then
    warn "PoSe banlist file has no state header; treating as prepared."
    current_state="${POSE_TRACK_STATE_PREPARED}"
  fi

  if [ "${current_state}" = "${POSE_TRACK_STATE_APPLIED}" ]; then
    info "PoSe banlist file is already marked as applied. Skipping automatic re-apply."
    return 0
  fi

  PREPARED_POSE_IPS=()
  collect_ips_from_pose_file "${POSE_BANLIST_FILE}" PREPARED_POSE_IPS

  if [ "${#PREPARED_POSE_IPS[@]}" -eq 0 ]; then
    warn "Prepared PoSe banlist file exists but contains no valid IPs."
    return 0
  fi

  print_line
  echo "Prepared PoSe bans ready to apply after restart: ${#PREPARED_POSE_IPS[@]}"
  print_line

  local applied=0
  local failed=0

  for ip in "${PREPARED_POSE_IPS[@]}"; do
    if run_cli setban "${ip}" add "${POSE_BANTIME}" false >/dev/null 2>&1; then
      applied=$((applied + 1))
    else
      failed=$((failed + 1))
      warn "Could not ban IP (setban add failed): ${ip}"
    fi
  done

  print_line
  echo "Temporary PoSe ban application summary:"
  echo " - Successfully banned: ${applied}"
  echo " - Failed to ban      : ${failed}"
  print_line

  if [ "${applied}" -gt 0 ]; then
    success "Temporary PoSe-based bans were applied after restart."
    update_pose_banlist_state_to_applied
  else
    warn "No PoSe-based bans were applied after restart."
  fi
}

remove_tracked_pose_bans() {
  print_line
  info "Checking for recovery-helper temporary PoSe bans..."

  if [ ! -f "${POSE_BANLIST_FILE}" ]; then
    info "No recovery-helper PoSe banlist file found."
    return 0
  fi

  local current_state
  current_state="$(read_pose_banlist_state)"
  if [ -z "${current_state}" ]; then
    current_state="(unknown)"
  fi

  TRACKED_POSE_IPS=()
  collect_ips_from_pose_file "${POSE_BANLIST_FILE}" TRACKED_POSE_IPS

  if [ "${#TRACKED_POSE_IPS[@]}" -eq 0 ]; then
    warn "PoSe banlist file exists but contains no valid tracked IPs."
    if ask_yes_no "Do you want to remove the empty or invalid PoSe banlist file now?"; then
      rm -f "${POSE_BANLIST_FILE}"
      success "PoSe banlist file removed."
    fi
    return 0
  fi

  print_line
  echo "Tracked temporary PoSe bans found: ${#TRACKED_POSE_IPS[@]}"
  echo "File state: ${current_state}"
  echo "Tracked IPs:"
  for ip in "${TRACKED_POSE_IPS[@]}"; do
    echo " - ${ip}"
  done
  print_line

  if ! ask_yes_no "Do you want to remove these recovery-helper PoSe bans now?"; then
    warn "Removal of tracked PoSe bans skipped by user."
    return 0
  fi

  local removed=0
  local missing=0
  local failed=0

  for ip in "${TRACKED_POSE_IPS[@]}"; do
    if run_cli setban "${ip}" remove >/dev/null 2>&1; then
      removed=$((removed + 1))
    else
      # could be "not currently banned"
      missing=$((missing + 1))
      warn "Ban for IP not found or already expired: ${ip}"
    fi
  done

  print_line
  echo "Tracked PoSe ban removal summary:"
  echo " - Successfully removed: ${removed}"
  echo " - Not currently banned : ${missing}"
  echo " - Other failures       : ${failed}"
  print_line

  if ask_yes_no "Do you want to delete the recovery-helper PoSe banlist file now?"; then
    rm -f "${POSE_BANLIST_FILE}"
    success "Recovery-helper PoSe banlist file removed."
  else
    warn "PoSe banlist file was kept."
  fi
}

offer_pose_banlist_preparation() {
  print_line
  echo "Optional PoSe-based temporary banlist feature (registered true)"
  echo "This can collect all currently problematic masternodes from the live"
  echo "deterministic masternode state and prepare their service IPs for a"
  echo "temporary banlist that will be applied AFTER cleanup and restart."
  echo
  echo "Problematic means:"
  echo " - all currently PoSe-banned masternodes (PoSeBanHeight > 0)"
  echo " - all masternodes with current PoSe score / PoSePenalty > 0"
  echo "Source RPC: protx list registered true"
  print_line

  if ! ask_yes_no "Do you want to evaluate the current deterministic masternode state for a temporary PoSe-based banlist now?"; then
    warn "PoSe-based temporary banlist evaluation skipped by user."
    return 0
  fi

  if collect_pose_problem_nodes; then
    prepare_pose_banlist
  else
    warn "No PoSe-based temporary banlist was prepared."
  fi
}

verify_daemon_stopped() {
  local rpc_dead=1
  local proc_dead=1
  local service_inactive=1

  if ! pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    proc_dead=0
  fi

  if systemctl list-unit-files | grep -q "^${DEFAULT_SERVICE}\\.service"; then
    if ! systemctl is-active --quiet "${DEFAULT_SERVICE}"; then
      service_inactive=0
    fi
  else
    service_inactive=0
  fi

  if ! timeout 5 "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" getblockcount >/dev/null 2>&1; then
    rpc_dead=0
  fi

  print_line
  echo "Stop verification:"
  echo " - Process stopped : $([[ $proc_dead -eq 0 ]] && echo yes || echo no)"
  echo " - Service inactive: $([[ $service_inactive -eq 0 ]] && echo yes || echo no)"
  echo " - RPC unreachable : $([[ $rpc_dead -eq 0 ]] && echo yes || echo no)"
  print_line

  if [[ $proc_dead -eq 0 && $service_inactive -eq 0 && $rpc_dead -eq 0 ]]; then
    return 0
  fi

  return 1
}

show_stop_summary() {
  print_line
  echo "Shutdown summary"
  echo "----------------"

  if systemctl list-unit-files | grep -q "^${DEFAULT_SERVICE}\\.service"; then
    if systemctl is-active --quiet "${DEFAULT_SERVICE}"; then
      echo "Service state : active"
    else
      echo "Service state : inactive"
    fi

    if systemctl is-enabled "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      echo "Service boot  : enabled"
    else
      echo "Service boot  : disabled or masked"
    fi
  else
    echo "Service state : service file not found"
  fi

  if pgrep -af "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    echo "Process state : running"
    pgrep -af "${DEFAULT_DAEMON}"
  else
    echo "Process state : not running"
  fi

  if timeout 5 "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" getblockcount >/dev/null 2>&1; then
    echo "RPC state     : responding"
  else
    echo "RPC state     : not responding"
  fi

  print_line
}

stop_daemon_cautious() {
  print_line
  warn "The next step can stop the daemon and service."
  warn "This is required for cleanup or recovery actions."

  if ! ask_yes_no "Do you want to try stopping the masternode daemon now?"; then
    warn "Stop step skipped by user."
    return 0
  fi

  info "Trying systemctl stop first..."
  systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl stop did not succeed."
  sleep 8

  if ask_yes_no "Do you want to temporarily disable the service to prevent auto-restart during recovery?"; then
    info "Trying systemctl disable..."
    systemctl disable "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl disable did not succeed."
    SERVICE_WAS_DISABLED=1
    sleep 3
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    info "Trying RPC stop..."
    run_cli stop >/dev/null 2>&1 || warn "RPC stop did not succeed."
    sleep 10
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon is still running after systemctl stop and RPC stop."

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
    warn "Daemon is still running after hard kill."

    if ask_yes_no "Do you want to temporarily mask the service to block all restarts?"; then
      systemctl mask "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl mask did not succeed."
      SERVICE_WAS_MASKED=1
      systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || true
      sleep 5
    fi
  fi

  show_stop_summary

  if verify_daemon_stopped; then
    success "Daemon and service appear to be fully stopped."
    return 0
  fi

  error "Safe stopped state was NOT confirmed."
  warn "Cleanup or resync actions must not continue."
  return 1
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
  echo " - ${DEFAULT_DATA_DIR}/banlist.json (or banlist.dat)"
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
  rm -f "${DEFAULT_DATA_DIR}/banlist.json" "${DEFAULT_DATA_DIR}/banlist.dat"
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
  dedupe_good_addnodes_array
  warn "Recovery with trusted addnodes will now manage addnode entries in defcon.conf."

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
  warn "Restore normal mode will remove the helper-managed addnode section from defcon.conf."

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

restore_service_if_needed() {
  if [[ "${SERVICE_WAS_MASKED}" -eq 0 && "${SERVICE_WAS_DISABLED}" -eq 0 ]]; then
    return 0
  fi

  print_line
  info "Recovery helper changed the service state earlier."

  if [[ "${SERVICE_WAS_MASKED}" -eq 1 ]]; then
    echo " - Service was temporarily masked"
  fi

  if [[ "${SERVICE_WAS_DISABLED}" -eq 1 ]]; then
    echo " - Service was temporarily disabled"
  fi

  print_line

  if ! ask_yes_no "Do you want to restore the service state now and start the service?"; then
    warn "Service restore skipped by user."
    warn "If needed, restore it manually later with systemctl unmask/enable/start."
    return 0
  fi

  if [[ "${SERVICE_WAS_MASKED}" -eq 1 ]]; then
    info "Trying systemctl unmask ${DEFAULT_SERVICE}..."
    if ! systemctl unmask "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      error "systemctl unmask did not succeed."
    else
      success "Service unmasked."
    fi
    sleep 2
  fi

  if [[ "${SERVICE_WAS_DISABLED}" -eq 1 ]]; then
    info "Trying systemctl enable ${DEFAULT_SERVICE}..."
    if ! systemctl enable "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      error "systemctl enable did not succeed."
    else
      success "Service enabled."
    fi
    sleep 2
  fi

  info "Trying systemctl start ${DEFAULT_SERVICE}..."
  if ! systemctl start "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
    error "systemctl start did not succeed."
    echo "Check with: systemctl status ${DEFAULT_SERVICE}"
    echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
    sleep 2
  else
    sleep 5
    if systemctl is-active --quiet "${DEFAULT_SERVICE}"; then
      success "Daemon appears to be running after service restore."
    else
      warn "Daemon does not appear to be running after service restore."
      echo "Check with: systemctl status ${DEFAULT_SERVICE}"
      echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
    fi
  fi

  check_service_and_process
}

start_daemon_cautious() {
  print_line
  warn "The script can now try to start the daemon again."

  if ! ask_yes_no "Do you want to start the daemon now?"; then
    warn "Start step skipped by user."
    return 0
  fi

  info "Ensuring no manual ${DEFAULT_DAEMON} processes are running..."
  pkill -f "${DEFAULT_DAEMON}" >/dev/null 2>&1 || true
  sleep 2

  info "Trying systemctl start ${DEFAULT_SERVICE}..."
  if ! systemctl start "${DEFAULT_SERVICE}"; then
    error "systemctl start did not succeed."
    echo "Check with: systemctl status ${DEFAULT_SERVICE}"
    echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
    return 1
  fi

  sleep 5

  if systemctl is-active --quiet "${DEFAULT_SERVICE}"; then
    success "Daemon appears to be running via systemd."
    return 0
  else
    error "Daemon does not appear to be running after systemd start."
    echo "Check with: systemctl status ${DEFAULT_SERVICE}"
    echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
    return 1
  fi
}

show_protx_placeholder() {
  print_line
  echo "Controller wallet step:"
  echo
  echo "Run the following command in the controller wallet console after the VPS node is fully synced:"
  echo
  echo 'protx update_service "PROTX_HASH" "IP:8192" "BLS_SECRET_KEY" "" "FEE_SOURCE_ADDRESS"'
  echo
  echo "[Hint] To copy from PuTTY without stopping the script:"
  echo "- Do NOT press Ctrl + C or right-click."
  echo "- Just select text with the left mouse button; it is copied automatically."
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
  echo "The recommended way is to use 'p' (show sync progress) repeatedly and only"
  echo "continue with 'x' once everything is fully synced and all flags are true."
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
  local block_height sync_json
  local asset_name is_blockchain_synced is_synced is_failed is_failed_raw

  block_height="$(run_cli getblockcount 2>/dev/null || true)"
  sync_json="$(run_cli mnsync status 2>/dev/null || true)"

  asset_name="$(echo "$sync_json" | jq -r '.AssetName // "unknown"' 2>/dev/null)"
  is_blockchain_synced="$(echo "$sync_json" | jq -r '.IsBlockchainSynced // "unknown"' 2>/dev/null)"
  is_synced="$(echo "$sync_json" | jq -r '.IsSynced // "unknown"' 2>/dev/null)"
  is_failed_raw="$(echo "$sync_json" | jq -r '.IsFailed // empty' 2>/dev/null)"
  if [[ "$is_failed_raw" == "true" ]]; then
    is_failed="true"
  else
    is_failed="false"
  fi

  echo
  echo "Sync Progress"
  echo "-------------"
  echo "Local block height: ${block_height:-unknown}"

  echo "Masternode sync stage: ${asset_name:-unknown}"
  echo "Blockchain synced: ${is_blockchain_synced:-unknown}"
  echo "Masternode synced: ${is_synced:-unknown}"
  echo "Sync failed: ${is_failed}"
  echo

  if [[ "$is_synced" == "true" && "$asset_name" == "MASTERNODE_SYNC_FINISHED" ]]; then
    success "Sync completed. You can continue with 'x' and the next recovery step."
  else
    warn "Your node is still syncing. Please wait before continuing."
  fi
}

run_recovery_plain_mode() {
  info "Selected: Recovery without trusted addnodes."
  print_line
  echo "This mode performs a cautious recovery WITHOUT changing addnode settings."
  echo "No PoSe-based temporary banlist will be prepared in this mode."
  print_line

  show_local_status
  check_service_and_process
  backup_conf

  stop_daemon_cautious || exit 1

  if ! verify_daemon_stopped; then
    error "Verified stopped state was not reached."
    warn "Aborting before cleanup to avoid corruption."
    exit 1
  fi

  remove_lock_file
  cleanup_recovery_files

  start_daemon_cautious || exit 1

  interactive_monitoring_menu
  info "Showing final local status snapshot..."
  show_local_status
  show_protx_placeholder
  restore_service_if_needed
}

run_recovery_addnodes_mode() {
  info "Selected: Recovery with trusted addnodes."
  print_line
  echo "This mode performs a cautious recovery AND manages a helper-controlled trusted addnode list in defcon.conf."
  echo "PoSe-based bans can optionally be prepared and will be applied after cleanup and restart."
  print_line

  prompt_addnodes_source
  validate_addnodes
  show_addnodes
  prompt_reference_height
  prompt_addnode_check_mode
  pick_random_candidates
  check_addnode_candidates
  show_local_status
  check_service_and_process
  backup_conf
  offer_pose_banlist_preparation

  stop_daemon_cautious || {
    error "Verified stopped state was not reached."
    warn "Aborting before cleanup to avoid corruption."
    exit 1
  }

  if ! verify_daemon_stopped; then
    error "Verified stopped state was not reached."
    warn "Aborting before cleanup to avoid corruption."
    exit 1
  fi

  remove_lock_file
  cleanup_recovery_files
  write_trusted_addnodes_to_conf
  start_daemon_cautious || {
    error "Daemon start step failed."
    exit 1
  }

  apply_prepared_pose_bans
  interactive_monitoring_menu

  info "Showing final local status snapshot..."
  show_local_status
  show_protx_placeholder
  restore_service_if_needed
}

check_ready_for_restore() {
  while true; do
    print_line
    info "Checking if masternode is ready for restore normal mode..."

    local mn_json mn_state mn_status sync_json asset_name is_synced

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
      success "Masternode appears to be READY and fully synced. Continuing with restore normal mode."
      return 0
    fi

    error "Restore normal mode is not recommended yet."
    echo "The masternode does not meet the recommended conditions for restore normal mode:"
    echo "  - state should be 'READY'"
    echo "  - sync stage should be 'MASTERNODE_SYNC_FINISHED'"
    echo "  - 'IsSynced' should be true"
    print_line
    echo "Choose how to proceed:"
    echo "  1) Check status again"
    echo "  2) Continue with restore normal mode anyway (not recommended)"
    echo "  3) Exit without making changes"
    print_line

    local choice
    read -r -p "Enter 1, 2 or 3: " choice

    case "$choice" in
      1)
        ;;
      2)
        warn "Continuing with restore normal mode despite not meeting recommended conditions."
        return 0
        ;;
      3)
        warn "Aborting restore normal mode at user request."
        exit 1
        ;;
      *)
        warn "Invalid selection. Please choose 1, 2 or 3."
        ;;
    esac
  done
}

run_restore_mode() {
  info "Selected: Restore normal mode (remove helper-managed addnodes + PoSe-bans)."
  print_line
  echo "This mode is intended to revert changes made by Recovery with trusted addnodes"
  echo "and to remove temporary PoSe bans created by this helper."
  echo "Unlike recovery modes, this mode does not require the daemon to be started in advance."
  print_line

  check_ready_for_restore
  show_local_status
  check_service_and_process
  backup_conf

  stop_daemon_cautious || exit 1

  if ! verify_daemon_stopped; then
    error "Verified stopped state was not reached."
    warn "Aborting before changing the configuration."
    exit 1
  fi

  remove_lock_file
  restore_normal_mode_conf

  start_daemon_cautious || exit 1

  remove_tracked_pose_bans

  info "Showing final local status snapshot..."
  show_local_status
  restore_service_if_needed
}

main() {
  show_intro
  check_root
  show_defaults
  check_conf_file
  check_binaries
  choose_mode

  case "${MODE}" in
    recoveryplain)
      ensure_daemon_running || exit 1
      run_recovery_plain_mode
      ;;
    recoveryaddnodes)
      ensure_daemon_running || exit 1
      run_recovery_addnodes_mode
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

  if [[ "${MODE}" == "recoveryaddnodes" ]]; then
    print_line
    echo "Note:"
    echo "Once your masternode has been fully synced and stable for several days, run this script again and select"
    echo "\"Restore normal mode\" to revert from helper-managed trusted addnodes and remove temporary PoSe bans."
  fi

  print_line
}

main "$@"

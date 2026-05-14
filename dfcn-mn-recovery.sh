#!/usr/bin/env bash

set -u

SCRIPT_VERSION="0.5.1"

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

MAX_RANDOM_CANDIDATES=50
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

SYNC_READY_SINCE_EPOCH=""
PROTX_MIN_CONNECTIONS=6
PROTX_MAX_PEER_PING=2
PROTX_MIN_READY_SECONDS=900
PROTX_MAX_TIP_AGE=900

FORK_TIPS_SINCE=""
HEADERS_TIPS_SINCE=""
FORK_TIPS_WARN_THRESHOLD=1200      # 20 minutes
HEADERS_TIPS_WARN_THRESHOLD=1200   # 20 minutes

ORIGINAL_ARGS=("$@")

EARLY_BOOTSTRAP_TARGET_COUNT=5
EARLY_BOOTSTRAP_MAX_CANDIDATES=25
EARLY_BOOTSTRAP_FILE="${DEFAULT_DATA_DIR}/early_bootstrap_nodes.txt"

# --- Auto-restore scheduler ---
AUTO_RESTORE_DELAY_SECONDS=$((48 * 3600))    # 48 hours until auto-restore
AUTO_RESTORE_RETRY_SECONDS=$((12 * 3600))    # retry 12 hours later if restore is not recommended yet
AUTO_RESTORE_MAX_RETRIES=2                   # after 2 retries, force auto-restore even if not ready
AUTO_RESTORE_STATE_FILE="${DEFAULT_DATA_DIR}/auto_restore_pending.txt"
AUTO_RESTORE_UNIT="dfcn-autorestore-${DEFAULT_SERVICE}"

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

service_unit_exists() {
  systemctl list-unit-files | grep -q "^${DEFAULT_SERVICE}\.service"
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

dedupe_early_bootstrap_array() {
  local -A seen=()
  local -a result=()
  local item

  for item in "${EARLY_BOOTSTRAP_NODES[@]}"; do
    if [[ -n "${item}" && -z "${seen[$item]:-}" ]]; then
      seen["$item"]=1
      result+=("$item")
    fi
  done

  EARLY_BOOTSTRAP_NODES=("${result[@]}")
}

normalize_node() {
  local node="$1"
  if [[ "$node" != *:* ]]; then
    echo "${node}:${DEFAULT_PORT}"
  else
    echo "$node"
  fi
}

test_node_early_bootstrap() {
  local node="$1"
  local host port peer_json peer_height

  if ! is_number "${REFERENCE_HEIGHT}" || (( REFERENCE_HEIGHT == 0 )); then
    warn "Early bootstrap skipped: REFERENCE_HEIGHT is not set or invalid."
    return 1
  fi

  host="${node%:*}"
  port="${node##*:}"

  info "Early bootstrap test for ${node}"

  if ! timeout "${ADDNODE_TCP_TIMEOUT}" bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
    warn "Early bootstrap port check failed for ${node}"
    return 1
  fi

  run_cli addnode "${node}" onetry >/dev/null 2>&1 || true
  sleep "${ADDNODE_PEER_SLEEP}"

  peer_json="$(get_peer_json_by_host "$host" 2>/dev/null || true)"
  if [[ -z "${peer_json}" ]]; then
    warn "Early bootstrap peer check failed for ${node} (not visible in getpeerinfo)"
    return 1
  fi

  peer_height="$(jq -r '.synced_headers // .startingheight // .synced_blocks // empty' <<< "${peer_json}" 2>/dev/null || true)"

  # Erst: ist peer_height überhaupt eine gültige Zahl > 0?
  if ! is_number "${peer_height}" || (( peer_height == 0 )); then
    warn "Early bootstrap rejected: ${node} (peer height is 0 or unknown)"
    return 1
  fi

  echo "  Early peer height : ${peer_height}"
  echo "  Reference height  : ${REFERENCE_HEIGHT}"

  # Dann: Height-Diff-Check
  if (( peer_height + ADDNODE_MAX_HEIGHT_DIFF < REFERENCE_HEIGHT )); then
    warn "Early bootstrap rejected: ${node} (peer height ${peer_height} too far behind reference ${REFERENCE_HEIGHT})"
    return 1
  fi

  success "Early bootstrap candidate accepted: ${node}"
  return 0
}

pick_random_early_bootstrap_candidates() {
  EARLY_BOOTSTRAP_CANDIDATES=()

  check_addnode_file
  load_addnodes
  dedupe_addnodes_array
  validate_addnodes

  mapfile -t EARLY_BOOTSTRAP_CANDIDATES < <(
    printf '%s\n' "${ADDNODES[@]}" | shuf | head -n "${EARLY_BOOTSTRAP_MAX_CANDIDATES}"
  )

  if [[ "${#EARLY_BOOTSTRAP_CANDIDATES[@]}" -eq 0 ]]; then
    warn "No early bootstrap candidates were selected."
    return 1
  fi

  print_line
  info "Random early bootstrap candidates selected:"
  for node in "${EARLY_BOOTSTRAP_CANDIDATES[@]}"; do
    echo "  - ${node}"
  done
  print_line

  return 0
}

write_early_bootstrap_file() {
  local tmp_file
  tmp_file="${EARLY_BOOTSTRAP_FILE}.tmp"

  {
    echo "# DeFCoN Recovery Helper early bootstrap nodes"
    echo "# Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "# Reference height: ${REFERENCE_HEIGHT}"
    echo "# Temporary file for bootstrap only"
    echo "# Do not treat this as the final verified recovery addnode set"
    printf '%s\n' "${EARLY_BOOTSTRAP_NODES[@]}"
  } > "${tmp_file}"

  mv "${tmp_file}" "${EARLY_BOOTSTRAP_FILE}"
  chmod 600 "${EARLY_BOOTSTRAP_FILE}" >/dev/null 2>&1 || true
}

load_early_bootstrap_file() {
  EARLY_BOOTSTRAP_NODES=()

  if [[ ! -f "${EARLY_BOOTSTRAP_FILE}" ]]; then
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"

    if [[ -n "${line}" ]]; then
      line="$(awk '{print $1}' <<< "${line}")"
      line="$(normalize_node "${line}")"
      if echo "${line}" | grep -Eq '^[A-Za-z0-9._-]+:[0-9]+$'; then
        EARLY_BOOTSTRAP_NODES+=("${line}")
      fi
    fi
  done < "${EARLY_BOOTSTRAP_FILE}"

  dedupe_early_bootstrap_array

  [[ "${#EARLY_BOOTSTRAP_NODES[@]}" -gt 0 ]]
}

apply_early_bootstrap_nodes() {
  local node applied_count=0

  if [[ "${#EARLY_BOOTSTRAP_NODES[@]}" -eq 0 ]]; then
    warn "No early bootstrap nodes are available to apply."
    return 1
  fi

  print_line
  info "Applying temporary early bootstrap nodes..."

  for node in "${EARLY_BOOTSTRAP_NODES[@]}"; do
    if run_cli addnode "${node}" onetry >/dev/null 2>&1; then
      applied_count=$((applied_count + 1))
      echo "  applied: ${node}"
    else
      warn "Could not apply early bootstrap addnode: ${node}"
    fi
  done

  print_line
  echo "Early bootstrap apply summary:"
  echo " - Target count     : ${EARLY_BOOTSTRAP_TARGET_COUNT}"
  echo " - Selected good    : ${#EARLY_BOOTSTRAP_NODES[@]}"
  echo " - Applied via RPC  : ${applied_count}"
  print_line

  return 0
}

prepare_early_bootstrap_nodes() {
  local node
  local mode="${1:-interactive}"

  EARLY_BOOTSTRAP_NODES=()
  EARLY_BOOTSTRAP_CANDIDATES=()

  rm -f "${EARLY_BOOTSTRAP_FILE}" >/dev/null 2>&1 || true

  print_line
  echo "Temporary early bootstrap addnode step"
  echo
  echo "This step tries to build a temporary bootstrap list from"
  echo "a random subset of trusted_addnodes.txt."
  echo
  echo "Purpose:"
  echo " - help the node connect if normal seed nodes are unavailable"
  echo " - help sync get started so block height can move again"
  echo " - improve the basis for later recovery checks"
  echo
  echo "Important:"
  echo " - this is only a temporary bootstrap list"
  echo " - it is separate from the later full addnode verification in mode 2"
  print_line

  if [[ "${mode}" != "non_interactive" ]]; then
    if ! ask_yes_no "Do you want to run the temporary early bootstrap addnode step now?"; then
      warn "Early bootstrap addnode step skipped by user."
      return 0
    fi
  else
    info "Running temporary early bootstrap addnode step in non-interactive mode."
  fi

  if ! pick_random_early_bootstrap_candidates; then
    warn "Early bootstrap candidate preparation failed."
    if [[ "${mode}" == "non_interactive" ]]; then
      return 1
    fi
    return 0
  fi

  for node in "${EARLY_BOOTSTRAP_CANDIDATES[@]}"; do
    if test_node_early_bootstrap "${node}"; then
      EARLY_BOOTSTRAP_NODES+=("${node}")
      dedupe_early_bootstrap_array

      if [[ "${#EARLY_BOOTSTRAP_NODES[@]}" -ge "${EARLY_BOOTSTRAP_TARGET_COUNT}" ]]; then
        break
      fi
    fi

    print_line
  done

  if [[ "${#EARLY_BOOTSTRAP_NODES[@]}" -eq 0 ]]; then
    warn "No early bootstrap nodes passed the temporary checks."
    rm -f "${EARLY_BOOTSTRAP_FILE}" >/dev/null 2>&1 || true
    if [[ "${mode}" == "non_interactive" ]]; then
      return 1
    fi
    return 0
  fi

  print_line
  echo "Temporary early bootstrap nodes selected:"
  for node in "${EARLY_BOOTSTRAP_NODES[@]}"; do
    echo "  - ${node}"
  done
  print_line

  write_early_bootstrap_file
  success "Temporary early bootstrap node file created: ${EARLY_BOOTSTRAP_FILE}"
  return 0
}

maybe_apply_early_bootstrap_fallback() {
  local net_json connections peer_count
  local wait_seconds=15

  print_line
  info "Checking whether temporary early bootstrap fallback is needed..."

  sleep "${wait_seconds}"

  net_json="$(run_cli getnetworkinfo 2>/dev/null || true)"
  connections="$(jq -r '.connections // 0' <<< "${net_json}" 2>/dev/null || echo 0)"
  peer_count="$(run_cli getpeerinfo 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"

  echo "Current network state after startup wait:"
  echo " - connections : ${connections}"
  echo " - peer count  : ${peer_count}"
  print_line

  if [[ "${connections}" -ge 1 || "${peer_count}" -ge 1 ]]; then
    success "Normal peer discovery appears to be working. Early bootstrap fallback is not needed."
    return 0
  fi

  warn "No usable peer connections detected after startup wait."
  warn "Trying temporary early bootstrap fallback list now..."

  if [[ ! -f "${EARLY_BOOTSTRAP_FILE}" ]]; then
    warn "No temporary early bootstrap file is available yet."
    info "Trying to create a temporary early bootstrap file now..."
    prepare_early_bootstrap_nodes "non_interactive"
  fi

  if ! load_early_bootstrap_file; then
    warn "No temporary early bootstrap file is available."
    return 0
  fi

  apply_early_bootstrap_nodes
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
    warn "WARNING: Your node may be on the wrong fork."
    warn "The local block height (${local_height}) may be INCORRECT."
    warn "It is strongly recommended to enter the reference height from the official explorer."
    echo
    if ! ask_yes_no "Are you sure you want to use the local block height ${local_height} as reference?"; then
        error "Please restart and enter the correct reference height manually."
        exit 1
    fi
    REFERENCE_HEIGHT="$local_height"
    info "Using local block height as reference: ${REFERENCE_HEIGHT}"
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
  echo "  3) Automatic recovery with trusted addnodes"
  echo "  4) Automatic recovery (without trusted addnodes)"
  echo "  5) Restore normal mode (remove helper-managed addnodes + PoSe-bans)"
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
  echo "3. Automatic recovery with trusted addnodes"
  echo "4. Automatic recovery (without trusted addnodes)"
  echo "5. Restore normal mode (remove helper-managed addnodes + PoSe-bans)"
  print_line

  read -r -p "Enter 1, 2, 3, 4 or 5: " SELECTED_MODE

  case "${SELECTED_MODE}" in
    1)
      MODE="recovery_plain"
      ;;
    2)
      MODE="recovery_addnodes"
      ;;
    3)
      MODE="recovery_addnodes_auto"
      ;;
    4)
      MODE="recovery_plain_auto"
      ;;
    5)
      MODE="restore"
      ;;
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
  local mode="${1:-interactive}"

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
    if [[ "${mode}" != "non_interactive" ]]; then
      if ask_yes_no "Do you want to remove the empty or invalid PoSe banlist file now?"; then
        rm -f "${POSE_BANLIST_FILE}"
        success "PoSe banlist file removed."
      fi
    else
      warn "Removing empty or invalid PoSe banlist file in non-interactive mode."
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

  if [[ "${mode}" != "non_interactive" ]]; then
    if ! ask_yes_no "Do you want to remove these recovery-helper PoSe bans now?"; then
      warn "Removal of tracked PoSe bans skipped by user."
      return 0
    fi
  else
    info "Removing tracked PoSe bans in non-interactive mode."
  fi

  local removed=0
  local missing=0
  local ip

  for ip in "${TRACKED_POSE_IPS[@]}"; do
    if run_cli setban "${ip}" remove >/dev/null 2>&1; then
      removed=$((removed + 1))
    else
      missing=$((missing + 1))
      warn "Ban for IP not found or already expired: ${ip}"
    fi
  done

  print_line
  echo "Tracked PoSe ban removal summary:"
  echo " - Successfully removed                : ${removed}"
  echo " - Not currently banned or remove failed: ${missing}"
  print_line

  if [[ "${mode}" != "non_interactive" ]]; then
    if ask_yes_no "Do you want to delete the recovery-helper PoSe banlist file now?"; then
      rm -f "${POSE_BANLIST_FILE}"
      if (( removed > 0 )); then
        success "Recovery-helper PoSe banlist file removed after tracked bans were cleaned up."
      else
        warn "Recovery-helper PoSe banlist file removed, but no active bans could be removed."
      fi
    else
      warn "PoSe banlist file was kept."
    fi
  else
    rm -f "${POSE_BANLIST_FILE}"
    if (( removed > 0 )); then
      success "Recovery-helper PoSe banlist file removed after tracked bans were cleaned up."
    else
      warn "Recovery-helper PoSe banlist file removed, but no active bans could be removed."
    fi
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

  if service_unit_exists; then
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
  echo " - Process stopped : $([[ ${proc_dead} -eq 0 ]] && echo yes || echo no)"
  echo " - Service inactive: $([[ ${service_inactive} -eq 0 ]] && echo yes || echo no)"
  echo " - RPC unreachable : $([[ ${rpc_dead} -eq 0 ]] && echo yes || echo no)"
  print_line

  if [[ ${proc_dead} -eq 0 && ${service_inactive} -eq 0 && ${rpc_dead} -eq 0 ]]; then
    return 0
  fi

  return 1
}

show_stop_summary() {
  print_line
  echo "Shutdown summary"
  echo "----------------"

  if service_unit_exists; then
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

  if [[ "${SERVICE_WAS_DISABLED}" -eq 1 ]]; then
    echo "Service note  : temporarily disabled by recovery helper"
  fi

  if [[ "${SERVICE_WAS_MASKED}" -eq 1 ]]; then
    echo "Service note  : temporarily masked by recovery helper"
  fi

  print_line
}

recovery_abort_notice() {
  local exit_code="$?"

  if [[ "${SERVICE_WAS_DISABLED}" -eq 1 || "${SERVICE_WAS_MASKED}" -eq 1 ]]; then
    print_line
    warn "The script is exiting while the service may still be in a temporary recovery state."

    if [[ "${SERVICE_WAS_DISABLED}" -eq 1 ]]; then
      warn "Service note: ${DEFAULT_SERVICE} may still be disabled."
      echo "Manual check: systemctl is-enabled ${DEFAULT_SERVICE}"
      echo "Manual fix  : systemctl enable ${DEFAULT_SERVICE}"
    fi

    if [[ "${SERVICE_WAS_MASKED}" -eq 1 ]]; then
      warn "Service note: ${DEFAULT_SERVICE} may still be masked."
      echo "Manual check: systemctl is-enabled ${DEFAULT_SERVICE}"
      echo "Manual fix  : systemctl unmask ${DEFAULT_SERVICE}"
      echo "              systemctl enable ${DEFAULT_SERVICE}"
    fi

    echo "After that, start it again if needed:"
    echo "  systemctl start ${DEFAULT_SERVICE}"
    print_line
  fi

  return "${exit_code}"
}

stop_daemon_cautious() {
  print_line
  warn "The next step can stop the daemon and service."
  warn "This is required for cleanup or recovery actions."

  if ! ask_yes_no "Do you want to try stopping the masternode daemon now?"; then
    warn "Stop step skipped by user."
    return 1
  fi

  if service_unit_exists; then
    if systemctl is-enabled "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      info "Service is enabled. Trying systemctl disable first to prevent auto-restart..."
      if systemctl disable "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
        SERVICE_WAS_DISABLED=1
        success "Service disabled temporarily."
      else
        warn "systemctl disable did not succeed."
      fi
      sleep 2
    else
      info "Service is already not enabled."
    fi

    info "Trying systemctl stop..."
    systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl stop did not succeed."
    sleep 8
  else
    warn "Service file ${DEFAULT_SERVICE}.service was not found. Skipping systemctl disable/stop."
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    info "Trying RPC stop..."
    run_cli stop >/dev/null 2>&1 || warn "RPC stop did not succeed."
    sleep 10
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon is still running after service stop and RPC stop."

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

    if service_unit_exists; then
      if ask_yes_no "Do you want to temporarily mask the service to block all restarts?"; then
        if systemctl mask "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
          SERVICE_WAS_MASKED=1
          success "Service masked temporarily."
        else
          warn "systemctl mask did not succeed."
        fi
        systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || true
        sleep 5
      fi
    else
      warn "Service masking is not possible because no service file was found."
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
  local mode="${1:-interactive}"
  local lock_file="${DEFAULT_DATA_DIR}/.lock"

  if [ -f "${lock_file}" ]; then
    if [[ "${mode}" != "non_interactive" ]]; then
      if ask_yes_no "A lock file was found. Remove it?"; then
        rm -f "${lock_file}"
        success "Lock file removed."
      else
        warn "Lock file was not removed."
      fi
    else
      info "Removing lock file in non-interactive mode."
      rm -f "${lock_file}"
      success "Lock file removed."
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
    $0 == end   {skip=0; next}
    !skip {print}
  ' "${DEFAULT_CONF_FILE}" > "${DEFAULT_CONF_FILE}.tmp"

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
  local mode="${1:-interactive}"

  print_line
  warn "Restore normal mode will remove the helper-managed addnode section from defcon.conf."

  if ! has_managed_addnode_section; then
    info "No helper-managed trusted addnode section found in defcon.conf."
    return 0
  fi

  if [[ "${mode}" != "non_interactive" ]]; then
    if ! ask_yes_no "Do you want to remove the managed trusted addnode section now?"; then
      warn "Restore step skipped by user."
      return 0
    fi
  else
    info "Removing helper-managed addnode section in non-interactive mode."
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
  print_line
  info "Final service restore/start step..."

  if ! service_unit_exists; then
    error "Service file ${DEFAULT_SERVICE}.service was not found."
    echo "Automatic enable/start via systemctl is not possible."
    return 1
  fi

  info "Ensuring no manual ${DEFAULT_DAEMON} processes are running..."
  pkill -f "${DEFAULT_DAEMON}" >/dev/null 2>&1 || true
  sleep 2

  local enabled_state
  enabled_state="$(systemctl is-enabled "${DEFAULT_SERVICE}" 2>/dev/null || true)"

  if [[ "${enabled_state}" == "enabled" ]]; then
    info "Service is already enabled."
  else
    if [[ "${enabled_state}" == "masked" ]]; then
      info "Service is masked. Trying systemctl unmask ${DEFAULT_SERVICE}..."
      if ! systemctl unmask "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
        error "systemctl unmask did not succeed."
        return 1
      fi
      success "Service unmasked."
      sleep 2
    fi

    info "Trying systemctl enable ${DEFAULT_SERVICE}..."
    if ! systemctl enable "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      error "systemctl enable did not succeed."
      return 1
    fi
    success "Service enabled."
    sleep 2
  fi

  info "Trying systemctl start ${DEFAULT_SERVICE}..."
  if ! systemctl start "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
    error "systemctl start did not succeed."
    echo "Check with: systemctl status ${DEFAULT_SERVICE}"
    echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
    return 1
  fi

  sleep 5

  if systemctl is-active --quiet "${DEFAULT_SERVICE}"; then
    success "Daemon appears to be running via systemd."
    check_service_and_process
    return 0
  fi

  error "Daemon does not appear to be running after final service start."
  echo "Check with: systemctl status ${DEFAULT_SERVICE}"
  echo "        and: journalctl -u ${DEFAULT_SERVICE} -n 50"
  check_service_and_process
  return 1
}

show_protx_placeholder() {
  local local_ip service protx_json protx_hash payout_address bls_key cmd_service
  local command_shown=0

  local_ip="$(get_local_service_ip 2>/dev/null || true)"

  if [[ -n "${local_ip}" ]]; then
    service="${local_ip}:${DEFAULT_PORT}"
    protx_json="$(get_protx_match "${service}" 2>/dev/null || true)"
  else
    service=""
    protx_json=""
  fi

  if [[ -n "${protx_json}" ]]; then
    protx_hash="$(echo "${protx_json}" | jq -r '.proTxHash // empty' 2>/dev/null)"
    payout_address="$(echo "${protx_json}" | jq -r '.state.payoutAddress // empty' 2>/dev/null)"
    cmd_service="$(echo "${protx_json}" | jq -r '.state.service // empty' 2>/dev/null)"
  else
    protx_hash=""
    payout_address=""
    cmd_service=""
  fi

  bls_key="$(grep -E '^[[:space:]]*masternodeblsprivkey=' "${DEFAULT_CONF_FILE}" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)"

  print_line
  echo "Controller wallet step:"
  echo
  echo "Run the following command in the controller wallet console after the VPS node is fully synced:"
  echo

  if [[ -n "${cmd_service}" ]]; then
    service="${cmd_service}"
  fi

  if [[ -n "${protx_hash}" && -n "${service}" && -n "${bls_key}" ]]; then
    if [[ -n "${payout_address}" ]]; then
      echo "protx update_service \"${protx_hash}\" \"${service}\" \"${bls_key}\" \"\" \"${payout_address}\""
      command_shown=1
    else
      echo "protx update_service \"${protx_hash}\" \"${service}\" \"${bls_key}\" \"\" \"FEE_SOURCE_ADDRESS\""
      command_shown=1
    fi
  fi

  if [[ "${command_shown}" -eq 0 ]]; then
    echo 'protx update_service "PROTX_HASH" "IP:8192" "BLS_SECRET_KEY" "" "FEE_SOURCE_ADDRESS"'
  fi

  echo
  if [[ -n "${payout_address}" ]]; then
    echo "[Hint] The current payout address was inserted as fee source address."
    echo "[Hint] You may replace it with a separate funded fee address from the controller wallet."
    echo
  fi

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

is_sync_finished() {
  local sync_json="${1:-}"
  local asset_name is_blockchain_synced is_synced is_failed_raw

  if [[ -z "${sync_json}" ]]; then
    sync_json="$(run_cli mnsync status 2>/dev/null || true)"
  fi

  asset_name="$(echo "${sync_json}" | jq -r '.AssetName // empty' 2>/dev/null)"
  is_blockchain_synced="$(echo "${sync_json}" | jq -r '.IsBlockchainSynced // empty' 2>/dev/null)"
  is_synced="$(echo "${sync_json}" | jq -r '.IsSynced // empty' 2>/dev/null)"
  is_failed_raw="$(echo "${sync_json}" | jq -r '.IsFailed // "false"' 2>/dev/null)"

  if [[ "${asset_name}" == "MASTERNODESYNCFINISHED" ]] \
     && [[ "${is_blockchain_synced}" == "true" ]] \
     && [[ "${is_synced}" == "true" ]] \
     && [[ "${is_failed_raw}" != "true" ]]; then
    return 0
  fi

  return 1
}

interactive_monitoring_menu() {
  local skip_intro=0
  [[ "${1:-}" == "--no-intro" ]] && skip_intro=1

  if [[ "$skip_intro" -eq 0 ]]; then
    print_line
    echo "The node must now fully synchronize before you continue."
    echo "Use the following menu options to monitor sync progress."
    echo "Only continue with x when all of the following are true:"
    echo "  - Local block height matches the reference block height"
    echo "  - Masternode sync stage is 'MASTERNODESYNCFINISHED'"
    echo "  - 'Blockchain synced' is true"
    echo "  - 'Masternode synced' is true"
    print_line
  fi

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
  local now_ts ready_seconds

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

  if is_sync_finished "$sync_json"; then
    if [[ -z "${SYNC_READY_SINCE_EPOCH}" ]]; then
      SYNC_READY_SINCE_EPOCH="$(date +%s)"
    fi
  else
    SYNC_READY_SINCE_EPOCH=""
  fi

  echo
  echo "Sync Progress"
  echo "-------------"
  echo "Local block height: ${block_height:-unknown}"
  echo "Masternode sync stage: ${asset_name:-unknown}"
  echo "Blockchain synced: ${is_blockchain_synced:-unknown}"
  echo "Masternode synced: ${is_synced:-unknown}"
  echo "Sync failed: ${is_failed}"

  if [[ -n "${SYNC_READY_SINCE_EPOCH}" ]]; then
    now_ts="$(date +%s)"
    ready_seconds=$((now_ts - SYNC_READY_SINCE_EPOCH))
    echo "Fully synced for: ${ready_seconds} seconds"
  fi

  echo

  if is_sync_finished "$sync_json"; then
    success "Sync completed. You can continue with 'x' and the next recovery step."
  else
    warn "Your node is still syncing. Please wait before continuing."
  fi
}

get_protx_readiness_snapshot() {
  local bc_json sync_json net_json peer_json tips_json

  bc_json="$(run_cli getblockchaininfo 2>/dev/null || true)"
  sync_json="$(run_cli mnsync status 2>/dev/null || true)"
  net_json="$(run_cli getnetworkinfo 2>/dev/null || true)"
  peer_json="$(run_cli getpeerinfo 2>/dev/null || true)"
  tips_json="$(run_cli getchaintips 2>/dev/null || true)"

  [[ -z "$bc_json" ]] && bc_json="{}"
  [[ -z "$sync_json" ]] && sync_json="{}"
  [[ -z "$net_json" ]] && net_json="{}"
  [[ -z "$peer_json" ]] && peer_json="[]"
  [[ -z "$tips_json" ]] && tips_json="[]"

  local blocks headers
  local asset_name is_blockchain_synced is_synced is_failed
  local connections peer_count
  local headers_only_count fork_count conflicting_count
  local high_ping_count max_ping
  local now_ts ready_seconds
  local block_time best_block_age
  local fork_warn_minutes=$(( FORK_TIPS_WARN_THRESHOLD / 60 ))
  local headers_warn_minutes=$(( HEADERS_TIPS_WARN_THRESHOLD / 60 ))

  local active_height=""
  local overall_tip_rating="NONE"
  local has_non_active_tips=0
  local fork_elapsed=0
  local headers_elapsed=0
  local hard_fail=0

  local -a tip_analysis_lines=()
  local line tip_height branchlen status diff tip_rating

  blocks="$(echo "$bc_json" | jq -r '.blocks // "unknown"' 2>/dev/null)"
  headers="$(echo "$bc_json" | jq -r '.headers // "unknown"' 2>/dev/null)"
  block_time="$(echo "$bc_json" | jq -r '.time // 0' 2>/dev/null)"

  asset_name="$(echo "$sync_json" | jq -r '.AssetName // "unknown"' 2>/dev/null)"
  is_blockchain_synced="$(echo "$sync_json" | jq -r '.IsBlockchainSynced // "unknown"' 2>/dev/null)"
  is_synced="$(echo "$sync_json" | jq -r '.IsSynced // "unknown"' 2>/dev/null)"
  is_failed="$(echo "$sync_json" | jq -r '.IsFailed // "unknown"' 2>/dev/null)"

  connections="$(echo "$net_json" | jq -r '.connections // 0' 2>/dev/null)"
  peer_count="$(echo "$peer_json" | jq 'length' 2>/dev/null || echo 0)"

  headers_only_count="$(echo "$tips_json" | jq '[.[] | select((.status // "") == "headers-only")] | length' 2>/dev/null || echo 0)"
  fork_count="$(echo "$tips_json" | jq '[.[] | select((.status // "") == "valid-fork" or (.status // "") == "valid-headers")] | length' 2>/dev/null || echo 0)"
  conflicting_count="$(echo "$tips_json" | jq '[.[] | select((.status // "") == "conflicting")] | length' 2>/dev/null || echo 0)"

  high_ping_count="$(echo "$peer_json" | jq --argjson max_ping "${PROTX_MAX_PEER_PING}" '[.[] | select(((.pingtime // 999999) > $max_ping))] | length' 2>/dev/null || echo 0)"
  max_ping="$(echo "$peer_json" | jq -r '[.[].pingtime // empty] | max // "n/a"' 2>/dev/null || echo "n/a")"

  if is_number "${block_time}" && (( block_time > 0 )); then
    now_ts="$(date +%s)"
    best_block_age=$(( now_ts - block_time ))
  else
    best_block_age=-1
  fi

  if [[ -n "${SYNC_READY_SINCE_EPOCH}" ]]; then
    now_ts="$(date +%s)"
    ready_seconds=$((now_ts - SYNC_READY_SINCE_EPOCH))
  else
    ready_seconds=0
  fi

  active_height="$(echo "$tips_json" | jq -r '.[] | select((.status // "") == "active") | .height' 2>/dev/null | head -n 1)"
  if ! is_number "${active_height}"; then
    active_height=""
  fi

  if [[ -n "${active_height}" ]]; then
    while IFS=$'\t' read -r tip_height branchlen status; do
      [[ -z "${tip_height}" ]] && continue
      has_non_active_tips=1

      if is_number "${active_height}" && is_number "${tip_height}"; then
        diff=$(( active_height - tip_height ))
      else
        diff=-1
      fi

      tip_rating="WAIT"

      case "${status}" in
        invalid)
          tip_rating="HARMLESS"
          ;;
        valid-fork)
          if is_number "${diff}" && is_number "${branchlen}" && (( diff >= 6 )) && (( branchlen <= 3 )); then
            tip_rating="HARMLESS"
          else
            tip_rating="WAIT"
          fi
          ;;
        valid-headers)
          if is_number "${diff}" && (( diff >= 6 )); then
            tip_rating="HARMLESS"
          else
            tip_rating="WAIT"
          fi
          ;;
        conflicting)
          if is_number "${diff}" && (( diff >= 6 )); then
            tip_rating="HARMLESS"
          else
            tip_rating="WAIT"
          fi
          ;;
        headers-only)
          if is_number "${active_height}" && is_number "${tip_height}" && (( tip_height >= active_height - 2 )); then
            tip_rating="CRITICAL"
          elif is_number "${diff}" && (( diff < 6 )); then
            tip_rating="CRITICAL"
          else
            tip_rating="WAIT"
          fi
          ;;
        *)
          tip_rating="WAIT"
          ;;
      esac

      case "${tip_rating}" in
        CRITICAL)
          overall_tip_rating="CRITICAL"
          ;;
        WAIT)
          if [[ "${overall_tip_rating}" != "CRITICAL" ]]; then
            overall_tip_rating="WAIT"
          fi
          ;;
        HARMLESS)
          if [[ "${overall_tip_rating}" == "NONE" ]]; then
            overall_tip_rating="HARMLESS"
          fi
          ;;
      esac

      tip_analysis_lines+=("  Tip height: ${tip_height} | branchlen: ${branchlen} | status: ${status} | diff: ${diff} -> ${tip_rating}")
    done < <(
      echo "${tips_json}" | jq -r '
        .[] | select((.status // "") != "active")
        | [
            (.height // "unknown"),
            (.branchlen // "unknown"),
            (.status // "unknown")
          ] | @tsv
      ' 2>/dev/null
    )
  fi

  print_line
  echo "ProTx readiness check"
  echo "---------------------"
  echo "Blocks                : ${blocks}"
  echo "Headers               : ${headers}"
  echo "Sync stage            : ${asset_name}"
  echo "Blockchain synced     : ${is_blockchain_synced}"
  echo "Masternode synced     : ${is_synced}"
  echo "Sync failed           : ${is_failed}"
  echo "Connections           : ${connections}"
  echo "Peers visible         : ${peer_count}"
  echo "Headers-only tips     : ${headers_only_count}"
  echo "Fork-like tips        : ${fork_count}"
  echo "Conflicting tips      : ${conflicting_count}"
  echo "Peers with ping > ${PROTX_MAX_PEER_PING}s: ${high_ping_count}"
  echo "Max peer ping         : ${max_ping}"
  if (( best_block_age >= 0 )); then
    echo "Best block age        : ${best_block_age} seconds"
  else
    echo "Best block age        : unknown"
  fi

  if [[ -n "${SYNC_READY_SINCE_EPOCH}" ]]; then
    echo "Fully synced for      : ${ready_seconds} seconds"
  else
    echo "Fully synced for      : not tracked yet"
  fi

  echo

  if [[ "${blocks}" != "${headers}" ]]; then
    warn "Blocks and headers do not match yet."
    hard_fail=1
  fi

  if [[ "${asset_name}" != "MASTERNODE_SYNC_FINISHED" ]]; then
    warn "Masternode sync stage is not MASTERNODE_SYNC_FINISHED yet."
    hard_fail=1
  fi

  if [[ "${is_blockchain_synced}" != "true" ]]; then
    warn "Blockchain synced is not true yet."
    hard_fail=1
  fi

  if [[ "${is_synced}" != "true" ]]; then
    warn "Masternode synced is not true yet."
    hard_fail=1
  fi

  if [[ "${is_failed}" == "true" ]]; then
    warn "Sync failed is true."
    hard_fail=1
  fi

  if ! is_number "${connections}" || (( connections < PROTX_MIN_CONNECTIONS )); then
    warn "Peer connectivity is still weaker than recommended."
    hard_fail=1
  fi

  if (( has_non_active_tips > 0 )); then
    echo "Chain tip analysis"
    echo "------------------"
    echo "(Includes conflicting tips in addition to headers-only / fork-like statuses.)"

    case "${overall_tip_rating}" in
      CRITICAL)
        warn "A headers-only tip at or near the current chain height was detected."
        warn "This may indicate an active fork attempt."
        warn "It is recommended to restart recovery with 'n'."
        info "The basic recovery without managed addnodes is usually enough; recovery with trusted addnodes is only needed in more complex cases."
        hard_fail=1
        ;;
      WAIT)
        warn "One or more chain tips are recent and need more time."
        info "Waiting is recommended. Run 'r' again in a few minutes."
        hard_fail=1
        ;;
      HARMLESS)
        success "All non-active chain tips appear harmless."
        success "Height distance and branch length are within safe thresholds."
        success "It is safe to continue with 'x' despite the tip count > 0."
        ;;
    esac

    for line in "${tip_analysis_lines[@]}"; do
      echo "${line}"
    done

    echo

    if (( fork_count > 0 )); then
      if [[ -z "${FORK_TIPS_SINCE}" ]]; then
        FORK_TIPS_SINCE="$(date +%s)"
      fi
      fork_elapsed=$(( $(date +%s) - FORK_TIPS_SINCE ))
      if (( fork_elapsed >= FORK_TIPS_WARN_THRESHOLD )); then
        info "Fork-like tips have been present for over ${fork_warn_minutes} minutes."
        info "If this does not resolve on its own, it is recommended to"
        info "restart the full recovery with 'n' to rebuild the chain state."
        info "The basic recovery without managed addnodes is usually enough; recovery with trusted addnodes is only needed in more complex cases."
      fi
    else
      FORK_TIPS_SINCE=""
    fi

    if (( headers_only_count > 0 )); then
      if [[ -z "${HEADERS_TIPS_SINCE}" ]]; then
        HEADERS_TIPS_SINCE="$(date +%s)"
      fi
      headers_elapsed=$(( $(date +%s) - HEADERS_TIPS_SINCE ))
      if (( headers_elapsed >= HEADERS_TIPS_WARN_THRESHOLD )); then
        info "Headers-only tips have been present for over ${headers_warn_minutes} minutes."
        info "If this does not resolve on its own, it is recommended to"
        info "restart the full recovery with 'n' to rebuild the chain state."
      fi
    else
      HEADERS_TIPS_SINCE=""
    fi
  else
    FORK_TIPS_SINCE=""
    HEADERS_TIPS_SINCE=""
  fi

  if (( best_block_age >= 0 )) && (( best_block_age > PROTX_MAX_TIP_AGE )); then
    warn "Best block age (${best_block_age}s) is older than recommended tip age (${PROTX_MAX_TIP_AGE}s)."
    hard_fail=1
  fi

  echo

  if (( hard_fail > 0 )); then
    warn "The timing for protx update_service is not ideal yet."
    echo "Please wait a little longer and run the readiness check again."
    echo
    info "If you do not want to wait any longer, you can still continue with 'x'."
    echo
    info "If the situation does not improve over time (for example fork-like tips"
    info "or headers-only tips stay present, or the local view differs from a"
    info "trusted explorer), it can be safer to run this recovery helper again with 'n'."
    info "The basic recovery without managed addnodes is usually enough; recovery with trusted addnodes is only needed in more complex cases."
    return 1
  fi

  if [[ -n "${SYNC_READY_SINCE_EPOCH}" ]] && (( ready_seconds < PROTX_MIN_READY_SECONDS )); then
    warn "The node is fully synced, but only for ${ready_seconds} seconds."
    echo "It is recommended to wait a few more minutes for a more stable timing."
    echo "You may still continue with 'x' if you want."
    return 0
  fi

  success "The timing now looks good for protx update_service."
  echo "You can continue with 'x' and the controller-wallet step."
  return 0
}

interactive_protx_readiness_menu() {
  local action

  print_line
  echo "The node is fully synced, but it can still be useful to wait a few more minutes"
  echo "until connectivity and chain state look stable before running protx update_service."
  echo
  echo "If the node was not PoSe-banned and you only performed a sync to bring it"
  echo "up to the current block height, then no protx update_service is required."
  echo "In this case you can skip the following protx step with 'x'."
  echo
  echo "Recommended way:"
  echo " - Use 'r' repeatedly to run the readiness check again"
  echo " - Wait until the result says the timing looks good"
  echo " - You can skip this step any time with 'x'"
  print_line
  echo "ProTx readiness menu"
  echo "Use the following keys:"
  echo "  r = run readiness check"
  echo "  l = show last 30 debug.log lines"
  echo "  j = show last 30 journalctl lines for the service"
  echo "  n = abort here and restart the recovery helper from the beginning"
  echo "  x = skip this step and continue"
  print_line

  while true; do
    read -r -p "Choose action [r/l/j/n/x]: " action

    case "${action}" in
      r|R)
        get_protx_readiness_snapshot
        ;;
      l|L)
        tail -n 30 "${DEFAULT_DATA_DIR}/debug.log" || warn "Could not read debug.log."
        ;;
      j|J)
        journalctl -u "${DEFAULT_SERVICE}" -n 30 --no-pager 2>/dev/null || warn "Could not read journalctl output."
        ;;
      n|N)
        if ask_yes_no "Do you really want to abort here and restart the recovery helper from the beginning?"; then
          warn "Aborting here and restarting the recovery helper from the beginning."
          echo "The script will now restart."
          exec "$0" "${ORIGINAL_ARGS[@]}"
          error "Automatic restart failed."
          exit 1
        else
          warn "Restart aborted. Staying in the ProTx readiness menu."
        fi
        ;;
      x|X)
        success "Leaving ProTx readiness menu and continuing."
        break
        ;;
      *)
        warn "Invalid selection."
        ;;
    esac

    print_line
  done
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
  prompt_reference_height

  stop_daemon_cautious || exit 1

  if ! verify_daemon_stopped; then
    error "Verified stopped state was not reached."
    warn "Aborting before cleanup to avoid corruption."
    exit 1
  fi

  remove_lock_file
  cleanup_recovery_files

  restore_service_if_needed || exit 1

  print_line
  info "Phase – Temporary early bootstrap addnode check"
  print_line
  echo "The daemon is running but not yet fully synced."
  echo "This optional step tests a random subset of trusted addnodes for"
  echo "basic reachability and sends them via 'addnode onetry' to help"
  echo "the daemon find peers — especially if seed nodes are unreachable."
  print_line

  if wait_for_rpc 60 5; then
    if [[ ! -f "${DEFAULT_ADDNODE_FILE}" ]]; then
      warn "trusted_addnodes.txt was not found. Early bootstrap addnode step skipped."
    else
      prepare_early_bootstrap_nodes
      maybe_apply_early_bootstrap_fallback
    fi
  else
    warn "RPC did not respond in time. Early bootstrap addnode step skipped."
  fi

  interactive_monitoring_menu
  interactive_protx_readiness_menu
  info "Showing final local status snapshot..."
  show_local_status
  show_protx_placeholder

}

run_recovery_plain_auto_mode() {
  info "Selected: Automatic recovery without trusted addnodes."
  print_line
  echo "This mode performs an automatic recovery WITHOUT changing addnode settings."
  echo "No helper-managed trusted addnodes will be written to defcon.conf."
  echo "No PoSe-based temporary banlist will be prepared in this mode."
  echo "The only manual input required is the reference block height."
  print_line

  show_local_status
  check_service_and_process
  backup_conf
  prompt_reference_height

  print_line
  info "Phase 1 – Stopping daemon and cleaning up local chain data (automatic)"
  print_line

  if service_unit_exists; then
    if systemctl is-enabled "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      info "Service is enabled. Disabling temporarily to prevent auto-restart..."
      if systemctl disable "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
        SERVICE_WAS_DISABLED=1
        success "Service disabled temporarily."
      else
        warn "systemctl disable did not succeed."
      fi
      sleep 2
    fi

    info "Stopping service..."
    systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl stop did not succeed."
    sleep 8
  else
    warn "Service file ${DEFAULT_SERVICE}.service not found. Skipping systemctl stop."
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    info "Trying RPC stop..."
    run_cli stop >/dev/null 2>&1 || warn "RPC stop did not succeed."
    sleep 10
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon still running after service/RPC stop. Trying normal kill..."
    pkill -f "${DEFAULT_DAEMON}" >/dev/null 2>&1 || warn "Normal kill did not succeed."
    sleep 5
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon still running after normal kill. Trying hard kill (kill -9)..."
    pkill -9 -f "${DEFAULT_DAEMON}" >/dev/null 2>&1 || warn "Hard kill did not succeed."
    sleep 3
  fi

  show_stop_summary

  if ! verify_daemon_stopped; then
    error "Safe stopped state was NOT confirmed. Aborting automatic recovery."
    exit 1
  fi
  success "Daemon fully stopped."

  local lock_file="${DEFAULT_DATA_DIR}/.lock"
  if [[ -f "${lock_file}" ]]; then
    rm -f "${lock_file}"
    success "Lock file removed."
  else
    info "No lock file found."
  fi

  print_line
  info "Performing automatic cleanup of local chain data..."
  print_line
  rm -f "${DEFAULT_DATA_DIR}/peers.dat"
  rm -f "${DEFAULT_DATA_DIR}/banlist.json" "${DEFAULT_DATA_DIR}/banlist.dat"
  rm -f "${DEFAULT_DATA_DIR}/mncache.dat"
  rm -f "${DEFAULT_DATA_DIR}/netfulfilled.dat"
  rm -rf "${DEFAULT_DATA_DIR}/llmq"
  rm -rf "${DEFAULT_DATA_DIR}/evodb"
  rm -rf "${DEFAULT_DATA_DIR}/blocks"
  rm -rf "${DEFAULT_DATA_DIR}/chainstate"
  rm -rf "${DEFAULT_DATA_DIR}/indexes"
  success "Cleanup completed."

  print_line
  info "Phase 2 – Starting daemon on clean chain (automatic)"
  print_line

  restore_service_if_needed || { error "Final service start failed."; exit 1; }
  check_service_and_process

  print_line
  info "Phase – Temporary early bootstrap addnode fallback"
  print_line
  echo "The daemon is running but not yet fully synced."
  echo "Checking whether the early bootstrap fallback is needed."
  print_line

  if wait_for_rpc 60 5; then
    if [[ -f "${DEFAULT_ADDNODE_FILE}" ]]; then
      prepare_early_bootstrap_nodes "non_interactive"
      maybe_apply_early_bootstrap_fallback
    else
      warn "trusted_addnodes.txt was not found. Early bootstrap fallback step skipped."
    fi
  else
    warn "RPC did not respond in time. Early bootstrap fallback step skipped."
  fi

  print_line
  info "Phase – Automatic sync wait loop (checking every 60 seconds)"
  print_line
  echo "Waiting for the node to fully synchronize..."
  echo "Loop ends when IsSynced=true AND AssetName=MASTERNODE_SYNC_FINISHED."
  echo "No timeout. Press Ctrl+C to abort manually if needed."
  print_line

  while true; do
    local ts block_height sync_json asset_name is_synced is_blockchain_synced

    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    block_height="$(run_cli getblockcount 2>/dev/null || echo 'unknown')"
    sync_json="$(run_cli mnsync status 2>/dev/null || echo '{}')"
    asset_name="$(echo "${sync_json}" | jq -r '.AssetName // "unknown"' 2>/dev/null)"
    is_blockchain_synced="$(echo "${sync_json}" | jq -r '.IsBlockchainSynced // "unknown"' 2>/dev/null)"
    is_synced="$(echo "${sync_json}" | jq -r '.IsSynced // "unknown"' 2>/dev/null)"

    echo "[${ts}] Height: ${block_height} | Stage: ${asset_name} | Blockchain synced: ${is_blockchain_synced} | Masternode synced: ${is_synced}"

    if [[ "${is_synced}" == "true" && "${asset_name}" == "MASTERNODE_SYNC_FINISHED" ]]; then
      success "Node is fully synced."
      SYNC_READY_SINCE_EPOCH="$(date +%s)"
      break
    fi

    sleep 60
  done

  print_line
  info "Automatic plain recovery steps completed."
  info "Handing over to interactive ProTx readiness menu."
  print_line

  interactive_protx_readiness_menu

  info "Showing final local status snapshot..."
  show_local_status
  show_protx_placeholder

}

wait_for_rpc() {
  local max_attempts="${1:-30}"
  local sleep_sec="${2:-5}"
  local attempt=0

  print_line
  info "Waiting for RPC to become available after daemon start..."

  while (( attempt < max_attempts )); do
    attempt=$(( attempt + 1 ))
    if timeout 5 "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" getblockcount >/dev/null 2>&1; then
      success "RPC is responding (attempt ${attempt}/${max_attempts})."
      return 0
    fi
    echo "  Attempt ${attempt}/${max_attempts}: RPC not yet available. Waiting ${sleep_sec}s..."
    sleep "${sleep_sec}"
  done

  error "RPC did not become available after ${max_attempts} attempts."
  return 1
}

stop_daemon_for_config_reload() {
  print_line
  info "Stopping daemon temporarily to apply the verified addnode config..."
  echo "The daemon will be restarted immediately after the config is written."
  print_line

  if service_unit_exists; then
    if systemctl is-enabled "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      info "Service is enabled. Trying systemctl disable first to prevent auto-restart..."
      if systemctl disable "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
        [ "${SERVICE_WAS_DISABLED}" -eq 0 ] && SERVICE_WAS_DISABLED=1
        success "Service disabled temporarily."
      else
        warn "systemctl disable did not succeed."
      fi
      sleep 2
    else
      info "Service is already not enabled."
    fi

    info "Trying systemctl stop..."
    systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl stop did not succeed."
    sleep 8
  else
    warn "Service file ${DEFAULT_SERVICE}.service was not found. Skipping systemctl disable/stop."
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    info "Trying RPC stop..."
    run_cli stop >/dev/null 2>&1 || warn "RPC stop did not succeed."
    sleep 10
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon is still running after service stop and RPC stop. Trying normal kill..."
    pkill -f "${DEFAULT_DAEMON}" >/dev/null 2>&1 || warn "Normal kill did not succeed."
    sleep 5
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon is still running after normal kill. Trying hard kill (kill -9)..."
    pkill -9 -f "${DEFAULT_DAEMON}" >/dev/null 2>&1 || warn "Hard kill did not succeed."
    sleep 3
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon is still running after hard kill."

    if service_unit_exists; then
      info "Trying systemctl mask to block all restarts..."
      if systemctl mask "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
        [ "${SERVICE_WAS_MASKED}" -eq 0 ] && SERVICE_WAS_MASKED=1
        success "Service masked temporarily."
      else
        warn "systemctl mask did not succeed."
      fi
      systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || true
      sleep 5
    else
      warn "Service masking is not possible because no service file was found."
    fi
  fi

  show_stop_summary

  if verify_daemon_stopped; then
    success "Daemon stopped successfully for config reload."
    return 0
  fi

  error "Safe stopped state was NOT confirmed for config reload."
  warn "Aborting before writing config to avoid data corruption."
  return 1
}

run_recovery_addnodes_mode() {
    info "Selected: Recovery with trusted addnodes."
    print_line
    echo "This mode performs a cautious recovery AND manages a helper-controlled trusted addnode list in defcon.conf."
    echo "PoSe-based bans can optionally be prepared and will be applied after cleanup and restart."
    print_line

    # ------------------------------------------------------------------
    print_line
    info "Phase 1 – Pre-stop preparation (RPC must be available)"
    print_line

    prompt_addnodes_source
    validate_addnodes
    show_addnodes
    prompt_reference_height
    show_local_status
    check_service_and_process
    backup_conf
    offer_pose_banlist_preparation

    # ------------------------------------------------------------------
    print_line
    info "Phase 1 – Temporary early bootstrap node preparation (RPC still active)"
    print_line
    echo "This step builds a temporary bootstrap node list while RPC is still available."
    echo "The list will be used as a fallback after the daemon restarts on a clean chain,"
    echo "in case normal seed node discovery fails."
    print_line

    prepare_early_bootstrap_nodes

    # ------------------------------------------------------------------
    print_line
    info "Phase 2 – Stopping daemon and cleaning up local chain data"
    print_line

    stop_daemon_cautious || { error "Daemon stop was not confirmed. Aborting."; exit 1; }

    if ! verify_daemon_stopped; then
        error "Verified stopped state was not reached."
        warn "Aborting before cleanup to avoid data corruption."
        exit 1
    fi

    remove_lock_file
    cleanup_recovery_files

    # ------------------------------------------------------------------
    print_line
    info "Phase 3 – Starting daemon on clean chain for addnode verification..."
    echo "The daemon will now start without any managed addnodes."
    echo "It must reach full sync before trusted addnode candidates can be"
    echo "verified reliably. Please monitor the sync progress and continue"
    echo "with 'x' only when the node is fully synced."
    print_line

    restore_service_if_needed || { error "Final service start failed."; exit 1; }
    check_service_and_process

    # ------------------------------------------------------------------
    print_line
    info "Phase – Temporary early bootstrap addnode fallback"
    print_line
    echo "The daemon is running but not yet fully synced."
    echo "Checking whether the early bootstrap fallback is needed"
    echo "(bootstrap file was prepared in Phase 1 while RPC was still active)."
    print_line

    if wait_for_rpc 60 5; then
      maybe_apply_early_bootstrap_fallback
    else
      warn "RPC did not respond in time. Early bootstrap fallback step skipped."
    fi

    # ------------------------------------------------------------------
    print_line
    info "Phase 4 – Waiting for full sync before addnode verification"
    print_line
    echo "The node is syncing on a clean chain. Addnode candidates can only"
    echo "be verified reliably once the node has fully synchronized."
    echo ""
    echo "Please use the sync monitoring menu below to track the sync progress."
    echo "Continue with 'x' ONLY when all of the following conditions are met:"
    echo ""
    echo "  - Local block height ≈ reference height ($REFERENCE_HEIGHT)"
    echo "  - Sync stage:          MASTERNODE_SYNC_FINISHED"
    echo "  - Blockchain synced:   true"
    echo "  - Masternode synced:   true"
    echo ""
    echo "Do NOT continue with 'x' while the sync stage is still"
    echo "MASTERNODE_SYNC_BLOCKCHAIN or any earlier stage."
    print_line

    interactive_monitoring_menu --no-intro

    # ------------------------------------------------------------------
    # Select addnode check mode, pick candidates, run verification
    prompt_addnode_check_mode
    pick_random_candidates
    check_addnode_candidates

    if [[ ${#GOOD_ADDNODES[@]} -eq 0 ]]; then
        error "No trusted addnodes passed the verification. Cannot continue."
        echo "Options:"
        echo "  - Try again later when more peers are available."
        echo "  - Check your trusted_addnodes.txt for valid entries."
        exit 1
    fi

    # ------------------------------------------------------------------
    print_line
    info "Phase 5 – Writing verified addnodes to defcon.conf and restarting"
    print_line

    write_trusted_addnodes_to_conf

    stop_daemon_for_config_reload || { error "Could not stop daemon for config reload. Aborting."; exit 1; }

    restore_service_if_needed || { error "Final service start with addnode config failed."; exit 1; }

    # ------------------------------------------------------------------
    print_line
    info "Phase 6 – Applying PoSe bans and opening sync monitoring"
    print_line

    apply_prepared_pose_bans
    interactive_monitoring_menu
    interactive_protx_readiness_menu

    info "Showing final local status snapshot..."
    show_local_status
    show_protx_placeholder

    if is_recovery_state_active; then
      schedule_auto_restore "${AUTO_RESTORE_DELAY_SECONDS}" 0
    else
      info "No temporary recovery state detected after recovery run. Automatic restore scheduling skipped."
    fi
}

run_recovery_addnodes_auto_mode() {
  info "Selected: Automatic recovery (fully automated, no confirmations)."
  print_line
  echo "This mode performs a fully automated recovery with trusted addnodes."
  echo "All steps run without user confirmations."
  echo "The only manual input required is the reference block height."
  print_line

  # ------------------------------------------------------------------
  print_line
  info "Phase 1 – Pre-stop preparation (fully automatic)"
  print_line

  check_addnode_file
  load_addnodes
  dedupe_addnodes_array
  validate_addnodes
  show_addnodes

  prompt_reference_height

  ADDNODE_CHECK_MODE="hard"
  info "Addnode check mode set automatically: hard"

  show_local_status
  check_service_and_process

  backup_conf

  print_line
  info "Collecting PoSe problem nodes for automatic banlist preparation..."
  print_line
  if collect_pose_problem_nodes; then
    if [[ "${ALL_POSE_COUNT:-0}" -gt 0 ]]; then
      show_pose_problem_nodes_preview
      save_pose_banlist_file_prepared
    else
      warn "No PoSe-based IPs found. Banlist skipped."
    fi
  else
    warn "PoSe evaluation returned no data. Banlist skipped."
  fi

  print_line
  info "Phase 1 – Temporary early bootstrap node preparation (non-interactive)"
  print_line
  echo "Building temporary bootstrap node list while RPC is still available..."
  print_line

  if ! prepare_early_bootstrap_nodes "non_interactive"; then
    error "No early bootstrap nodes were found or accepted."
    error "Cannot continue automatic recovery without bootstrap nodes."
    error "The node might start without any peers after restart."
    warn "Returning to main menu. Please check trusted_addnodes.txt and try again."
    return 0
  fi

  # ------------------------------------------------------------------
  print_line
  info "Phase 2 – Stopping daemon and cleaning up local chain data (automatic)"
  print_line

  if service_unit_exists; then
    if systemctl is-enabled "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
      info "Service is enabled. Disabling temporarily to prevent auto-restart..."
      if systemctl disable "${DEFAULT_SERVICE}" >/dev/null 2>&1; then
        SERVICE_WAS_DISABLED=1
        success "Service disabled temporarily."
      else
        warn "systemctl disable did not succeed."
      fi
      sleep 2
    fi
    info "Stopping service..."
    systemctl stop "${DEFAULT_SERVICE}" >/dev/null 2>&1 || warn "systemctl stop did not succeed."
    sleep 8
  else
    warn "Service file ${DEFAULT_SERVICE}.service not found. Skipping systemctl stop."
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    info "Trying RPC stop..."
    run_cli stop >/dev/null 2>&1 || warn "RPC stop did not succeed."
    sleep 10
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon still running after service/RPC stop. Trying normal kill..."
    pkill -f "${DEFAULT_DAEMON}" || warn "Normal kill did not succeed."
    sleep 5
  fi

  if pgrep -f "${DEFAULT_DAEMON}" >/dev/null 2>&1; then
    warn "Daemon still running after normal kill. Trying hard kill (kill -9)..."
    pkill -9 -f "${DEFAULT_DAEMON}" || warn "Hard kill did not succeed."
    sleep 3
  fi

  show_stop_summary

  if ! verify_daemon_stopped; then
    error "Safe stopped state was NOT confirmed. Aborting automatic recovery."
    exit 1
  fi
  success "Daemon fully stopped."

  local lock_file="${DEFAULT_DATA_DIR}/.lock"
  if [[ -f "${lock_file}" ]]; then
    rm -f "${lock_file}"
    success "Lock file removed."
  else
    info "No lock file found."
  fi

  print_line
  info "Performing automatic cleanup of local chain data..."
  print_line
  rm -f "${DEFAULT_DATA_DIR}/peers.dat"
  rm -f "${DEFAULT_DATA_DIR}/banlist.json" "${DEFAULT_DATA_DIR}/banlist.dat"
  rm -f "${DEFAULT_DATA_DIR}/mncache.dat"
  rm -f "${DEFAULT_DATA_DIR}/netfulfilled.dat"
  rm -rf "${DEFAULT_DATA_DIR}/llmq"
  rm -rf "${DEFAULT_DATA_DIR}/evodb"
  rm -rf "${DEFAULT_DATA_DIR}/blocks"
  rm -rf "${DEFAULT_DATA_DIR}/chainstate"
  rm -rf "${DEFAULT_DATA_DIR}/indexes"
  success "Cleanup completed."

  # ------------------------------------------------------------------
  print_line
  info "Phase 3 – Starting daemon on clean chain (automatic)"
  print_line

  restore_service_if_needed || { error "Final service start failed."; exit 1; }
  check_service_and_process

  print_line
  info "Phase – Temporary early bootstrap addnode fallback"
  print_line
  if wait_for_rpc 60 5; then
    maybe_apply_early_bootstrap_fallback
  else
    warn "RPC did not respond in time. Early bootstrap fallback step skipped."
  fi

  # ------------------------------------------------------------------
  print_line
  info "Phase – Automatic sync wait loop (checking every 60 seconds)"
  print_line
  echo "Waiting for the node to fully synchronize..."
  echo "Loop ends when IsSynced=true AND AssetName=MASTERNODE_SYNC_FINISHED."
  echo "No timeout. Press Ctrl+C to abort manually if needed."
  print_line

  while true; do
    local ts block_height sync_json asset_name is_synced is_blockchain_synced

    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    block_height="$(run_cli getblockcount 2>/dev/null || echo 'unknown')"
    sync_json="$(run_cli mnsync status 2>/dev/null || echo '{}')"
    asset_name="$(echo "${sync_json}" | jq -r '.AssetName // "unknown"' 2>/dev/null)"
    is_blockchain_synced="$(echo "${sync_json}" | jq -r '.IsBlockchainSynced // "unknown"' 2>/dev/null)"
    is_synced="$(echo "${sync_json}" | jq -r '.IsSynced // "unknown"' 2>/dev/null)"

    echo "[${ts}] Height: ${block_height} | Stage: ${asset_name} | Blockchain synced: ${is_blockchain_synced} | Masternode synced: ${is_synced}"

    if [[ "${is_synced}" == "true" && "${asset_name}" == "MASTERNODE_SYNC_FINISHED" ]]; then
      success "Node is fully synced. Proceeding with addnode verification."
      SYNC_READY_SINCE_EPOCH="$(date +%s)"
      break
    fi

    sleep 60
  done

  # ------------------------------------------------------------------
  print_line
  info "Phase 4 – Addnode verification (automatic, hard mode)"
  print_line

  pick_random_candidates
  check_addnode_candidates

  if [[ "${#GOOD_ADDNODES[@]}" -eq 0 ]]; then
    error "No trusted addnodes passed the verification."
    error "Cannot write addnode config without verified nodes."
    exit 1
  fi

  # ------------------------------------------------------------------
  print_line
  info "Phase 5 – Writing verified addnodes to defcon.conf and restarting daemon (automatic)"
  print_line
  
  dedupe_good_addnodes_array
  cp "${DEFAULT_CONF_FILE}" "${DEFAULT_CONF_FILE}.pre-managed.$(date +%Y%m%d-%H%M%S)"

  awk -v start="${MANAGED_START}" -v end="${MANAGED_END}" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "${DEFAULT_CONF_FILE}" > "${DEFAULT_CONF_FILE}.tmp"

  {
    echo
    echo "${MANAGED_START}"
    for node in "${GOOD_ADDNODES[@]}"; do
      echo "addnode=${node}"
    done
    echo "${MANAGED_END}"
  } >> "${DEFAULT_CONF_FILE}.tmp"

  mv "${DEFAULT_CONF_FILE}.tmp" "${DEFAULT_CONF_FILE}"
  success "Verified trusted addnodes written to defcon.conf."

  print_line
  info "Stopping daemon temporarily to reload config with verified addnodes..."
  print_line

  stop_daemon_for_config_reload || { error "Daemon stop for config reload failed."; exit 1; }

  print_line
  info "Restarting daemon with verified addnode config..."
  print_line

  restore_service_if_needed || { error "Daemon restart after config write failed."; exit 1; }
  check_service_and_process

  # ------------------------------------------------------------------
  print_line
  info "Phase 6 – PoSe bans + readiness check"
  print_line

  if wait_for_rpc 60 5; then
    apply_prepared_pose_bans
  else
    warn "RPC did not respond in time. PoSe ban application skipped."
  fi

  print_line
  info "Current sync state after Phase 6 restart:"
  print_line
  show_sync_progress

  print_line
  info "Automatic recovery steps completed."
  info "Handing over to interactive ProTx readiness menu."
  print_line

  interactive_protx_readiness_menu

  info "Showing final local status snapshot..."
  show_local_status
  show_protx_placeholder

  if is_recovery_state_active; then
    schedule_auto_restore "${AUTO_RESTORE_DELAY_SECONDS}" 0
  else
    info "No temporary recovery state detected after recovery run. Automatic restore scheduling skipped."
  fi
}

check_ready_for_restore() {
  local mode="${1:-interactive}"

  while true; do
    print_line
    info "Checking if masternode is ready for restore normal mode..."

    if ! timeout 5 "${DEFAULT_CLI}" -datadir="${DEFAULT_DATA_DIR}" -conf="${DEFAULT_CONF_FILE}" getblockcount >/dev/null 2>&1; then
      if [ "$mode" = "noninteractive" ]; then
        warn "Restore readiness check failed: RPC is not responding."
        return 1
      fi

      error "Restore normal mode is not recommended yet."
      echo "RPC is not responding."
      print_line
      echo "Choose how to proceed:"
      echo "1) Check status again"
      echo "2) Continue with restore normal mode anyway (not recommended)"
      echo "3) Exit without making changes"
      print_line

      local choice
      read -r -p "Enter 1, 2 or 3: " choice
      case "$choice" in
        1) continue ;;
        2)
          warn "Continuing with restore normal mode despite RPC not responding."
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
      continue
    fi

    local mn_json sync_json mn_state mn_status asset_name is_synced
    mn_json="$(run_cli masternode status 2>/dev/null || echo "")"
    sync_json="$(run_cli mnsync status 2>/dev/null || echo "")"

    mn_state="$(echo "$mn_json" | jq -r '.state // empty' 2>/dev/null)"
    mn_status="$(echo "$mn_json" | jq -r '.status // empty' 2>/dev/null)"
    asset_name="$(echo "$sync_json" | jq -r '.AssetName // empty' 2>/dev/null)"
    is_synced="$(echo "$sync_json" | jq -r '.IsSynced // empty' 2>/dev/null)"

    echo "Masternode state: ${mn_state:-unknown}"
    echo "Masternode status: ${mn_status:-unknown}"
    echo "Sync stage: ${asset_name:-unknown}"
    echo "IsSynced: ${is_synced:-unknown}"
    print_line

    if [[ "$mn_state" == "READY" ]] && is_sync_finished "$sync_json"; then
      success "Masternode appears to be READY and fully synced. Continuing with restore normal mode."
      return 0
    fi

    if [ "$mode" = "noninteractive" ]; then
      warn "Restore readiness check failed: node is not fully ready yet."
      return 1
    fi

    error "Restore normal mode is not recommended yet."
    echo "The masternode does not meet the recommended conditions for restore normal mode:"
    echo "- state should be READY"
    echo "- sync stage should be MASTERNODESYNCFINISHED"
    echo "- Blockchain synced should be true"
    echo "- IsSynced should be true"
    print_line
    echo "Choose how to proceed:"
    echo "1) Check status again"
    echo "2) Continue with restore normal mode anyway (not recommended)"
    echo "3) Exit without making changes"
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

# ---------------------------------------------------------------------------
# Auto-restore: check whether a temporary recovery state is still active
# ---------------------------------------------------------------------------
is_recovery_state_active() {
  local managed_present=1
  local pose_present=1

  if grep -Fq "${MANAGED_START}" "${DEFAULT_CONF_FILE}" 2>/dev/null; then
    managed_present=0
  fi

  if [[ -f "${POSE_BANLIST_FILE}" ]]; then
    pose_present=0
  fi

  if [[ "${managed_present}" -eq 0 || "${pose_present}" -eq 0 ]]; then
    return 0
  fi

  return 1
}

has_managed_addnode_section() {
  if grep -Fq "${MANAGED_START}" "${DEFAULT_CONF_FILE}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Auto-restore: cancel any existing scheduled job (unit + state file)
# ---------------------------------------------------------------------------
cancel_auto_restore() {
  if systemctl list-units --full --all 2>/dev/null | grep -q "${AUTO_RESTORE_UNIT}"; then
    systemctl stop "${AUTO_RESTORE_UNIT}.service" >/dev/null 2>&1 || true
    systemctl stop "${AUTO_RESTORE_UNIT}.timer" >/dev/null 2>&1 || true
  fi

  rm -f "${AUTO_RESTORE_STATE_FILE}" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Auto-restore: schedule a new one-shot job via systemd-run
# $1 = delay in seconds
# ---------------------------------------------------------------------------
schedule_auto_restore() {
  local delay_seconds="${1:-}"
  local retry_count="${2:-0}"
  local token run_at_epoch run_at_human script_path

  if ! is_number "${delay_seconds}" || (( delay_seconds <= 0 )); then
    warn "Auto-restore scheduling skipped because the delay is invalid."
    return 1
  fi

  if ! is_number "${retry_count}" || (( retry_count < 0 )); then
    retry_count=0
  fi

  mkdir -p "${DEFAULT_DATA_DIR}" >/dev/null 2>&1 || true

  cancel_auto_restore >/dev/null 2>&1 || true

  token="$(date +%s)-${RANDOM}"
  run_at_epoch=$(( $(date +%s) + delay_seconds ))
  run_at_human="$(date -d "@${run_at_epoch}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"
  script_path="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"

  {
    echo "token=${token}"
    echo "retry_count=${retry_count}"
    echo "run_at_epoch=${run_at_epoch}"
    echo "run_at_human=${run_at_human}"
    echo "script_path=${script_path}"
    echo "unit=${AUTO_RESTORE_UNIT}"
    echo "created_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  } > "${AUTO_RESTORE_STATE_FILE}"

  chmod 600 "${AUTO_RESTORE_STATE_FILE}" >/dev/null 2>&1 || true

  if command -v systemd-run >/dev/null 2>&1; then
    if systemd-run \
      --unit="${AUTO_RESTORE_UNIT}" \
      --on-active="${delay_seconds}" \
      --description="DeFCoN recovery helper auto-restore" \
      "${script_path}" --auto-restore "${token}" >/dev/null 2>&1; then
      success "Automatic restore scheduled in ${delay_seconds} seconds."
      info "Planned auto-restore time: ${run_at_human}"
      info "Auto-restore retry counter: ${retry_count}/${AUTO_RESTORE_MAX_RETRIES}"
      info "Auto-restore unit: ${AUTO_RESTORE_UNIT}"
      return 0
    else
      warn "systemd-run scheduling failed. Trying fallback with at."
    fi
  else
    warn "systemd-run is not available. Trying fallback with at."
  fi

  if command -v at >/dev/null 2>&1; then
    if printf '%q %q %q\n' "${script_path}" "--auto-restore" "${token}" \
      | at -M -t "$(date -d "@${run_at_epoch}" '+%Y%m%d%H%M.%S' 2>/dev/null)" >/dev/null 2>&1; then
      success "Automatic restore scheduled in ${delay_seconds} seconds via at."
      info "Planned auto-restore time: ${run_at_human}"
      info "Auto-restore retry counter: ${retry_count}/${AUTO_RESTORE_MAX_RETRIES}"
      info "Note: old at jobs cannot be cleaned up reliably; stale jobs are neutralized by the token check."
      return 0
    fi
  fi

  warn "Automatic restore could not be scheduled automatically."
  warn "You will need to run restore mode manually later."
  return 1
}

# ---------------------------------------------------------------------------
# Auto-restore: non-interactive restore run
# $1 = token from the state file
# ---------------------------------------------------------------------------
run_auto_restore() {
  local token="${1:-}"
  local saved_token retry_count force_restore=0

  print_line
  info "Automatic restore mode started."
  print_line

  if [ -z "$token" ]; then
    error "Automatic restore aborted because no token was provided."
    exit 1
  fi

  if [ ! -f "${AUTO_RESTORE_STATE_FILE}" ]; then
    warn "Automatic restore state file not found. Nothing to do."
    exit 0
  fi

  saved_token="$(grep -E '^token=' "${AUTO_RESTORE_STATE_FILE}" 2>/dev/null | head -n1 | cut -d= -f2-)"
  retry_count="$(grep -E '^retry_count=' "${AUTO_RESTORE_STATE_FILE}" 2>/dev/null | head -n1 | cut -d= -f2-)"

  if [ -z "$saved_token" ]; then
    warn "Automatic restore state file has no valid token. Nothing to do."
    exit 0
  fi

  if ! is_number "$retry_count"; then
    retry_count=0
  fi

  if [ "$token" != "$saved_token" ]; then
    warn "Ignoring stale automatic restore job because its token is no longer current."
    exit 0
  fi

  if ! is_recovery_state_active; then
    info "No temporary recovery state is active anymore. Auto-restore is not needed."
    rm -f "${AUTO_RESTORE_STATE_FILE}" >/dev/null 2>&1 || true
    exit 0
  fi

  if ! check_ready_for_restore noninteractive; then
    if [ "$retry_count" -lt "$AUTO_RESTORE_MAX_RETRIES" ]; then
      warn "Automatic restore is not recommended yet."
      info "Scheduling another automatic restore retry in ${AUTO_RESTORE_RETRY_SECONDS} seconds."
      schedule_auto_restore "${AUTO_RESTORE_RETRY_SECONDS}" "$((retry_count + 1))" || true
      exit 0
    fi

    warn "Automatic restore readiness check still not ideal after ${retry_count} retries."
    warn "Retry limit reached. Continuing with automatic restore anyway."
    force_restore=1
  fi

  print_line
  if [ "$force_restore" -eq 1 ]; then
    warn "Automatic restore will now continue even though the node is not in the recommended ready state."
  else
    info "Automatic restore readiness check passed."
  fi

  run_restore_mode noninteractive

  rm -f "${AUTO_RESTORE_STATE_FILE}" >/dev/null 2>&1 || true

  print_line
  success "Automatic restore completed successfully."
  print_line
  info "Showing final local status snapshot..."
  show_local_status
  exit 0
}

run_restore_mode() {
  local mode="${1:-interactive}"

  info "Selected Restore normal mode: remove helper-managed addnodes / PoSe-bans."
  print_line
  echo "This mode is intended to revert changes made by Recovery with trusted addnodes"
  echo "and to remove temporary PoSe bans created by this helper."
  echo "For the recommended path, the daemon should be running and fully synced before restore is started."
  print_line

  info "Cancelling any previously scheduled automatic restore job before starting restore mode..."
  cancel_auto_restore

  check_ready_for_restore "$mode"

  show_local_status
  check_service_and_process
  backup_conf

  if [ "$mode" = "noninteractive" ]; then
    stop_daemon_for_config_reload || {
      error "Automatic restore aborted because a safe stopped state could not be confirmed."
      exit 1
    }
  else
    stop_daemon_cautious || exit 1
  fi

  if ! verify_daemon_stopped; then
    error "Verified stopped state was not reached."
    warn "Aborting before changing the configuration."
    exit 1
  fi

  remove_lock_file "$mode"
  restore_normal_mode_conf "$mode"

  restore_service_if_needed || {
    error "Restore failed because the service could not be started again."
    exit 1
  }

  if wait_for_rpc 30 5; then
    remove_tracked_pose_bans "$mode"
  else
    warn "RPC did not become available after restart. Temporary PoSe ban removal was skipped."
  fi

  if [ -f "${EARLY_BOOTSTRAP_FILE}" ]; then
    if rm -f "${EARLY_BOOTSTRAP_FILE}" >/dev/null 2>&1; then
      success "Temporary early bootstrap file removed: ${EARLY_BOOTSTRAP_FILE}"
    else
      warn "Could not remove temporary early bootstrap file: ${EARLY_BOOTSTRAP_FILE}"
    fi
  else
    info "No temporary early bootstrap file found."
  fi

  info "Showing final local status snapshot..."
  show_local_status
}

main() {
  trap 'recovery_abort_notice' EXIT INT TERM
  
  if [[ "${1:-}" == "--auto-restore" ]]; then
    local token="${2:-}"
    check_root
    check_conf_file
    check_binaries
    run_auto_restore "${token}"
    exit 0
  fi

  show_intro
  check_root
  show_defaults
  check_conf_file
  check_binaries
  choose_mode

  case "${MODE}" in
    recovery_plain)
      ensure_daemon_running || exit 1
      run_recovery_plain_mode
      ;;
    recovery_addnodes)
      ensure_daemon_running || exit 1
      run_recovery_addnodes_mode
      ;;
    recovery_addnodes_auto)
      ensure_daemon_running || exit 1
      run_recovery_addnodes_auto_mode
      ;;
    recovery_plain_auto)
      ensure_daemon_running || exit 1
      run_recovery_plain_auto_mode
      ;;
    restore)
      run_restore_mode
      ;;
    *)
      error "Unknown mode: ${MODE:-unset}"
      exit 1
      ;;
  esac

  print_line
  echo "Recovery helper run completed."
  echo "Please continue monitoring the node carefully."

  if [[ "${MODE}" == "recovery_addnodes" ]]; then
    print_line
    echo "Note:"
    echo "Temporary recovery changes such as helper-managed trusted addnodes and temporary PoSe bans"
    echo "will be reverted automatically after $((AUTO_RESTORE_DELAY_SECONDS / 3600)) hours, if the"
    echo "temporary recovery state is still active and the node is ready for restore."
    echo "You can also run this script again earlier and select \"Restore normal mode\" to revert them manually."
  fi

  print_line
}

main "$@"


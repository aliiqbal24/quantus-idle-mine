#!/usr/bin/env bash
# Shared paths, config access, and process checks for quantus-idle-mine.
# Source this file; do not execute it.
# shellcheck disable=SC2034 # Callers of this library read the variables.

# Resolve the install or repo root (parent of lib/).
_qim_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${_qim_lib_dir}/.." && pwd)"
unset _qim_lib_dir

QUANTUS_IDLE_VERSION="$(tr -d '[:space:]' < "${APP_ROOT}/VERSION" 2>/dev/null || echo 1.0.0)"

if [[ -z "${QUANTUS_IDLE_COMMON_LOADED:-}" ]]; then
  QUANTUS_IDLE_COMMON_LOADED=1
fi

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

quantus_idle_init_paths() {
  : "${HOME:?HOME is not set}"
  : "${XDG_CONFIG_HOME:=${HOME}/.config}"
  : "${XDG_STATE_HOME:=${HOME}/.local/state}"
  : "${XDG_DATA_HOME:=${HOME}/.local/share}"

  CONFIG_DIR="${QUANTUS_IDLE_CONFIG_DIR:-${XDG_CONFIG_HOME}/quantus-idle}"
  STATE_DIR="${QUANTUS_IDLE_STATE_DIR:-${XDG_STATE_HOME}/quantus-idle}"
  DATA_DIR="${QUANTUS_IDLE_DATA_DIR:-${XDG_DATA_HOME}/quantus-idle}"

  CONFIG_FILE="${CONFIG_DIR}/config"
  DAEMON_ENV_FILE="${CONFIG_DIR}/daemon.env"
  STATE_FILE="${STATE_DIR}/state"
  LOG_FILE="${STATE_DIR}/idle-mine.log"
  DAEMON_PID_FILE="${STATE_DIR}/daemon.pid"
  LAST_INPUT_FILE="${STATE_DIR}/last_input_ms"
  ACTIVITY_SNAP_FILE="${STATE_DIR}/activity_snap.json"
  ACTIVITY_TRACKER_PID_FILE="${STATE_DIR}/activity-tracker.pid"

  RUN_DIR="${DATA_DIR}/run"
  STACK_LOG_DIR="${DATA_DIR}/logs"
  NODE_PID_FILE="${RUN_DIR}/node.pid"
  MINER_PID_FILE="${RUN_DIR}/miner.pid"
  NODE_KEY_PATH="${DATA_DIR}/node_key.p2p"
  DEFAULT_BIN_DIR="${DATA_DIR}/binaries"
  SERVICE_NAME="quantus-idle-mine.service"

  CHAIN_REPO="Quantus-Network/chain"
  MINER_REPO="Quantus-Network/quantus-miner"
  # Used only when GitHub's API does not answer. install probes --help and
  # refuses a mismatched pair. Confirm newer tags on the release pages.
  NODE_VERSION_FALLBACK="v1.0.2-Qm"
  MINER_VERSION_FALLBACK="v4.2.0"
}

quantus_idle_ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$DATA_DIR" "$RUN_DIR" "$STACK_LOG_DIR" "$DEFAULT_BIN_DIR"
  chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$DATA_DIR" "$RUN_DIR" "$STACK_LOG_DIR" "$DEFAULT_BIN_DIR" 2>/dev/null || true
}

# Print a config value with one layer of matching quotes removed.
cfg_get() {
  local key="$1" line val
  [[ -f "$CONFIG_FILE" ]] || return 0
  line="$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  val="${line#*=}"
  if [[ "$val" == \"*\" && "$val" == *\" ]]; then
    val="${val#\"}"
    val="${val%\"}"
  elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
    val="${val#\'}"
    val="${val%\'}"
  fi
  printf '%s' "$val"
}

cfg_set() {
  local key="$1" value="$2" tmp
  [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "Refusing to write unsafe config key"
  case "$value" in
    *$'\n'*|*$'\r'*) die "Refusing to write a multi-line config value for ${key}" ;;
  esac
  mkdir -p "$CONFIG_DIR"
  touch "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  tmp="$(mktemp "${CONFIG_DIR}/.config.XXXXXX")"
  if [[ -s "$CONFIG_FILE" ]] && grep -qE "^${key}=" "$CONFIG_FILE"; then
    awk -v k="$key" -v v="$value" '
      BEGIN { FS = "=" }
      $1 == k { print k "=" v; next }
      { print }
    ' "$CONFIG_FILE" >"$tmp"
  else
    if [[ -s "$CONFIG_FILE" ]]; then
      cat "$CONFIG_FILE" >"$tmp"
      printf '\n' >>"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

resolve_bin_dir() {
  local from_env="${QUANTUS_BIN_DIR:-}" from_cfg
  from_cfg="$(cfg_get QUANTUS_BIN_DIR)"
  if [[ -n "$from_env" ]]; then
    BIN_DIR="$from_env"
  elif [[ -n "$from_cfg" ]]; then
    BIN_DIR="$from_cfg"
  else
    BIN_DIR="$DEFAULT_BIN_DIR"
  fi
  NODE_BIN="${BIN_DIR}/quantus-node"
  MINER_BIN="${BIN_DIR}/quantus-miner"
}

load_mining_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Config not found at ${CONFIG_FILE}. Run ./install.sh"
  NODE_NAME="$(cfg_get NODE_NAME)"
  INNER_HASH="$(cfg_get INNER_HASH)"
  WORMHOLE_ADDRESS="$(cfg_get WORMHOLE_ADDRESS)"
  CHAIN="$(cfg_get CHAIN)"
  MINER_LISTEN_PORT="$(cfg_get MINER_LISTEN_PORT)"
  CPU_WORKERS="$(cfg_get CPU_WORKERS)"
  GPU_DEVICES="$(cfg_get GPU_DEVICES)"
  USE_CUDA="$(cfg_get USE_CUDA)"
  NODE_VERSION="$(cfg_get NODE_VERSION)"
  MINER_VERSION="$(cfg_get MINER_VERSION)"
  : "${CHAIN:=mainnet}"
  : "${MINER_LISTEN_PORT:=9833}"
  : "${CPU_WORKERS:=0}"
  : "${GPU_DEVICES:=1}"
  : "${USE_CUDA:=1}"
  [[ -n "$NODE_NAME" ]] || die "NODE_NAME is missing in ${CONFIG_FILE}"
  [[ -n "$INNER_HASH" ]] || die "INNER_HASH is missing in ${CONFIG_FILE}. Run ./install.sh"
  resolve_bin_dir
}

node_data_path() {
  if [[ -n "${QUANTUS_NODE_DATA_PATH:-}" ]]; then
    printf '%s' "$QUANTUS_NODE_DATA_PATH"
    return
  fi
  printf '%s/quantus-node' "${XDG_DATA_HOME:-${HOME}/.local/share}"
}

node_chain_dir() {
  local base expected
  base="$(node_data_path)"
  expected="${base}/chains/${CHAIN:-mainnet}"
  if [[ -d "$expected" ]]; then
    printf '%s' "$expected"
    return
  fi
  printf '%s' "$expected"
}

miner_auth_token_path() {
  printf '%s/miner-auth-token' "$(node_chain_dir)"
}

miner_tls_pin_path() {
  printf '%s/miner-tls-cert-sha256' "$(node_chain_dir)"
}

# PIDs of processes we own whose executable is exactly $1.
owned_pids_for_bin() {
  local bin="$1" d pid exe ou self
  [[ -n "$bin" && -e "$bin" ]] || return 1
  self="$(id -u)"
  for d in /proc/[0-9]*; do
    [[ -d "$d" ]] || continue
    pid="${d##*/}"
    [[ "$pid" -gt 1 ]] || continue
    ou="$(awk '/^Uid:/{print $2; exit}' "${d}/status" 2>/dev/null || true)"
    [[ "$ou" == "$self" ]] || continue
    exe="$(readlink -f "${d}/exe" 2>/dev/null || true)"
    exe="${exe% (deleted)}"
    [[ "$exe" == "$bin" ]] && printf '%s\n' "$pid"
  done
}

process_alive() {
  local pid="$1"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

read_pid_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  tr -d '[:space:]' <"$file"
}

miner_running() {
  resolve_bin_dir
  [[ -n "${MINER_BIN:-}" && -e "$MINER_BIN" ]] || return 1
  owned_pids_for_bin "$MINER_BIN" | grep -q .
}

node_running() {
  resolve_bin_dir
  [[ -n "${NODE_BIN:-}" && -e "$NODE_BIN" ]] || return 1
  owned_pids_for_bin "$NODE_BIN" | grep -q .
}

is_enabled() {
  local enabled
  enabled="$(cfg_state_enabled)"
  case "$enabled" in
    0|false|FALSE|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

cfg_state_enabled() {
  local enabled=1
  if [[ -f "$STATE_FILE" ]]; then
    enabled="$(grep -E '^enabled=' "$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
    enabled="${enabled:-1}"
  fi
  printf '%s' "$enabled"
}

write_enabled_state() {
  local value="$1"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  printf 'enabled=%s\n' "$value" >"$STATE_FILE"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

ms_human() {
  local ms="$1" s unit
  [[ "$ms" =~ ^[0-9]+$ ]] || {
    printf '%s' "$ms"
    return
  }
  s=$((ms / 1000))
  if ((s >= 3600 && s % 3600 == 0)); then
    s=$((s / 3600))
    unit="hour"
  elif ((s >= 60 && s % 60 == 0)); then
    s=$((s / 60))
    unit="minute"
  else
    unit="second"
  fi
  if ((s == 1)); then
    printf '%s %s' "$s" "$unit"
  else
    printf '%s %ss' "$s" "$unit"
  fi
}

mask_middle() {
  local value="$1" len
  len="${#value}"
  if ((len <= 12)); then
    printf '****'
  else
    printf '%s...%s' "${value:0:6}" "${value: -4}"
  fi
}

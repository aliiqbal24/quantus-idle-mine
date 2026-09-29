#!/usr/bin/env bash
# Install Quantus idle mining for an NVIDIA GPU on Linux.
# Idempotent: a second run keeps the existing wormhole identity and refreshes scripts.
set -euo pipefail
umask 077

case $- in
  *x*)
    printf 'Error: do not run install.sh under bash -x. Tracing can print a mnemonic.\n' >&2
    exit 1
    ;;
esac

if [[ "$(id -u)" -eq 0 ]]; then
  printf 'Error: run ./install.sh as your desktop user, not root.\n' >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/lib/common.sh"
quantus_idle_init_paths

NONINTERACTIVE=0
ALLOW_NO_GPU=0
SKIP_DOWNLOAD=0
SKIP_SYSTEMD=0
FORCE_DOWNLOAD=0
UNINSTALL=0
PURGE=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

Install official quantus-node and quantus-miner binaries, write
${CONFIG_DIR}/, and enable the quantus-idle-mine user service.

Options:
  --non-interactive   Do not prompt. Requires an existing config with an inner hash.
  --force-download    Re-download official binaries (respects NODE_VERSION / MINER_VERSION pins).
  --allow-no-gpu      Continue when nvidia-smi cannot see a GPU (development only).
  --skip-download     Do not contact GitHub releases.
  --skip-systemd      Install the user unit, but do not enable or start it.
  --uninstall         Stop the service and remove the user unit and idle-mine command.
  --purge             With --uninstall, also delete config, state, and ${DATA_DIR}.
  -h, --help          Show this help.

The seed phrase is requested in the terminal and is not written to disk.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NONINTERACTIVE=1 ;;
    --force-download) FORCE_DOWNLOAD=1 ;;
    --allow-no-gpu) ALLOW_NO_GPU=1 ;;
    --skip-download) SKIP_DOWNLOAD=1 ;;
    --skip-systemd) SKIP_SYSTEMD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

mnemonic=""
WALLET_PHRASE=""
WALLET_SECRET=""
cleanup_secrets() {
  mnemonic=""
  WALLET_PHRASE=""
  WALLET_SECRET=""
  unset mnemonic WALLET_PHRASE WALLET_SECRET || true
}
trap cleanup_secrets EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

paths_are_default() {
  [[ "$CONFIG_DIR" == "${HOME}/.config/quantus-idle" \
    && "$STATE_DIR" == "${HOME}/.local/state/quantus-idle" \
    && "$DATA_DIR" == "${HOME}/.local/share/quantus-idle" ]]
}

systemd_quote() {
  local value="$1"
  if [[ "$value" =~ ^[A-Za-z0-9._@/:~+-]+$ ]]; then
    printf '%s' "$value"
    return
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

install_unit() {
  local unit_dir="${XDG_CONFIG_HOME}/systemd/user" dest daemon envfile
  mkdir -p "$unit_dir"
  dest="${unit_dir}/${SERVICE_NAME}"
  if paths_are_default; then
    cp "${ROOT}/systemd/quantus-idle-mine.service" "$dest"
  else
    daemon="$(systemd_quote "${DATA_DIR}/daemon/idle-mine-daemon.sh")"
    envfile="$(systemd_quote "${DAEMON_ENV_FILE}")"
    cat >"$dest" <<EOF
[Unit]
Description=Quantus idle miner (start after keyboard and mouse are idle)
After=default.target
Wants=graphical-session.target

[Service]
Type=simple
UMask=0077
ExecStart=${daemon}
Restart=always
RestartSec=5
StartLimitIntervalSec=120
StartLimitBurst=8
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=XDG_CONFIG_HOME=$(systemd_quote "$XDG_CONFIG_HOME")
Environment=XDG_STATE_HOME=$(systemd_quote "$XDG_STATE_HOME")
Environment=XDG_DATA_HOME=$(systemd_quote "$XDG_DATA_HOME")
EnvironmentFile=-${envfile}

[Install]
WantedBy=default.target
EOF
  fi
  chmod 644 "$dest"
  info "Installed user unit ${dest}"
}

enable_service() {
  install_unit
  if [[ "$SKIP_SYSTEMD" -eq 1 ]]; then
    info "User unit is installed. Skipped enable/start (--skip-systemd)."
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is not installed. Start the unit after installing systemd."
    return
  fi
  if ! systemctl --user daemon-reload; then
    warn "Could not talk to the systemd user bus."
    warn "On a machine where your user session is running, execute:"
    warn "  systemctl --user daemon-reload"
    warn "  systemctl --user enable --now ${SERVICE_NAME}"
    return
  fi
  systemctl --user enable --now "$SERVICE_NAME"
  info "User service ${SERVICE_NAME} is enabled and started."
}

lingering_advice() {
  local linger=""
  command -v loginctl >/dev/null 2>&1 || return 0
  linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
  if [[ "$linger" != "yes" ]]; then
    cat <<EOF

The user service starts when you log in. To keep it registered across reboots
before a full desktop session exists (mining still waits for a graphical session):

  sudo loginctl enable-linger ${USER}
EOF
  fi
}

detect_nvidia() {
  local -a rows=()
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    if [[ "$ALLOW_NO_GPU" -eq 1 ]]; then
      warn "nvidia-smi not found. Continuing because --allow-no-gpu was set."
      GPU_COUNT=1
      return
    fi
    die "nvidia-smi not found. Install the NVIDIA proprietary driver, then re-run ./install.sh."
  fi
  if ! nvidia-smi >/dev/null 2>&1; then
    if [[ "$ALLOW_NO_GPU" -eq 1 ]]; then
      warn "nvidia-smi failed. Continuing because --allow-no-gpu was set."
      GPU_COUNT=1
      return
    fi
    die "nvidia-smi failed. The NVIDIA driver is missing or does not match this kernel."
  fi
  mapfile -t rows < <(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)
  if ((${#rows[@]} == 0)); then
    if [[ "$ALLOW_NO_GPU" -eq 1 ]]; then
      warn "No NVIDIA GPU listed. Continuing because --allow-no-gpu was set."
      GPU_COUNT=1
      return
    fi
    die "No NVIDIA GPU detected. This V1 mines on NVIDIA GPUs."
  fi
  GPU_COUNT="${#rows[@]}"
  info "NVIDIA GPU (${GPU_COUNT}):"
  local row
  for row in "${rows[@]}"; do
    printf '  %s\n' "$row"
  done
}

valid_token() {
  [[ "$1" =~ ^[A-Za-z0-9._:+/=-]{8,256}$ ]]
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

read_recorded_version() {
  local key="$1" file="${BIN_DIR:-${DEFAULT_BIN_DIR}}/VERSIONS" line
  [[ -f "$file" ]] || return 0
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  printf '%s' "${line#*=}"
}

write_daemon_env() {
  if [[ -f "$DAEMON_ENV_FILE" ]]; then
    return
  fi
  cat >"$DAEMON_ENV_FILE" <<'EOF'
# Optional environment overrides for the quantus-idle-mine user service.
# Idle thresholds are read from ./config on every poll.
# Uncomment a line here only when you want the service environment to win.
# IDLE_START_MS=900000
# ACTIVITY_GRACE_MS=15000
# POLL_SEC=5
EOF
  chmod 600 "$DAEMON_ENV_FILE"
}

write_fresh_config() {
  local node_version miner_version protocol
  node_version="$(read_recorded_version NODE_VERSION)"
  miner_version="$(read_recorded_version MINER_VERSION)"
  protocol="$(read_recorded_version MINER_PROTOCOL)"
  : "${GPU_DEVICES:=${GPU_COUNT:-1}}"
  cat >"$CONFIG_FILE" <<EOF
# Quantus idle-mine configuration. Mode 0600.
# The 24-word seed is not stored here. Back it up offline. See SAFE.md.

IDLE_START_MS=900000
ACTIVITY_GRACE_MS=15000
POLL_SEC=5
HEARTBEAT_SEC=60

NODE_NAME=${NODE_NAME}
WORMHOLE_ADDRESS=${WORMHOLE_ADDRESS}
INNER_HASH=${INNER_HASH}
CHAIN=mainnet
MINER_LISTEN_PORT=9833
CPU_WORKERS=0
GPU_DEVICES=${GPU_DEVICES}
USE_CUDA=1
NODE_VERSION=${node_version}
MINER_VERSION=${miner_version}
MINER_PROTOCOL=${protocol}
QUANTUS_BIN_DIR=
EOF
  chmod 600 "$CONFIG_FILE"
  if [[ -n "$WALLET_PHRASE" ]] && grep -qF "$WALLET_PHRASE" "$CONFIG_FILE"; then
    rm -f "$CONFIG_FILE"
    die "Refusing to keep a config file that contains the seed phrase."
  fi
  if [[ -n "$WALLET_SECRET" ]] && grep -qF "$WALLET_SECRET" "$CONFIG_FILE"; then
    rm -f "$CONFIG_FILE"
    die "Refusing to keep a config file that contains the wormhole secret."
  fi
}

load_wallet_json() {
  local json="$1"
  WORMHOLE_ADDRESS="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
  INNER_HASH="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["inner_hash"])')"
  WALLET_PHRASE="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("secret_phrase") or "")')"
  WALLET_SECRET="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("secret") or "")')"
  valid_token "$WORMHOLE_ADDRESS" || die "Wormhole address from quantus-node was not usable."
  valid_token "$INNER_HASH" || die "Inner hash from quantus-node was not usable."
}

prompt_node_name() {
  local default choice
  default="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo desktop)"
  default="${default//[^A-Za-z0-9._-]/-}"
  default="${default:0:64}"
  [[ -n "$default" ]] || default="desktop"
  read -r -p "Node name shown on telemetry [${default}]: " choice
  NODE_NAME="${choice:-$default}"
  valid_name "$NODE_NAME" || die "Node name must be 1-64 characters: letters, numbers, dot, underscore, hyphen."
}

prompt_wallet() {
  local choice json words
  echo
  echo "Rewards are paid to a wormhole address derived from a 24-word phrase."
  echo "The phrase is not written to this repo, to the config file, or to the logs."
  echo "  [1] Import an existing 24-word wallet mnemonic (recommended)"
  echo "  [2] Create a new phrase and wormhole address"
  read -r -p "Choice [1]: " choice
  choice="${choice:-1}"
  resolve_bin_dir
  case "$choice" in
    1)
      echo "Enter the 24-word mnemonic. Input is hidden and is not stored."
      IFS= read -r -s mnemonic || die "Could not read the mnemonic."
      echo
      words="$(printf '%s' "$mnemonic" | wc -w | tr -d '[:space:]')"
      [[ "$words" -eq 24 ]] || die "Expected 24 words, got ${words}."
      json="$(printf '%s\n' "$mnemonic" | bash "${ROOT}/scripts/quantus-stack.sh" wallet-import)" || die "Could not derive a wormhole key."
      mnemonic=""
      unset mnemonic
      load_wallet_json "$json"
      json=""
      echo "Imported wormhole address $(mask_middle "$WORMHOLE_ADDRESS"). The phrase was not saved."
      ;;
    2)
      json="$(bash "${ROOT}/scripts/quantus-stack.sh" wallet-create)" || die "Could not create a wormhole key."
      load_wallet_json "$json"
      json=""
      echo
      echo "Write this phrase on paper and keep it offline. It will not be shown again."
      echo "Do not photograph it, paste it into chat, or commit it."
      echo
      printf '%s\n' "$WALLET_PHRASE"
      if [[ -n "$WALLET_SECRET" ]]; then
        echo
        echo "Secret value (also not saved to disk):"
        printf '%s\n' "$WALLET_SECRET"
      fi
      echo
      echo "Address: ${WORMHOLE_ADDRESS}"
      read -r -p "Type 'I saved it' to continue: " choice
      [[ "$choice" == "I saved it" ]] || die "Stopped before writing config. Nothing was saved. Run ./install.sh again if you still want a wallet."
      ;;
    *)
      die "Invalid choice: ${choice}"
      ;;
  esac
}

install_files() {
  local dir
  quantus_idle_ensure_dirs
  for dir in daemon scripts lib bin; do
    mkdir -p "${DATA_DIR}/${dir}"
    cp -a "${ROOT}/${dir}/." "${DATA_DIR}/${dir}/"
  done
  cp -a "${ROOT}/VERSION" "${DATA_DIR}/VERSION"
  cp -a "${ROOT}/SAFE.md" "${DATA_DIR}/SAFE.md"
  find "${DATA_DIR}/daemon" "${DATA_DIR}/scripts" "${DATA_DIR}/bin" "${DATA_DIR}/lib" \
    -type f \( -name '*.sh' -o -name '*.py' -o -name 'idle-mine' \) -exec chmod 755 {} +
  mkdir -p "${HOME}/.local/bin"
  ln -sfn "${DATA_DIR}/bin/idle-mine" "${HOME}/.local/bin/idle-mine"
  info "Installed idle-mine to ${HOME}/.local/bin/idle-mine"
}

cmd_uninstall() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -x "${DATA_DIR}/bin/idle-mine" || -x "${ROOT}/bin/idle-mine" ]]; then
    "${ROOT}/bin/idle-mine" disable >/dev/null 2>&1 || true
  fi
  rm -f "${XDG_CONFIG_HOME}/systemd/user/${SERVICE_NAME}"
  if [[ -L "${HOME}/.local/bin/idle-mine" || -f "${HOME}/.local/bin/idle-mine" ]]; then
    rm -f "${HOME}/.local/bin/idle-mine"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR" "$DATA_DIR"
    info "Removed ${CONFIG_DIR}, ${STATE_DIR}, and ${DATA_DIR}."
  else
    info "Removed the user unit and the idle-mine command."
    info "Kept config and binaries. Re-run with --uninstall --purge to delete them."
  fi
  info "Chain data was left in place at $(node_data_path) (it can be large)."
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  cmd_uninstall
  exit 0
fi

[[ -f "${ROOT}/daemon/idle-mine-daemon.sh" ]] || die "install.sh must be run from a clone of quantus-idle-mine."
require_cmd curl
require_cmd tar
require_cmd python3
require_cmd install

info "quantus-idle-mine ${QUANTUS_IDLE_VERSION}"
info "Config directory: ${CONFIG_DIR}"
info "Data directory:   ${DATA_DIR}"

detect_nvidia
quantus_idle_ensure_dirs

download_args=(download)
if [[ "$FORCE_DOWNLOAD" -eq 1 ]]; then
  download_args+=(--force)
fi
if [[ "$SKIP_DOWNLOAD" -eq 1 ]]; then
  info "Skipped binary download (--skip-download)."
  info "Place quantus-node and quantus-miner in ${DEFAULT_BIN_DIR} or set QUANTUS_BIN_DIR."
else
  bash "${ROOT}/scripts/quantus-stack.sh" "${download_args[@]}"
fi

existing_hash=""
existing_name=""
if [[ -f "$CONFIG_FILE" ]]; then
  existing_hash="$(cfg_get INNER_HASH)"
  existing_name="$(cfg_get NODE_NAME)"
fi

if [[ -n "$existing_hash" && -n "$existing_name" ]]; then
  info "Keeping the wormhole identity already in ${CONFIG_FILE} ($(mask_middle "$(cfg_get WORMHOLE_ADDRESS)"))"
  NODE_NAME="$existing_name"
  INNER_HASH="$existing_hash"
  WORMHOLE_ADDRESS="$(cfg_get WORMHOLE_ADDRESS)"
else
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    die "No wallet config at ${CONFIG_FILE}. Run ./install.sh without --non-interactive to import or create one."
  fi
  if [[ "$SKIP_DOWNLOAD" -eq 1 ]]; then
    resolve_bin_dir
    [[ -x "$NODE_BIN" ]] || die "quantus-node is required to create a wallet. Download binaries or set QUANTUS_BIN_DIR."
  fi
  prompt_node_name
  prompt_wallet
  write_fresh_config
  info "Wrote ${CONFIG_FILE} (mode 0600). It has the inner hash, not the seed phrase."
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "Config was not written."
fi
chmod 600 "$CONFIG_FILE"

resolve_bin_dir
if [[ ! -s "$NODE_KEY_PATH" && -x "${NODE_BIN:-}" ]]; then
  info "Generating a node P2P key"
  "$NODE_BIN" key generate-node-key --file "$NODE_KEY_PATH" \
    || die "quantus-node could not write a P2P key at ${NODE_KEY_PATH}."
  chmod 600 "$NODE_KEY_PATH"
fi

write_daemon_env
install_files
enable_service

# Drop any phrase material before the status command prints logs.
cleanup_secrets

echo
if [[ ":$PATH:" != *":${HOME}/.local/bin:"* ]]; then
  echo "Add ${HOME}/.local/bin to PATH if your shell does not already include it."
  echo "Ubuntu does this from ~/.profile for login shells."
fi

export PATH="${HOME}/.local/bin:${PATH}"
echo
idle-mine status
lingering_advice

cat <<EOF

Next steps
  1. If you created a new phrase, confirm the paper backup is offline. It is not on disk.
  2. The node syncs in the background the first time the machine is idle. That can take
     a while. Until it reaches the chain tip, mined blocks are not rewarded.
  3. Watch logs:  tail -f ${STACK_LOG_DIR}/node.log
  4. Telemetry:   https://telemetry.quantus.cat/
  5. Pause:       idle-mine pause
  6. Read SAFE.md before leaving a machine mining (power, heat, seed backup).

Optional power cap (needs permission to change the GPU limit):
  nvidia-smi --query-gpu=power.max_limit,power.limit,temperature.gpu --format=csv
  sudo nvidia-smi -pl <watts>
EOF

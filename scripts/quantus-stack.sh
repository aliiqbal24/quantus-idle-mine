#!/usr/bin/env bash
# Slim start/stop glue for official quantus-node and quantus-miner binaries.
# Downloads come from Quantus Network GitHub releases. This file does not
# vendor those binaries and it never writes a seed phrase.
set -euo pipefail
umask 077

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${APP_ROOT}/lib/common.sh"
quantus_idle_init_paths

CURL=(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 -A "quantus-idle-mine/${QUANTUS_IDLE_VERSION}")

detect_platform() {
  case "$(uname -s)" in
    Linux) ;;
    *) die "quantus-idle-mine V1 supports Linux. This host is $(uname -s)." ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)
      NODE_TARGET="x86_64-unknown-linux-gnu"
      MINER_ASSET="quantus-miner-linux-x86_64"
      ;;
    *)
      die "No official quantus-miner build for $(uname -m). V1 expects Linux x86_64."
      ;;
  esac
}

with_stack_lock() {
  mkdir -p "$RUN_DIR"
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"${RUN_DIR}/stack.lock"
    flock 9
  fi
}

release_json() {
  local repo="$1" tag="${2:-}" url
  if [[ -n "$tag" ]]; then
    url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  else
    url="https://api.github.com/repos/${repo}/releases/latest"
  fi
  "${CURL[@]}" "$url"
}

parse_release() {
  local asset="$1"
  python3 -c '
import json, sys
asset = sys.argv[1]
try:
    release = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    sys.stderr.write(f"Could not parse GitHub release JSON: {exc}\n")
    raise SystemExit(1)
tag = release.get("tag_name") or ""
url = ""
digest = ""
for item in release.get("assets") or []:
    if item.get("name") == asset:
        url = item.get("browser_download_url") or ""
        digest = item.get("digest") or ""
        break
if not tag or not url:
    sys.stderr.write(f"Release JSON has no asset named {asset}\n")
    raise SystemExit(1)
sys.stdout.write(tag + "\n" + url + "\n" + digest + "\n")
' "$asset"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
  local file="$1" expected="$2" actual
  expected="${expected#sha256:}"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "Checksum for $(basename "$file") is missing or not SHA-256. Set QUANTUS_BIN_DIR to binaries you verified, or QUANTUS_SKIP_CHECKSUM=1 to bypass (not recommended)."
  actual="$(sha256_file "$file")"
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    rm -f "$file"
    die "Checksum mismatch for $(basename "$file"). Expected ${expected}, got ${actual}."
  fi
}

download_node() {
  local tag="$1" asset url sums expected tmp archive found
  asset="quantus-node-${tag}-${NODE_TARGET}.tar.gz"
  url="https://github.com/${CHAIN_REPO}/releases/download/${tag}/${asset}"
  info "Downloading ${asset}"
  tmp="$(mktemp -d)"
  archive="${tmp}/${asset}"
  "${CURL[@]}" "$url" -o "$archive" || {
    rm -rf "$tmp"
    die "Failed to download ${url}"
  }
  if [[ "${QUANTUS_SKIP_CHECKSUM:-0}" != "1" ]]; then
    sums="${tmp}/sha256sums.txt"
    "${CURL[@]}" "https://github.com/${CHAIN_REPO}/releases/download/${tag}/sha256sums-${tag}-${NODE_TARGET}.txt" -o "$sums" || {
      rm -rf "$tmp"
      die "Failed to download checksums for ${asset}. Refusing to install an unverified node."
    }
    expected="$(awk -v f="$asset" '$2==f {print $1; exit}' "$sums")"
    verify_sha256 "$archive" "$expected"
  else
    warn "QUANTUS_SKIP_CHECKSUM=1 — node archive was not verified"
  fi
  tar -xzf "$archive" -C "$tmp"
  if [[ -f "${tmp}/quantus-node" ]]; then
    found="${tmp}/quantus-node"
  else
    found="$(find "$tmp" -type f -name quantus-node -print -quit || true)"
  fi
  if [[ -z "$found" || ! -f "$found" ]]; then
    rm -rf "$tmp"
    die "quantus-node was not inside ${asset}"
  fi
  mkdir -p "$BIN_DIR"
  install -m 700 "$found" "$NODE_BIN"
  rm -rf "$tmp"
  info "Installed quantus-node to ${NODE_BIN}"
}

download_miner() {
  local tag="$1" url digest dest json
  json="$(release_json "$MINER_REPO" "$tag")" || die "Could not read the quantus-miner ${tag} release"
  local -a release_lines=()
  mapfile -t release_lines < <(printf '%s' "$json" | parse_release "$MINER_ASSET")
  url="${release_lines[1]:-}"
  digest="${release_lines[2]:-}"
  [[ -n "$url" ]] || die "Could not find ${MINER_ASSET} in the ${tag} release"
  dest="${MINER_BIN}.partial"
  mkdir -p "$BIN_DIR"
  info "Downloading ${MINER_ASSET} (${tag})"
  "${CURL[@]}" "$url" -o "$dest" || {
    rm -f "$dest"
    die "Failed to download ${url}"
  }
  if [[ "${QUANTUS_SKIP_CHECKSUM:-0}" != "1" ]]; then
    verify_sha256 "$dest" "$digest"
  else
    warn "QUANTUS_SKIP_CHECKSUM=1 — miner binary was not verified"
  fi
  mv "$dest" "$MINER_BIN"
  chmod 700 "$MINER_BIN"
  info "Installed quantus-miner to ${MINER_BIN}"
}

resolve_version_pins() {
  local env_node="${NODE_VERSION:-}" env_miner="${MINER_VERSION:-}"
  # Caller may have exported pins. Config fills the gaps after load_mining_config
  # when a config file exists. download is also used before the wallet exists,
  # so a missing config is allowed.
  if [[ -z "$env_node" && -f "$CONFIG_FILE" ]]; then
    env_node="$(cfg_get NODE_VERSION)"
  fi
  if [[ -z "$env_miner" && -f "$CONFIG_FILE" ]]; then
    env_miner="$(cfg_get MINER_VERSION)"
  fi
  PIN_NODE="$env_node"
  PIN_MINER="$env_miner"
}

fetch_latest_or_fallback() {
  local repo="$1" asset="$2" fallback="$3" json
  local -a lines=()
  if json="$(release_json "$repo")"; then
    if mapfile -t lines < <(printf '%s' "$json" | parse_release "$asset"); then
      if [[ -n "${lines[0]:-}" ]]; then
        printf '%s' "${lines[0]}"
        return 0
      fi
    fi
  fi
  warn "GitHub latest release for ${repo} was not readable. Using fallback ${fallback} (current when this V1 was packaged). Set NODE_VERSION and MINER_VERSION to override."
  printf '%s' "$fallback"
}

record_downloaded_versions() {
  local node_tag="$1" miner_tag="$2"
  [[ "$node_tag" != "installed" && "$miner_tag" != "installed" ]] || return 0
  mkdir -p "$BIN_DIR"
  cat >"${BIN_DIR}/VERSIONS" <<EOF
NODE_VERSION=${node_tag}
MINER_VERSION=${miner_tag}
MINER_PROTOCOL=${MINER_PROTOCOL:-}
EOF
  chmod 600 "${BIN_DIR}/VERSIONS"
}

classify_miner_protocol() {
  local node_help miner_help node_auth="no" miner_auth="no" node_status miner_status
  [[ -x "$NODE_BIN" ]] || die "quantus-node is not executable at ${NODE_BIN}"
  [[ -x "$MINER_BIN" ]] || die "quantus-miner is not executable at ${MINER_BIN}"
  node_help="$("$NODE_BIN" --help 2>&1)" && node_status=0 || node_status=$?
  [[ "$node_status" -eq 0 ]] || die "quantus-node --help failed (exit ${node_status}). ${node_help}"
  miner_help="$("$MINER_BIN" serve --help 2>&1)" && miner_status=0 || miner_status=$?
  [[ "$miner_status" -eq 0 ]] || die "quantus-miner serve --help failed (exit ${miner_status}). ${miner_help}"
  printf '%s' "$node_help" | grep -q -- 'miner-auth-token-file' && node_auth="yes"
  if printf '%s' "$miner_help" | grep -q -- 'auth-token-file' \
    && printf '%s' "$miner_help" | grep -q -- 'tls-cert-sha256-file'; then
    miner_auth="yes"
  fi
  MINER_HELP="$miner_help"
  if [[ "$node_auth" == "yes" && "$miner_auth" == "yes" ]]; then
    MINER_PROTOCOL="auth"
  elif [[ "$node_auth" == "no" && "$miner_auth" == "no" ]]; then
    MINER_PROTOCOL="legacy"
    warn "This node/miner pair has no miner QUIC auth. Prefer a current matching pair from the Quantus release pages."
  else
    die "Incompatible node/miner pair (node auth=${node_auth}, miner auth=${miner_auth}). Pin NODE_VERSION and MINER_VERSION to a matching pair and re-run ./install.sh --force-download. See https://github.com/${CHAIN_REPO}/releases and https://github.com/${MINER_REPO}/releases"
  fi
  info "Miner protocol: ${MINER_PROTOCOL}"
}

cmd_download() {
  local force="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force="true" ;;
      *) die "Unknown download option: $1" ;;
    esac
    shift
  done
  detect_platform
  quantus_idle_ensure_dirs
  resolve_bin_dir
  resolve_version_pins
  local node_tag miner_tag
  if [[ "$force" == "true" || ! -x "$NODE_BIN" ]]; then
    node_tag="${PIN_NODE:-}"
    if [[ -z "$node_tag" ]]; then
      node_tag="$(fetch_node_tag)"
    fi
    download_node "$node_tag"
  else
    node_tag="${PIN_NODE:-installed}"
    info "Using existing quantus-node at ${NODE_BIN}"
  fi
  if [[ "$force" == "true" || ! -x "$MINER_BIN" ]]; then
    miner_tag="${PIN_MINER:-}"
    if [[ -z "$miner_tag" ]]; then
      miner_tag="$(fetch_latest_or_fallback "$MINER_REPO" "$MINER_ASSET" "$MINER_VERSION_FALLBACK")"
    fi
    download_miner "$miner_tag"
  else
    miner_tag="${PIN_MINER:-installed}"
    info "Using existing quantus-miner at ${MINER_BIN}"
  fi
  classify_miner_protocol
  if [[ "$node_tag" == "installed" ]]; then
    node_tag="${PIN_NODE:-$(cfg_get NODE_VERSION)}"
  fi
  if [[ "$miner_tag" == "installed" ]]; then
    miner_tag="${PIN_MINER:-$(cfg_get MINER_VERSION)}"
  fi
  if [[ -n "$node_tag" && -f "$CONFIG_FILE" ]]; then
    cfg_set NODE_VERSION "$node_tag"
  fi
  if [[ -n "$miner_tag" && -f "$CONFIG_FILE" ]]; then
    cfg_set MINER_VERSION "$miner_tag"
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    cfg_set MINER_PROTOCOL "$MINER_PROTOCOL"
  fi
  if [[ -n "$node_tag" && -n "$miner_tag" ]]; then
    record_downloaded_versions "$node_tag" "$miner_tag"
  fi
}

fetch_node_tag() {
  local json tag
  if json="$(release_json "$CHAIN_REPO")"; then
    tag="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
    if [[ -n "$tag" ]]; then
      printf '%s' "$tag"
      return 0
    fi
  fi
  warn "GitHub latest release for ${CHAIN_REPO} was not readable. Using fallback ${NODE_VERSION_FALLBACK}."
  printf '%s' "$NODE_VERSION_FALLBACK"
}

ensure_node_key() {
  if [[ ! -s "$NODE_KEY_PATH" ]]; then
    info "Generating a node P2P key at ${NODE_KEY_PATH}"
    "$NODE_BIN" key generate-node-key --file "$NODE_KEY_PATH"
    chmod 600 "$NODE_KEY_PATH"
  fi
}

parse_wormhole_output() {
  printf '%s' "$1" | python3 -c '
import json, re, sys
text = sys.stdin.read()
def grab(pattern):
    match = re.search(pattern, text, re.M)
    return match.group(1).strip() if match else ""
payload = {
    "address": grab(r"^Address:\s*(\S+)\s*$"),
    "inner_hash": grab(r"^Inner\s*Hash:\s*(\S+)\s*$") or grab(r"^inner_hash:\s*(\S+)\s*$"),
    "secret_phrase": grab(r"^Secret phrase:\s*(.+)\s*$"),
    "secret": grab(r"^Secret:\s*(\S+)\s*$"),
}
if not payload["address"] or not payload["inner_hash"]:
    sys.stderr.write("Could not parse wormhole Address and Inner Hash from quantus-node output.\n")
    raise SystemExit(1)
json.dump(payload, sys.stdout)
'
}

# Read a mnemonic on stdin. Print JSON to stdout. Do not log stdin.
cmd_wallet_import() {
  detect_platform
  resolve_bin_dir
  [[ -x "$NODE_BIN" ]] || die "quantus-node is missing. Download binaries first."
  local output
  output="$( "$NODE_BIN" key quantus --scheme wormhole --words )" || die "wormhole key derivation failed"
  parse_wormhole_output "$output" || die "Could not parse wormhole key output"
}

cmd_wallet_create() {
  detect_platform
  resolve_bin_dir
  [[ -x "$NODE_BIN" ]] || die "quantus-node is missing. Download binaries first."
  local output
  output="$( "$NODE_BIN" key quantus --scheme wormhole )" || die "wormhole key generation failed"
  parse_wormhole_output "$output" || die "Could not parse wormhole key output"
}

port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lun 2>/dev/null | grep -q ":${port} " && return 0
    ss -ltn 2>/dev/null | grep -q ":${port} " && return 0
  fi
  return 1
}

wait_for_miner_server() {
  local port="$1" log_file="$2" timeout="${3:-180}" i
  info "Waiting up to ${timeout}s for the node miner port ${port}"
  for ((i = 1; i <= timeout; i++)); do
    if [[ -f "$log_file" ]] && grep -qi "miner server listening" "$log_file" 2>/dev/null; then
      return 0
    fi
    if port_listening "$port"; then
      return 0
    fi
    if [[ -f "$NODE_PID_FILE" ]]; then
      local pid
      pid="$(read_pid_file "$NODE_PID_FILE")"
      if [[ -n "$pid" ]] && ! process_alive "$pid"; then
        warn "quantus-node exited while waiting. Last log lines:"
        tail -n 20 "$log_file" >&2 || true
        return 1
      fi
    fi
    sleep 1
  done
  warn "Timed out waiting for miner port ${port}. Last log lines:"
  tail -n 20 "$log_file" >&2 || true
  return 1
}

wait_for_auth_files() {
  local timeout="${1:-60}" i token pin
  [[ "${MINER_PROTOCOL:-}" == "auth" ]] || return 0
  info "Waiting up to ${timeout}s for miner auth files"
  for ((i = 1; i <= timeout; i++)); do
    token="$(miner_auth_token_path)"
    pin="$(miner_tls_pin_path)"
    if [[ -s "$token" && -s "$pin" ]]; then
      return 0
    fi
    sleep 1
  done
  die "Timed out waiting for miner auth files under $(node_chain_dir)"
}

node_launch_args() {
  NODE_ARGS=(
    --name "$NODE_NAME"
    --validator
    --base-path "$(node_data_path)"
    --miner-listen-port "$MINER_LISTEN_PORT"
    --chain "$CHAIN"
    --node-key-file "$NODE_KEY_PATH"
    --rewards-inner-hash "$INNER_HASH"
    --max-blocks-per-request 64
    --sync full
  )
}

start_node_detached() {
  local log_file="${STACK_LOG_DIR}/node.log"
  mkdir -p "$STACK_LOG_DIR" "$RUN_DIR"
  if node_running; then
    info "quantus-node is already running"
    return 0
  fi
  ensure_node_key
  node_launch_args
  info "Starting quantus-node in the background (log: ${log_file})"
  # Do not print NODE_ARGS: it contains the rewards inner hash.
  nohup "$NODE_BIN" "${NODE_ARGS[@]}" >>"$log_file" 2>&1 &
  printf '%s\n' "$!" >"$NODE_PID_FILE"
  sleep 1
  if ! process_alive "$(read_pid_file "$NODE_PID_FILE")"; then
    warn "quantus-node exited immediately. Last log lines:"
    tail -n 20 "$log_file" >&2 || true
    return 1
  fi
}

miner_launch_args() {
  MINER_ARGS=(
    serve
    --cpu-workers "$CPU_WORKERS"
    --gpu-devices "$GPU_DEVICES"
    --node-addr "127.0.0.1:${MINER_LISTEN_PORT}"
  )
  if [[ "${GPU_DEVICES}" != "0" && "${USE_CUDA}" != "0" ]]; then
    if printf '%s' "${MINER_HELP:-}" | grep -q -- '--cuda-gpu'; then
      MINER_ARGS+=(--cuda-gpu)
    fi
  fi
  if [[ "${MINER_PROTOCOL:-}" == "auth" ]]; then
    local token pin
    token="$(miner_auth_token_path)"
    pin="$(miner_tls_pin_path)"
    [[ -s "$token" && -s "$pin" ]] || die "Miner auth files are not ready under $(node_chain_dir)"
    MINER_ARGS+=(
      --auth-token-file "$token"
      --tls-cert-sha256-file "$pin"
    )
  fi
}

start_miner_detached() {
  local log_file="${STACK_LOG_DIR}/miner.log"
  mkdir -p "$STACK_LOG_DIR" "$RUN_DIR"
  if miner_running; then
    info "quantus-miner is already running"
    return 0
  fi
  miner_launch_args
  info "Starting quantus-miner in the background (log: ${log_file})"
  nohup "$MINER_BIN" "${MINER_ARGS[@]}" >>"$log_file" 2>&1 &
  printf '%s\n' "$!" >"$MINER_PID_FILE"
  sleep 1
  if ! process_alive "$(read_pid_file "$MINER_PID_FILE")"; then
    warn "quantus-miner exited immediately. Last log lines:"
    tail -n 30 "$log_file" >&2 || true
    return 1
  fi
}

stop_pids() {
  local name="$1" bin="$2" pid_file="$3" pid
  local -a pids=()
  pid="$(read_pid_file "$pid_file")"
  if [[ -n "$pid" ]]; then
    pids+=("$pid")
  fi
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(owned_pids_for_bin "$bin" || true)
  local seen="" stopped="false" p
  for p in "${pids[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    case " $seen " in
      *" $p "*) continue ;;
    esac
    seen+=" $p"
    process_alive "$p" || continue
    info "Stopping ${name} (pid ${p})"
    kill "$p" 2>/dev/null || true
    stopped="true"
  done
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    local alive="false"
    for p in "${pids[@]}"; do
      if process_alive "$p"; then
        alive="true"
      fi
    done
    [[ "$alive" == "true" ]] || break
    sleep 1
  done
  for p in "${pids[@]}"; do
    if process_alive "$p"; then
      warn "${name} did not exit; sending SIGKILL to ${p}"
      kill -9 "$p" 2>/dev/null || true
    fi
  done
  rm -f "$pid_file"
  [[ "$stopped" == "true" ]]
}

prepare_runtime() {
  load_mining_config
  quantus_idle_ensure_dirs
  detect_platform
  [[ -x "$NODE_BIN" && -x "$MINER_BIN" ]] || die "Official binaries are missing in ${BIN_DIR}. Run ./install.sh or set QUANTUS_BIN_DIR."
  [[ -s "$NODE_KEY_PATH" ]] || die "Node key missing at ${NODE_KEY_PATH}. Run ./install.sh"
  classify_miner_protocol
}

cmd_start() {
  local detach="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--detach) detach="true" ;;
      *) die "Unknown start option: $1" ;;
    esac
    shift
  done
  [[ "$detach" == "true" ]] || die "V1 starts the stack in the background. Use: quantus-stack.sh start -d"
  with_stack_lock
  prepare_runtime
  if miner_running && node_running; then
    info "Mining stack is already running"
    return 0
  fi
  start_node_detached
  wait_for_miner_server "$MINER_LISTEN_PORT" "${STACK_LOG_DIR}/node.log" 180
  wait_for_auth_files 60
  start_miner_detached
  info "Mining stack is running. Node log: ${STACK_LOG_DIR}/node.log"
  info "The first sync can take a while. Blocks before the chain tip are not rewarded."
  info "Telemetry: https://telemetry.quantus.cat/ (search for ${NODE_NAME})"
}

cmd_start_miner() {
  local detach="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--detach) detach="true" ;;
      *) die "Unknown start-miner option: $1" ;;
    esac
    shift
  done
  [[ "$detach" == "true" ]] || die "Use: quantus-stack.sh start-miner -d"
  with_stack_lock
  prepare_runtime
  if ! node_running && ! port_listening "$MINER_LISTEN_PORT"; then
    die "quantus-node is not running. Start the stack with mine-on.sh or quantus-stack.sh start -d"
  fi
  if ! port_listening "$MINER_LISTEN_PORT"; then
    wait_for_miner_server "$MINER_LISTEN_PORT" "${STACK_LOG_DIR}/node.log" 60 || die "Node miner port ${MINER_LISTEN_PORT} is not open"
  fi
  wait_for_auth_files 30
  start_miner_detached
}

cmd_stop_miner() {
  with_stack_lock
  resolve_bin_dir
  if [[ ! -e "${MINER_BIN:-}" ]]; then
    info "No quantus-miner binary at ${MINER_BIN}; nothing to stop"
    rm -f "$MINER_PID_FILE"
    return 0
  fi
  if stop_pids "quantus-miner" "$MINER_BIN" "$MINER_PID_FILE"; then
    info "Miner stopped. Node left running."
  else
    info "Miner was not running."
  fi
}

cmd_stop() {
  with_stack_lock
  resolve_bin_dir
  local stopped="false"
  if [[ -e "${MINER_BIN:-}" ]] && stop_pids "quantus-miner" "$MINER_BIN" "$MINER_PID_FILE"; then
    stopped="true"
  else
    rm -f "$MINER_PID_FILE"
  fi
  if [[ -e "${NODE_BIN:-}" ]] && stop_pids "quantus-node" "$NODE_BIN" "$NODE_PID_FILE"; then
    stopped="true"
  else
    rm -f "$NODE_PID_FILE"
  fi
  if [[ "$stopped" == "true" ]]; then
    info "Mining stack stopped."
  else
    info "No quantus-node or quantus-miner process was running."
  fi
}

cmd_status() {
  resolve_bin_dir
  if [[ -f "$CONFIG_FILE" ]]; then
    load_mining_config || true
  fi
  local miner_bit=0 node_bit=0
  if miner_running; then miner_bit=1; fi
  if node_running; then node_bit=1; fi
  echo "binaries: ${BIN_DIR}"
  echo "node:     ${node_bit}  (${NODE_BIN})"
  echo "miner:    ${miner_bit}  (${MINER_BIN})"
  echo "logs:     ${STACK_LOG_DIR}"
  if [[ -n "${WORMHOLE_ADDRESS:-}" ]]; then
    echo "rewards:  $(mask_middle "$WORMHOLE_ADDRESS")"
  fi
}

cmd_help() {
  cat <<EOF
quantus-stack.sh — download and run official Quantus binaries.

  download [--force]     Install quantus-node and quantus-miner into ${DEFAULT_BIN_DIR}
  start -d               Start node and miner in the background
  start-miner -d         Start only the miner (node must already be up)
  stop-miner             Stop only the miner
  stop                   Stop miner and node
  wallet-create          Print wormhole JSON (includes a new secret phrase)
  wallet-import          Read a mnemonic on stdin and print wormhole JSON
  status                 Show whether the official binaries are running
  help

Environment:
  QUANTUS_BIN_DIR        Directory that already holds quantus-node and quantus-miner
  NODE_VERSION           Pin a chain release tag (for example ${NODE_VERSION_FALLBACK})
  MINER_VERSION          Pin a miner release tag (for example ${MINER_VERSION_FALLBACK})
  QUANTUS_NODE_DATA_PATH Override the node --base-path
  QUANTUS_SKIP_CHECKSUM  Set to 1 to skip SHA-256 checks (not recommended)

Release pages:
  https://github.com/${CHAIN_REPO}/releases
  https://github.com/${MINER_REPO}/releases
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    download) cmd_download "$@" ;;
    start) cmd_start "$@" ;;
    start-miner) cmd_start_miner "$@" ;;
    stop-miner) cmd_stop_miner "$@" ;;
    stop) cmd_stop "$@" ;;
    wallet-create) cmd_wallet_create "$@" ;;
    wallet-import) cmd_wallet_import "$@" ;;
    status) cmd_status "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "Unknown command: ${cmd}. Run: quantus-stack.sh help" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

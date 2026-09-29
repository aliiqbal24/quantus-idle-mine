#!/usr/bin/env bash
# Quantus idle-mine daemon.
# After IDLE_START_MS with no keyboard or mouse input, start mining.
# On input, wait ACTIVITY_GRACE_MS, then stop the miner and leave the node up.
# enabled=0 stops auto-start and, on the transition, stops miner and node.
set -euo pipefail
umask 077

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${APP_ROOT}/lib/common.sh"
quantus_idle_init_paths
# shellcheck source=../lib/idle.sh
source "${APP_ROOT}/lib/idle.sh"

HEARTBEAT_SEC="${HEARTBEAT_SEC:-60}"
IDLE_START_FROM_ENV=""
GRACE_FROM_ENV=""
POLL_FROM_ENV=""

# Preserve explicit environment overrides. Unset means "use config".
if [[ -n "${IDLE_START_MS+x}" ]]; then
  IDLE_START_FROM_ENV="$IDLE_START_MS"
fi
if [[ -n "${ACTIVITY_GRACE_MS+x}" ]]; then
  GRACE_FROM_ENV="$ACTIVITY_GRACE_MS"
fi
if [[ -n "${POLL_SEC+x}" ]]; then
  POLL_FROM_ENV="$POLL_SEC"
fi

refresh_settings() {
  local value
  if [[ -n "$IDLE_START_FROM_ENV" ]]; then
    IDLE_START_MS="$IDLE_START_FROM_ENV"
  else
    value="$(cfg_get IDLE_START_MS)"
    IDLE_START_MS="${value:-900000}"
  fi
  if [[ -n "$GRACE_FROM_ENV" ]]; then
    ACTIVITY_GRACE_MS="$GRACE_FROM_ENV"
  else
    value="$(cfg_get ACTIVITY_GRACE_MS)"
    ACTIVITY_GRACE_MS="${value:-15000}"
  fi
  if [[ -n "$POLL_FROM_ENV" ]]; then
    POLL_SEC="$POLL_FROM_ENV"
  else
    value="$(cfg_get POLL_SEC)"
    POLL_SEC="${value:-5}"
  fi
  value="$(cfg_get HEARTBEAT_SEC)"
  HEARTBEAT_SEC="${value:-${HEARTBEAT_SEC:-60}}"
  [[ "$IDLE_START_MS" =~ ^[0-9]+$ ]] || IDLE_START_MS=900000
  [[ "$ACTIVITY_GRACE_MS" =~ ^[0-9]+$ ]] || ACTIVITY_GRACE_MS=15000
  [[ "$POLL_SEC" =~ ^[0-9]+$ ]] || POLL_SEC=5
  [[ "$HEARTBEAT_SEC" =~ ^[0-9]+$ ]] || HEARTBEAT_SEC=60
  if ((POLL_SEC < 1)); then
    POLL_SEC=1
  fi
}

log() {
  mkdir -p "$STATE_DIR"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >>"$LOG_FILE"
}

stack() {
  "${APP_ROOT}/scripts/quantus-stack.sh" "$@"
}

stop_activity_tracker() {
  local pid
  if [[ -f "$ACTIVITY_TRACKER_PID_FILE" ]]; then
    pid="$(tr -d '[:space:]' <"$ACTIVITY_TRACKER_PID_FILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$ACTIVITY_TRACKER_PID_FILE"
  fi
}

start_activity_tracker() {
  local pid
  if [[ -f "$ACTIVITY_TRACKER_PID_FILE" ]]; then
    pid="$(tr -d '[:space:]' <"$ACTIVITY_TRACKER_PID_FILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  if ! python3 "${APP_ROOT}/daemon/activity_tracker.py" --check >/dev/null 2>&1; then
    return 0
  fi
  python3 "${APP_ROOT}/daemon/activity_tracker.py" "$LAST_INPUT_FILE" &
  echo $! >"$ACTIVITY_TRACKER_PID_FILE"
  log "input tracker started pid=$(cat "$ACTIVITY_TRACKER_PID_FILE") (/dev/input EV_KEY and EV_REL)"
}

stop_miner_only() {
  log "ACTION stop-miner-only (keep node warm)"
  if [[ -x "${APP_ROOT}/scripts/quantus-stack.sh" ]]; then
    stack stop-miner >>"$LOG_FILE" 2>&1 || true
  fi
  if miner_running; then
    log "WARN miner still running after stop-miner"
  else
    if node_running; then
      log "OK miner stopped; node=up"
    else
      log "OK miner stopped; node=down"
    fi
  fi
}

stop_full() {
  log "ACTION stop-full (miner and node)"
  if [[ -x "${APP_ROOT}/scripts/mine-off.sh" ]]; then
    "${APP_ROOT}/scripts/mine-off.sh" >>"$LOG_FILE" 2>&1 || true
  else
    stack stop >>"$LOG_FILE" 2>&1 || true
  fi
}

start_mining() {
  log "ACTION start mining"
  if miner_running; then
    log "SKIP already mining"
    return 0
  fi
  if node_running; then
    log "Node warm — starting miner only"
    if stack start-miner -d >>"$LOG_FILE" 2>&1; then
      sleep 2
      if miner_running; then
        log "OK miner started (node was warm)"
        return 0
      fi
    fi
    log "WARN start-miner did not bring the miner up; falling back to full start"
  fi
  if [[ -x "${APP_ROOT}/scripts/mine-on.sh" ]]; then
    "${APP_ROOT}/scripts/mine-on.sh" >>"$LOG_FILE" 2>&1 || true
  else
    stack start -d >>"$LOG_FILE" 2>&1 || true
  fi
  sleep 2
  if miner_running; then
    log "OK mining started"
  else
    log "WARN start finished but miner was not detected yet"
  fi
}

already_running() {
  local old ou
  [[ -f "$DAEMON_PID_FILE" ]] || return 1
  old="$(tr -d '[:space:]' <"$DAEMON_PID_FILE" 2>/dev/null || true)"
  [[ "$old" =~ ^[0-9]+$ ]] || return 1
  [[ "$old" != "$$" ]] || return 1
  kill -0 "$old" 2>/dev/null || return 1
  ou="$(awk '/^Uid:/{print $2; exit}' "/proc/${old}/status" 2>/dev/null || true)"
  [[ "$ou" == "$(id -u)" ]] || return 1
  tr '\0' ' ' <"/proc/${old}/cmdline" 2>/dev/null | grep -q 'idle-mine-daemon.sh'
}

quantus_idle_ensure_dirs
if already_running; then
  log "refusing to start; another daemon is already running"
  exit 1
fi
printf '%s\n' "$$" >"$DAEMON_PID_FILE"

cleanup() {
  stop_activity_tracker
  rm -f "$DAEMON_PID_FILE"
}
trap cleanup EXIT

refresh_settings
log "daemon start pid=$$ version=${QUANTUS_IDLE_VERSION} idle_start_ms=${IDLE_START_MS} grace_ms=${ACTIVITY_GRACE_MS} poll=${POLL_SEC}s"
import_session_env
start_activity_tracker
if python3 "${APP_ROOT}/daemon/activity_tracker.py" --check >/dev/null 2>&1; then
  log "activity sources: Hyprland cursor (8px deadzone), /dev/input, xprintidle, loginctl, hyprctl idle"
else
  log "activity sources: Hyprland cursor (8px deadzone), xprintidle, loginctl, hyprctl idle; /dev/input not readable (optional: sudo usermod -aG input ${USER})"
fi

PREV_ENABLED=1
if is_enabled; then
  PREV_ENABLED=1
else
  PREV_ENABLED=0
fi
LAST_HB=0
NO_SESSION_LOGGED=0
NO_IDLE_LOGGED=0

while true; do
  refresh_settings
  import_session_env
  start_activity_tracker

  if ! is_enabled; then
    if [[ "$PREV_ENABLED" -eq 1 ]]; then
      log "STATE disabled — stopping miner and node"
      if miner_running || node_running; then
        stop_full
      fi
    fi
    PREV_ENABLED=0
    now_s="$(date +%s)"
    if ((now_s - LAST_HB >= HEARTBEAT_SEC)); then
      if miner_running; then miner_bit=1; else miner_bit=0; fi
      if node_running; then node_bit=1; else node_bit=0; fi
      log "HEARTBEAT enabled=0 miner=${miner_bit} node=${node_bit}"
      LAST_HB=$now_s
    fi
    sleep "$POLL_SEC"
    continue
  fi
  PREV_ENABLED=1

  if ! have_graphical_session; then
    if [[ "$NO_SESSION_LOGGED" -eq 0 ]]; then
      log "WAIT no graphical session — not auto-starting"
      NO_SESSION_LOGGED=1
    fi
    sleep "$POLL_SEC"
    continue
  fi
  NO_SESSION_LOGGED=0

  idle_ms=""
  if idle_ms="$(get_idle_ms)"; then
    NO_IDLE_LOGGED=0
  else
    idle_ms=""
    if [[ "$NO_IDLE_LOGGED" -eq 0 ]]; then
      log "WAIT idle time unknown — not auto-starting (need Hyprland, xprintidle, loginctl IdleHint, or read access to /dev/input)"
      NO_IDLE_LOGGED=1
    fi
  fi

  now_s="$(date +%s)"
  if ((now_s - LAST_HB >= HEARTBEAT_SEC)); then
    if miner_running; then miner_bit=1; else miner_bit=0; fi
    if node_running; then node_bit=1; else node_bit=0; fi
    log "HEARTBEAT enabled=1 idle_ms=${idle_ms:-na} miner=${miner_bit} node=${node_bit}"
    LAST_HB=$now_s
  fi

  if [[ -z "$idle_ms" ]]; then
    sleep "$POLL_SEC"
    continue
  fi

  if ((idle_ms >= IDLE_START_MS)); then
    if ! miner_running; then
      log "DECISION idle ${idle_ms}ms >= ${IDLE_START_MS}ms → start mining"
      start_mining || true
    fi
  elif ((idle_ms < ACTIVITY_GRACE_MS)); then
    if miner_running; then
      log "DECISION activity idle=${idle_ms}ms < grace=${ACTIVITY_GRACE_MS}ms → stop miner only"
      stop_miner_only || true
    fi
  fi

  sleep "$POLL_SEC"
done

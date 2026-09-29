#!/usr/bin/env bash
# Idle detection for the daemon and the idle-mine status command.
# Requires quantus_idle_init_paths from lib/common.sh.

import_session_env() {
  local pid="" kv runtime_dir
  pid="$(pgrep -u "$USER" -x Hyprland 2>/dev/null | head -n 1 || true)"
  [[ -z "$pid" ]] && pid="$(pgrep -u "$USER" -x hyprland 2>/dev/null | head -n 1 || true)"
  [[ -z "$pid" ]] && pid="$(pgrep -u "$USER" -x sway 2>/dev/null | head -n 1 || true)"
  if [[ -n "$pid" && -r "/proc/${pid}/environ" ]]; then
    while IFS= read -r -d '' kv; do
      case "$kv" in
        DISPLAY=*|WAYLAND_DISPLAY=*|XDG_RUNTIME_DIR=*|HYPRLAND_INSTANCE_SIGNATURE=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_SESSION_ID=*|XDG_CURRENT_DESKTOP=*|PATH=*)
          # kv is already KEY=value from the process environment block.
          # shellcheck disable=SC2163
          export "${kv?}" 2>/dev/null || true
          ;;
      esac
    done <"/proc/${pid}/environ"
  fi
  if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$(id -u)" ]]; then
    runtime_dir="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR="$runtime_dir"
  fi
}

have_graphical_session() {
  pgrep -u "$USER" -x Hyprland >/dev/null 2>&1 && return 0
  pgrep -u "$USER" -x hyprland >/dev/null 2>&1 && return 0
  pgrep -u "$USER" -x sway >/dev/null 2>&1 && return 0
  pgrep -u "$USER" -x gnome-shell >/dev/null 2>&1 && return 0
  pgrep -u "$USER" -x plasmashell >/dev/null 2>&1 && return 0
  pgrep -u "$USER" -x xfce4-session >/dev/null 2>&1 && return 0
  [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]] && return 0
  if loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3==u' | grep -qiE 'wayland|x11|graphical|seat'; then
    return 0
  fi
  return 1
}

idle_from_last_input() {
  local last now
  [[ -f "$LAST_INPUT_FILE" ]] || return 1
  last="$(tr -d '[:space:]' <"$LAST_INPUT_FILE" 2>/dev/null || true)"
  now="$(python3 -c 'import time; print(int(time.time()*1000))')"
  [[ "$last" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$now" -ge "$last" ]] || return 1
  printf '%s\n' $((now - last))
}

# hyprctl idle is consulted only when the cursor tracker is unavailable.
# On Hyprland it has been observed to be missing or stuck, which pinned
# idle at 0 and prevented mining. Cursor movement is the Hyprland signal.
hypr_idle_ms() {
  local json ms
  command -v hyprctl >/dev/null 2>&1 || return 1
  json="$(hyprctl -j idle 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1
  ms="$(
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for key in ("lastInput", "idleTime", "idle_ms", "time"):
    if key in data:
        print(int(data[key]))
        raise SystemExit(0)
raise SystemExit(1)
' 2>/dev/null || true
  )"
  [[ "$ms" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$ms"
}

loginctl_idle_ms() {
  local sid hint since now_us
  command -v loginctl >/dev/null 2>&1 || return 1
  sid="${XDG_SESSION_ID:-}"
  if [[ -z "$sid" ]]; then
    sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3==u {print $1; exit}')"
  fi
  [[ -n "$sid" ]] || return 1
  hint="$(loginctl show-session "$sid" -p IdleHint --value 2>/dev/null || true)"
  if [[ "$hint" == "yes" ]]; then
    since="$(loginctl show-session "$sid" -p IdleSinceHintMonotonic --value 2>/dev/null || true)"
    [[ "$since" =~ ^[0-9]+$ && "$since" -gt 0 ]] || return 1
    now_us="$(python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC)*1_000_000))' 2>/dev/null || echo 0)"
    [[ "$now_us" =~ ^[0-9]+$ && "$now_us" -gt "$since" ]] || return 1
    printf '%s\n' $(((now_us - since) / 1000))
    return 0
  fi
  if [[ "$hint" == "no" ]]; then
    printf '0\n'
    return 0
  fi
  return 1
}

xprintidle_ms() {
  local ms
  command -v xprintidle >/dev/null 2>&1 || return 1
  ms="$(DISPLAY="${DISPLAY:-:0}" xprintidle 2>/dev/null || true)"
  [[ "$ms" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$ms"
}

input_tracker_running() {
  local pid
  [[ -f "$ACTIVITY_TRACKER_PID_FILE" ]] || return 1
  pid="$(tr -d '[:space:]' <"$ACTIVITY_TRACKER_PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# Print idle milliseconds. Returns 1 when no source is available.
# Local trackers (Hyprland cursor, /dev/input) share last_input_ms.
# xprintidle and a positive loginctl IdleHint are extra sources.
# A stuck loginctl IdleHint=no is ignored while a local tracker is healthy,
# because some compositors never flip IdleHint.
get_idle_ms() {
  local cursor_state="unavailable" local_idle="" sample="" logind=""
  local use_local=0
  local -a candidates=()

  if [[ -n "${APP_ROOT:-}" && -f "${APP_ROOT}/lib/poll_cursor.py" ]]; then
    cursor_state="$(python3 "${APP_ROOT}/lib/poll_cursor.py" "$ACTIVITY_SNAP_FILE" "$LAST_INPUT_FILE" 2>/dev/null || echo unavailable)"
  fi

  if [[ "$cursor_state" == "ok" ]] || input_tracker_running; then
    use_local=1
    local_idle="$(idle_from_last_input || true)"
    if [[ "$local_idle" =~ ^[0-9]+$ ]]; then
      candidates+=("$local_idle")
    fi
  fi

  if ((use_local == 0)); then
    sample="$(hypr_idle_ms || true)"
    if [[ "$sample" =~ ^[0-9]+$ ]]; then
      candidates+=("$sample")
    fi
  fi

  sample="$(xprintidle_ms || true)"
  if [[ "$sample" =~ ^[0-9]+$ ]]; then
    candidates+=("$sample")
  fi

  logind="$(loginctl_idle_ms || true)"
  if [[ "$logind" =~ ^[0-9]+$ ]]; then
    if ((use_local == 1)); then
      if ((logind > 0)); then
        candidates+=("$logind")
      fi
    else
      candidates+=("$logind")
    fi
  fi

  if ((${#candidates[@]} == 0)); then
    return 1
  fi

  local min="${candidates[0]}" c
  for c in "${candidates[@]}"; do
    if ((c < min)); then
      min=$c
    fi
  done

  if [[ "${IDLE_DEBUG:-0}" == "1" ]]; then
    printf 'idle-debug local=%s cursor=%s candidates=%s chosen=%s\n' \
      "$use_local" "$cursor_state" "${candidates[*]}" "$min" >&2
  fi
  printf '%s\n' "$min"
}

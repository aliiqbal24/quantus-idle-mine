#!/usr/bin/env bash
# Fake-home install and idle-clock checks. No GPU, no download, no seed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

echo "== forbidden strings =="
if grep -R -n -E '/home/ali|QTCMine|SEED_BACKUP' \
  --exclude-dir=uploads --exclude-dir=.git --exclude-dir=tests \
  --exclude=smoke.sh .; then
  fail "found a personal path or seed backup marker"
fi

echo "== syntax =="
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find . -name '*.sh' -o -name 'idle-mine' -o -name 'install.sh' | grep -v '^\./uploads/' | grep -v '/.git/')

echo "== python =="
python3 -m py_compile lib/poll_cursor.py daemon/activity_tracker.py

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning -x install.sh bin/idle-mine daemon/idle-mine-daemon.sh \
    scripts/quantus-stack.sh scripts/mine-on.sh scripts/mine-off.sh \
    lib/common.sh lib/idle.sh
else
  echo "shellcheck not installed, skipped"
fi

echo "== unit file has no personal home =="
grep -q '%h/.local/share/quantus-idle/daemon/idle-mine-daemon.sh' systemd/quantus-idle-mine.service
grep -q 'EnvironmentFile=-%h/.config/quantus-idle/daemon.env' systemd/quantus-idle-mine.service
if grep -q '/home/' systemd/quantus-idle-mine.service; then
  fail "unit file contains a /home path"
fi

echo "== wormhole parser =="
# shellcheck source=../scripts/quantus-stack.sh
source "${ROOT}/scripts/quantus-stack.sh"
# quantus-stack.sh enables pipefail. grep -q in this harness closes the pipe early.
set +o pipefail
sample=$'Address: abcdefghijklmnop\nInner Hash: 0123456789abcdef0123456789abcdef\nSecret phrase: alpha beta gamma delta\nSecret: deadbeef\n'
json="$(parse_wormhole_output "$sample")"
python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert data["address"] == "abcdefghijklmnop"
assert data["inner_hash"].startswith("0123456789abcdef")
assert data["secret_phrase"] == "alpha beta gamma delta"
' "$json"

echo "== fake home install =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="${tmp}/home"
mkdir -p "$HOME"
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME QUANTUS_BIN_DIR || true
unset IDLE_START_MS ACTIVITY_GRACE_MS || true
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
quantus_idle_init_paths
quantus_idle_ensure_dirs
cat >"$CONFIG_FILE" <<'EOF'
IDLE_START_MS=1000
ACTIVITY_GRACE_MS=15000
POLL_SEC=1
HEARTBEAT_SEC=60
NODE_NAME=smoke-desktop
WORMHOLE_ADDRESS=abcdefghijklmnopqrst
INNER_HASH=0123456789abcdef0123456789abcdef
CHAIN=mainnet
MINER_LISTEN_PORT=9833
CPU_WORKERS=0
GPU_DEVICES=1
USE_CUDA=1
NODE_VERSION=
MINER_VERSION=
QUANTUS_BIN_DIR=
EOF
chmod 600 "$CONFIG_FILE"
if grep -q 'alpha beta gamma' "$CONFIG_FILE"; then
  fail "sample phrase leaked into config"
fi

bash "${ROOT}/install.sh" --non-interactive --allow-no-gpu --skip-download --skip-systemd </dev/null
[[ -L "${HOME}/.local/bin/idle-mine" ]] || fail "idle-mine symlink missing"
[[ -f "${HOME}/.config/systemd/user/quantus-idle-mine.service" ]] || fail "unit was not installed"
if grep -q '/home/ali' "${HOME}/.config/systemd/user/quantus-idle-mine.service"; then
  fail "installed unit contains /home/ali"
fi
grep -q '%h/.local/share/quantus-idle/daemon/idle-mine-daemon.sh' \
  "${HOME}/.config/systemd/user/quantus-idle-mine.service"

export PATH="${HOME}/.local/bin:${PATH}"
idle-mine status | grep -q 'smoke-desktop\|enabled:'
idle-mine status | grep -q 'enabled:'
idle-mine enable | grep -q 'Idle mining enabled'
grep -q '^enabled=1$' "${HOME}/.local/state/quantus-idle/state"
idle-mine pause | grep -q 'disabled'
grep -q '^enabled=0$' "${HOME}/.local/state/quantus-idle/state"
idle-mine resume >/dev/null
idle-mine disable >/dev/null
idle-mine help | grep -q 'enable'

echo "== process stop =="
resolve_bin_dir
mkdir -p "$BIN_DIR"
cp "$(command -v sleep)" "${BIN_DIR}/quantus-miner"
cp "$(command -v sleep)" "${BIN_DIR}/quantus-node"
chmod 700 "${BIN_DIR}/quantus-miner" "${BIN_DIR}/quantus-node"
"${BIN_DIR}/quantus-miner" 60 &
miner_pid=$!
"${BIN_DIR}/quantus-node" 60 &
node_pid=$!
sleep 0.2
idle-mine status | grep -q 'miner:       1'
idle-mine status | grep -q 'node:        1'
idle-mine disable >/dev/null
sleep 0.3
if kill -0 "$miner_pid" 2>/dev/null; then
  fail "miner process survived disable"
fi
if kill -0 "$node_pid" 2>/dev/null; then
  fail "node process survived disable"
fi

echo "== idle clock via xprintidle =="
fakebin="${tmp}/fakebin"
mkdir -p "$fakebin"
cat >"${fakebin}/xprintidle" <<'EOF'
#!/usr/bin/env bash
printf '45000\n'
EOF
cat >"${fakebin}/loginctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"${fakebin}/hyprctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${fakebin}/xprintidle" "${fakebin}/loginctl" "${fakebin}/hyprctl"
export PATH="${fakebin}:${PATH}"
export DISPLAY="${DISPLAY:-:99}"
# shellcheck source=../lib/idle.sh
source "${ROOT}/lib/idle.sh"
idle="$(get_idle_ms)"
[[ "$idle" == "45000" ]] || fail "expected xprintidle 45000, got ${idle}"

echo "== cursor tracker does not require hyprctl =="
state="$(python3 "${ROOT}/lib/poll_cursor.py" "${tmp}/snap.json" "${tmp}/last_ms" || true)"
[[ "$state" == "unavailable" || "$state" == "ok" ]] || fail "unexpected cursor state ${state}"

echo "== activity tracker check is safe without devices =="
python3 "${ROOT}/daemon/activity_tracker.py" --check >/dev/null 2>&1 || true

echo "== daemon reaches a start decision =="
write_enabled_state 1
export PATH="${HOME}/.local/bin:${fakebin}:${PATH}"
# Short threshold is already in the fake config. Do not export IDLE_START_MS.
daemon="${HOME}/.local/share/quantus-idle/daemon/idle-mine-daemon.sh"
if command -v timeout >/dev/null 2>&1; then
  timeout 8s "$daemon" >/dev/null 2>&1 || true
else
  "$daemon" &
  dpid=$!
  sleep 4
  kill "$dpid" 2>/dev/null || true
  wait "$dpid" 2>/dev/null || true
fi
if ! grep -q 'DECISION idle' "${HOME}/.local/state/quantus-idle/idle-mine.log"; then
  echo "----- daemon log -----" >&2
  cat "${HOME}/.local/state/quantus-idle/idle-mine.log" >&2 || true
  fail "daemon did not decide to start"
fi

echo "== second install keeps identity =="
rm -f "${BIN_DIR}/quantus-node" "${BIN_DIR}/quantus-miner"
bash "${ROOT}/install.sh" --non-interactive --allow-no-gpu --skip-download --skip-systemd </dev/null
grep -q 'INNER_HASH=0123456789abcdef0123456789abcdef' "$CONFIG_FILE"
mode="$(stat -c '%a' "$CONFIG_FILE")"
[[ "$mode" == "600" ]] || fail "config mode is ${mode}, expected 600"

echo "smoke ok"

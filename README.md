# Quantus idle miner

Linux V1 for NVIDIA GPUs. After you step away, it mines Quantus. When you come back, it stops the miner and leaves the GPU to you.

The node can stay running in the background so the next idle stretch does not start cold. `idle-mine pause` stops the miner and the node. Details and the seed-backup rules are in [SAFE.md](SAFE.md).

This is experimental cryptocurrency mining. It uses electricity, produces heat, and can wear a GPU. It may conflict with workplace rules, a laptop warranty, or a host's terms of service. You are responsible for power cost, cooling, backups, and whether you are allowed to run it. There is no warranty. See [LICENSE](LICENSE).

Windows is not part of this V1.

## Requirements

- Linux x86_64
- An NVIDIA GPU with the proprietary driver (`nvidia-smi` works)
- `bash`, `curl`, `tar`, `python3`, and systemd (user services)
- A graphical session (Hyprland, another Wayland compositor, or X11)
- A 24-word Quantus wallet phrase, or the willingness to create one during install and write it down offline

Idle detection is best on Hyprland (cursor tracking). On X11, install `xprintidle`. On other desktops, either `loginctl` IdleHint or read access to `/dev/input` (`sudo usermod -aG input "$USER"`, then log in again) lets the daemon see the keyboard.

## One install command

From a clone of this repository:

```bash
git clone https://github.com/aliiqbal24/quantus-idle-mine.git quantus-idle-mine && cd quantus-idle-mine && bash install.sh
```

That is the one install command.

The script is idempotent. Run it again after you pull updates; an existing wormhole identity in `~/.config/quantus-idle/config` is kept.

What it does:

1. Checks that `nvidia-smi` can see an NVIDIA GPU.
2. Downloads official `quantus-node` and `quantus-miner` binaries from [Quantus chain releases](https://github.com/Quantus-Network/chain/releases) and [quantus-miner releases](https://github.com/Quantus-Network/quantus-miner/releases), and checks published SHA-256 sums.
3. Writes `~/.config/quantus-idle/config` (mode `0600`) with the idle threshold, grace period, and reward identity. The seed phrase is not stored.
4. Asks you to import a 24-word mnemonic (hidden input) or create a new one. A new phrase is printed once. Back it up offline before you continue. See [SAFE.md](SAFE.md).
5. Installs a systemd **user** unit, enables it, and starts it. If lingering is off, it prints the `loginctl enable-linger` command. Mining still waits for a graphical session.
6. Runs `idle-mine status` and prints next steps.

If `~/.local/bin` is not on `PATH`, open a new login shell or add it. Ubuntu's default `~/.profile` already does this when the directory exists.

### Reading the installer before you run it

Prefer the clone command above, then read `install.sh` in the clone you have.

Do not pipe an unread script into a shell. A downloaded `install.sh` on its own is also incomplete: the daemon, CLI, and unit file live in the repository. If you still fetch the script with curl, treat that as an audit step, not as the install:

```bash
# Audit only. Read the file. Then clone the repository and run THAT install.sh.
curl -fsSL https://raw.githubusercontent.com/aliiqbal24/quantus-idle-mine/main/install.sh -o /tmp/quantus-idle-install.sh
less /tmp/quantus-idle-install.sh
```

## How idle works

The user service runs `daemon/idle-mine-daemon.sh`.

| Idle time | What happens |
| --- | --- |
| Under 15 seconds | If the miner is running, it stops. The node stays up. |
| Between 15 seconds and 15 minutes | No change. This gap avoids flapping. |
| 15 minutes or more | The miner starts. If the node is already up, only the miner is started. |

Defaults are `IDLE_START_MS=900000` and `ACTIVITY_GRACE_MS=15000`. Edit `~/.config/quantus-idle/config`. The daemon re-reads the file every poll (about every 5 seconds). A value exported in the service environment overrides the file; optional commented keys live in `~/.config/quantus-idle/daemon.env`.

While `enabled=0`, the daemon does not auto-start. Turning idle mining off stops the miner and the node.

The miner will not start if the daemon cannot see a graphical session, or if it cannot measure idle time.

## Commands

```bash
idle-mine status     # enabled flag, idle time, miner, node, GPU, log tail
idle-mine enable     # arm auto-start (also: idle-mine resume)
idle-mine disable    # stop miner and node (also: idle-mine pause)
```

`scripts/mine-on.sh` and `scripts/mine-off.sh` start and stop the stack directly. You rarely need them; the daemon calls them.

Manual stack control, from a clone or from `~/.local/share/quantus-idle`:

```bash
scripts/quantus-stack.sh start -d
scripts/quantus-stack.sh stop-miner    # GPU free, node stays warm
scripts/quantus-stack.sh stop
scripts/quantus-stack.sh status
```

## What gets installed

| Path | Role |
| --- | --- |
| `~/.config/quantus-idle/config` | Thresholds, node name, wormhole address, inner hash, version pins. Mode `0600`. |
| `~/.config/quantus-idle/daemon.env` | Optional environment overrides. |
| `~/.local/state/quantus-idle/` | Enabled flag, daemon log, idle clock. |
| `~/.local/share/quantus-idle/` | CLI, daemon, official binaries, node P2P key, runtime logs. |
| `~/.local/share/quantus-node/` | Chain data created by `quantus-node`. This grows. Uninstall does not delete it. |
| `~/.config/systemd/user/quantus-idle-mine.service` | User service. The copy in `systemd/` uses `%h`, not a personal home path. |
| `~/.local/bin/idle-mine` | CLI symlink. |

Logs:

```bash
tail -f ~/.local/state/quantus-idle/idle-mine.log
tail -f ~/.local/share/quantus-idle/logs/node.log
tail -f ~/.local/share/quantus-idle/logs/miner.log
```

Telemetry: <https://telemetry.quantus.cat/> (search for the node name you chose).

Reward accounting is a wormhole address, not a normal transparent account. The Quantus wallet uses the same 24-word phrase. Background: [Quantus mining guide](https://github.com/Quantus-Network/docs/blob/main/docs/guides/mining.md).

## Versions and `QUANTUS_BIN_DIR`

GitHub publishes node and miner releases independently. The installer downloads the latest tag of each, records the tags in the config, and refuses to start a pair whose `--help` output disagrees about miner authentication.

When this V1 was packaged, a known-good fallback (used only if the GitHub API does not answer) was:

- `quantus-node` `v1.0.2-Qm` — asset `quantus-node-<tag>-x86_64-unknown-linux-gnu.tar.gz`
- `quantus-miner` `v4.2.0` — asset `quantus-miner-linux-x86_64`

Pin a pair before install or before `./install.sh --force-download`:

```bash
export NODE_VERSION=v1.0.2-Qm
export MINER_VERSION=v4.2.0
./install.sh --force-download
```

To skip the download and use binaries you already verified:

```bash
export QUANTUS_BIN_DIR="$HOME/quantus-binaries"   # quantus-node and quantus-miner inside
./install.sh --skip-download
```

There is no official `quantus-miner` build for Linux ARM64. This V1 does not try to mine there.

## Power and heat

Sustained mining warms the card. A power cap is optional and is not applied for you:

```bash
nvidia-smi --query-gpu=power.max_limit,power.limit,temperature.gpu --format=csv
sudo nvidia-smi -pl <watts>
```

Read [SAFE.md](SAFE.md) before you leave the machine.

## Uninstall

```bash
./install.sh --uninstall
```

That disables the user service and removes the `idle-mine` command. Config, binaries, and chain data stay so you do not accidentally throw away a reward identity.

```bash
./install.sh --uninstall --purge
```

That also deletes `~/.config/quantus-idle`, `~/.local/state/quantus-idle`, and `~/.local/share/quantus-idle` (including the node P2P key and downloaded binaries). Chain data under `~/.local/share/quantus-node` is left on disk; delete that directory yourself if you want the space back. Purge does not delete a seed phrase, because the installer never stored one. Your offline backup is the only copy.

## Development

```bash
tests/smoke.sh
```

The smoke test uses a temporary `HOME`, skips the GPU check and the download, and exercises `idle-mine` plus the idle clock. It does not mine.

## Layout

```
install.sh
bin/idle-mine
daemon/idle-mine-daemon.sh
daemon/activity_tracker.py
lib/
scripts/mine-on.sh
scripts/mine-off.sh
scripts/quantus-stack.sh
systemd/quantus-idle-mine.service
SAFE.md
```

# Safety

Quantus idle mining uses a real wallet, a real GPU, and real electricity. Read this before you leave a machine running.

## Seed phrase

Mining rewards are paid to a wormhole address derived from a 24-word phrase.

- `./install.sh` asks for that phrase in the terminal with input hidden, or creates a new one and prints it once.
- The phrase is **not** written to the git repo, to `~/.config/quantus-idle/config`, or to the idle-mine log.
- The config file stores the wormhole **address** and the **inner hash** the node needs (`--rewards-inner-hash`). Mode is `0600`. The inner hash is still sensitive: back up the phrase, and do not publish the config file.
- The node process command line includes the inner hash. Anyone who can list your processes can read it. That is how `quantus-node` accepts the value. Do not mine on a shared account.
- Write a new phrase on paper (or another offline backup) before you continue past the install prompt. A screenshot, a cloud note, or a shell transcript is not a backup.
- Do not run `bash -x ./install.sh`. Tracing prints the phrase. The installer refuses `-x`.
- Loss of the phrase means loss of the rewards it controls. This project cannot recover it.
- Never commit `mining.conf`, `node_key.p2p`, `~/.config/quantus-idle/`, seed backups, or wormhole secrets. `.gitignore` is not a substitute for not creating those files inside the clone.

`idle-mine pause` and `idle-mine disable` stop the miner and the node. They do not delete the phrase, because the phrase was never stored.

## What stays running when you come back

After the grace period (default 15 seconds) the **miner** stops, so the GPU is released.

The **node** stays up on purpose so the next idle period does not start from a cold sync. It still uses some CPU, disk, and network. `idle-mine pause` (same as `disable`) stops both.

## GPU heat and power

Idle mining is still a sustained GPU load. A laptop on a bed or a dusty desktop can throttle or shut down.

See the card's limits:

```bash
nvidia-smi --query-gpu=name,temperature.gpu,power.draw,power.limit,power.max_limit --format=csv
```

Cap power below the card's maximum (the exact wattage depends on the card; a common starting point is well under `power.max_limit`):

```bash
sudo nvidia-smi -pl <watts>
```

`nvidia-smi` without `-pl` is enough to watch temperature while you tune. This installer does not change the power limit for you.

The miner is asked to use the native CUDA engine (`--cuda-gpu`) when the official binary supports it. CPU workers default to 0 so the desktop stays usable. Change `GPU_DEVICES` or `CPU_WORKERS` in `~/.config/quantus-idle/config` if you want a different split.

## NVIDIA driver

`nvidia-smi` must succeed before install. The proprietary NVIDIA driver is required. Nouveau is not supported. If `nvidia-smi` fails after a kernel update, boot the matching driver and re-run `./install.sh`.

## Idle detection

Mining does not start until a graphical session has been idle (default 15 minutes). Sources, in combination:

- Hyprland cursor position (`hyprctl cursorpos`), with an 8 pixel deadzone so compositor jitter does not count
- `/dev/input` key and relative mouse events, when those devices are readable (`sudo usermod -aG input "$USER"`, then log in again)
- `xprintidle` on X11 (`sudo apt install xprintidle` or the equivalent package)
- `loginctl` `IdleHint` when the desktop actually sets it
- `hyprctl idle`, only when the cursor tracker is not available (on Hyprland that command has been a poor signal)

If none of those sources work, the daemon waits and does not start the miner.

## Network

Keep the miner port (default `9833/UDP`) off the public internet. The node writes `miner-auth-token` under the chain data directory; treat that file like a password. Peer traffic for the node uses the usual Substrate port. Do not open RPC (`9944`) to the world.

## Official binaries

`install.sh` downloads `quantus-node` and `quantus-miner` from Quantus Network GitHub releases and checks SHA-256 sums when GitHub publishes them. To use binaries you downloaded yourself:

```bash
export QUANTUS_BIN_DIR=/path/to/dir   # contains quantus-node and quantus-miner
./install.sh --skip-download
```

`QUANTUS_SKIP_CHECKSUM=1` disables verification. Do not use it unless you have another reason to trust the files.

## Git

Do not commit:

- a seed phrase, a wormhole secret, or an inner hash from a wallet you use
- `node_key.p2p`, miner auth tokens, or TLS private keys
- personal home-directory paths as defaults
- logs from a machine that has mined

The example config in `config/config.example` has empty identity fields on purpose.

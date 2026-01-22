# Cosmos Off-chain Upgrade Watcher

Simple, deterministic upgrade watcher for Cosmos-SDK chains **without `x/upgrade`**.

This tool:
- Watches block height via local RPC
- Stops the node at a target height
- Switches the binary
- Restarts the service

No Cosmovisor. No governance module. No magic.

---

## Requirements

- Linux with `systemd`
- `curl`
- `jq`
- Local RPC enabled (default: `127.0.0.1:26657`)

---

## Installation

```bash
sudo cp upgrade-watcher.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/upgrade-watcher.sh

sudo cp upgrade-watcher.service /etc/systemd/system/
sudo cp examples/lumen.env /etc/upgrade-watcher.env

sudo systemctl daemon-reload
```

---

## Configuration

Edit the environment file:

```bash
sudo nano /etc/upgrade-watcher.env
```

Set at minimum:

```bash
UPGRADE_HEIGHT=800000
BIN_NEW=/usr/local/bin/lumend-1.4.0
```

Recommended hardening:

- Ensure `/etc/upgrade-watcher.env` is root-owned and not writable by others:
  - `sudo chown root:root /etc/upgrade-watcher.env`
  - `sudo chmod 600 /etc/upgrade-watcher.env`
- Ensure `BIN_NEW` is root-owned and not writable by group/others:
  - `sudo chown root:root "$BIN_NEW"`
  - `sudo chmod 755 "$BIN_NEW"`
- Optionally pin the binary hash:
  - `BIN_NEW_SHA256=$(sha256sum "$BIN_NEW" | awk '{print $1}')`

Optional parameters:

```bash
SERVICE_NAME=lumend
BIN_ACTIVE=/usr/local/bin/lumend
RPC=http://127.0.0.1:26657
CHECK_INTERVAL=1 # fallback when RPC fails

# Dynamic interval (defaults shown, adjustable)
DYNAMIC_INTERVAL_THRESHOLD=100  # blocks
DYNAMIC_INTERVAL_FAR=30         # seconds
DYNAMIC_INTERVAL_NEAR=1         # seconds
```
>**Note**: Dynamic interval is enabled by default. The watcher checks every 30s when >100 blocks away, switching to 1s when ≤100 blocks remain. When RPC queries fail, `CHECK_INTERVAL` is used as fallback since block distance cannot be calculated.

---

## Usage

Prepare the new binary **before** the upgrade height.

Start the watcher:

```bash
sudo systemctl start upgrade-watcher
```

The watcher will:
- Wait silently until the target height is reached
- Trigger exactly once
- Stop the node
- Switch the binary
- Restart the node
- Exit

Safety behavior:
- If the watcher ever observes a height **greater than** `UPGRADE_HEIGHT`, it will **exit non-zero** and do nothing.

---

## Logs

```bash
journalctl -u upgrade-watcher -f
```

---

## Important Notes

- **All validators must upgrade at the same height**
- This is functionally equivalent to `x/upgrade` + Cosmovisor, but coordinated off-chain
- Do **NOT** run multiple watchers on the same node
- Recommended for small to medium validator sets with human coordination

---

## License

MIT

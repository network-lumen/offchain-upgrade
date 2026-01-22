# Cosmos Off-chain Upgrade Watcher

Simple, deterministic upgrade watcher for Cosmos-SDK chains **without `x/upgrade`**.

This tool:
- Watches block height via local RPC
- Stops the node at a target height
- Switches the binary
- Restarts the service

No Cosmovisor. No governance module. No magic.

---

## Version Selection

This project provides two versions of the upgrade watcher script:

### Basic Version (`upgrade-watcher.sh`)
- **Simple and lightweight** - minimal code, easy to understand and maintain
- **Essential features only** - core functionality without extra complexity
- **Perfect for beginners** - straightforward implementation
- **Recommended for**: Simple setups, operators who prefer minimal code

**Features:**
- Block height monitoring
- Dynamic interval checking
- Basic security validations
- SHA256 verification support
- Atomic binary replacement

### Verbose/Advanced Version (`upgrade-watcher.verbose.sh`)
- **Enhanced reliability** - retry mechanism for RPC calls
- **Detailed logging** - timestamped logs with INFO/ERROR/WARN levels
- **Automatic backup** - backs up old binary before replacement
- **Better error handling** - comprehensive validation and failure tracking
- **Recommended for**: Production environments, operators who need detailed monitoring

**Additional features over basic version:**
- RPC retry mechanism (configurable retry count and delay)
- Automatic binary backup to `/var/backups/upgrade-watcher/`
- Detailed logging with timestamps and log levels
- RPC failure tracking and warnings
- Enhanced service status verification
- More comprehensive error messages

### Which Version Should I Use?

- **Choose Basic** if you:
  - Prefer simple, minimal code
  - Don't need detailed logging
  - Want to understand every line of code
  - Have a stable RPC connection

- **Choose Verbose** if you:
  - Run in production environments
  - Need detailed logs for troubleshooting
  - Want automatic backup of old binaries
  - Have unreliable network/RPC connections
  - Need better observability

Both versions use the same configuration file and are fully compatible. You can switch between them by simply changing the `ExecStart` path in the systemd service file.

---

## Requirements

- Linux with `systemd`
- `curl`
- `jq`
- Local RPC enabled (default: `127.0.0.1:26657`)

---

## Installation

### Basic Version

```bash
sudo cp upgrade-watcher.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/upgrade-watcher.sh

sudo cp upgrade-watcher.service /etc/systemd/system/
sudo cp examples/lumen.env /etc/upgrade-watcher.env

sudo systemctl daemon-reload
```

### Verbose/Advanced Version

```bash
sudo cp upgrade-watcher.verbose.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/upgrade-watcher.verbose.sh

sudo cp upgrade-watcher.service /etc/systemd/system/
# Edit the service file to use verbose version:
sudo sed -i 's|upgrade-watcher.sh|upgrade-watcher.verbose.sh|g' /etc/systemd/system/upgrade-watcher.service

sudo cp examples/lumen.env /etc/upgrade-watcher.env

sudo systemctl daemon-reload
```

**Note**: The systemd service file defaults to the basic version. To use the verbose version, edit `/etc/systemd/system/upgrade-watcher.service` and change the `ExecStart` line to point to `upgrade-watcher.verbose.sh`.

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

Optional parameters (both versions):

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

Additional parameters (verbose version only):

```bash
# RPC retry configuration
RPC_RETRY_MAX=3        # Maximum retry attempts for RPC calls (default: 3)
RPC_RETRY_DELAY=2      # Delay between retries in seconds (default: 2)

# Backup configuration
BACKUP_DIR=/var/backups/upgrade-watcher  # Backup directory (default: /var/backups/upgrade-watcher)
BACKUP_ENABLED=true     # Enable/disable automatic backup (default: true)
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

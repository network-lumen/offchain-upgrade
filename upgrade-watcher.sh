#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

### CONFIG (override via env or .env file)
UPGRADE_HEIGHT="${UPGRADE_HEIGHT:?missing UPGRADE_HEIGHT}"
RPC="${RPC:-http://127.0.0.1:26657}"
SERVICE_NAME="${SERVICE_NAME:-lumend}"
BIN_NEW="${BIN_NEW:?missing BIN_NEW}"
BIN_ACTIVE="${BIN_ACTIVE:-/usr/local/bin/lumend}"
CHECK_INTERVAL="${CHECK_INTERVAL:-1}"
DYNAMIC_INTERVAL_THRESHOLD="${DYNAMIC_INTERVAL_THRESHOLD:-100}"
DYNAMIC_INTERVAL_FAR="${DYNAMIC_INTERVAL_FAR:-30}"
DYNAMIC_INTERVAL_NEAR="${DYNAMIC_INTERVAL_NEAR:-1}"

LOCK_DIR="${LOCK_DIR:-/run/upgrade-watcher}"
LOCKFILE="$LOCK_DIR/upgrade-watcher.lock"
ENV_FILE="${ENV_FILE:-}"

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[upgrade] missing dependency: $bin" >&2
    exit 1
  fi
}

for bin in curl jq flock systemctl install stat; do
  require_bin "$bin"
done

if ! [[ "$UPGRADE_HEIGHT" =~ ^[0-9]+$ ]]; then
  echo "[upgrade] invalid UPGRADE_HEIGHT: $UPGRADE_HEIGHT (expected uint)" >&2
  exit 1
fi

if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  owner=$(stat -c '%u' "$ENV_FILE")
  mode=$(stat -c '%a' "$ENV_FILE")
  mode=${mode: -3}
  g=${mode:1:1}
  o=${mode:2:1}
  if [ "$owner" != "0" ] || (( (g & 2) != 0 || (o & 2) != 0 )); then
    echo "[upgrade] refusing to run: env file must be root-owned and not group/other-writable ($ENV_FILE)" >&2
    exit 1
  fi
fi

if [ ! -f "$BIN_NEW" ] || [ -L "$BIN_NEW" ]; then
  echo "[upgrade] BIN_NEW must be a regular file (not a symlink): $BIN_NEW" >&2
  exit 1
fi
if [ -n "${BIN_NEW_SHA256:-}" ]; then
  require_bin sha256sum
  actual=$(sha256sum "$BIN_NEW" | awk '{print $1}')
  if [ "$actual" != "$BIN_NEW_SHA256" ]; then
    echo "[upgrade] BIN_NEW sha256 mismatch (expected $BIN_NEW_SHA256, got $actual)" >&2
    exit 1
  fi
fi
owner=$(stat -c '%u' "$BIN_NEW")
mode=$(stat -c '%a' "$BIN_NEW")
mode=${mode: -3}
g=${mode:1:1}
o=${mode:2:1}
if [ "$owner" != "0" ] || (( (g & 2) != 0 || (o & 2) != 0 )); then
  echo "[upgrade] refusing BIN_NEW: must be root-owned and not group/other-writable ($BIN_NEW)" >&2
  exit 1
fi

if [ -e "$BIN_ACTIVE" ] && [ -L "$BIN_ACTIVE" ]; then
  echo "[upgrade] BIN_ACTIVE must not be a symlink: $BIN_ACTIVE" >&2
  exit 1
fi

if [ -L "$LOCK_DIR" ]; then
  echo "[upgrade] refusing to use symlinked LOCK_DIR: $LOCK_DIR" >&2
  exit 1
fi
mkdir -p "$LOCK_DIR"
chmod 0700 "$LOCK_DIR"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[upgrade] another watcher already running, exiting"
  exit 0
fi

echo "[upgrade] watching height == $UPGRADE_HEIGHT (will fail if surpassed)"

while true; do
  HEIGHT=$(
    curl --connect-timeout 1 --max-time 2 -sSf "$RPC/status" 2>/dev/null \
      | jq -r '.result.sync_info.latest_block_height // empty' 2>/dev/null || true
  )
  if [[ "$HEIGHT" =~ ^[0-9]+$ ]]; then
    if [ "$HEIGHT" -gt "$UPGRADE_HEIGHT" ]; then
      echo "[upgrade] error: current height $HEIGHT already surpassed target $UPGRADE_HEIGHT; refusing to run" >&2
      exit 1
    fi
    if [ "$HEIGHT" -eq "$UPGRADE_HEIGHT" ]; then
      echo "[upgrade] reached height $HEIGHT"
      break
    fi
    
    # Dynamic interval logic
    BLOCKS_REMAINING=$((UPGRADE_HEIGHT - HEIGHT))
    if [ "$BLOCKS_REMAINING" -gt "$DYNAMIC_INTERVAL_THRESHOLD" ]; then
      CURRENT_INTERVAL=$DYNAMIC_INTERVAL_FAR
    else
      CURRENT_INTERVAL=$DYNAMIC_INTERVAL_NEAR
    fi
    
    echo "[upgrade] height: $HEIGHT, remaining: $BLOCKS_REMAINING blocks, interval: ${CURRENT_INTERVAL}s"
    sleep "$CURRENT_INTERVAL"
  else
    # if RPC failed, use CHECK_INTERVAL as fallback
    sleep "$CHECK_INTERVAL"
  fi
done

echo "[upgrade] stopping service $SERVICE_NAME"
systemctl stop "$SERVICE_NAME"
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "[upgrade] failed to stop service $SERVICE_NAME" >&2
  exit 1
fi

echo "[upgrade] switching binary"
ACTIVE_DIR=$(dirname "$BIN_ACTIVE")
TMP="$ACTIVE_DIR/.upgrade-watcher.$SERVICE_NAME.$$"
install -m 0755 "$BIN_NEW" "$TMP"
mv -f "$TMP" "$BIN_ACTIVE"

echo "[upgrade] starting service $SERVICE_NAME"
systemctl start "$SERVICE_NAME"
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "[upgrade] service failed to start: $SERVICE_NAME" >&2
  exit 1
fi

echo "[upgrade] upgrade complete"
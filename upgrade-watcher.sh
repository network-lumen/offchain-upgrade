#!/usr/bin/env bash
# Cosmos Off-chain Upgrade Watcher
# Monitors block height and automatically upgrades binary at target height
# 
# Security: Requires root ownership, validates file permissions, supports SHA256 verification
# Reliability: Retry mechanism for RPC calls, backup of old binary, atomic operations

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Internal Field Separator for safer word splitting
umask 077          # Restrict default file permissions (owner read/write only)

### CONFIGURATION (override via env or .env file)
UPGRADE_HEIGHT="${UPGRADE_HEIGHT:?missing UPGRADE_HEIGHT}"
RPC="${RPC:-http://127.0.0.1:26657}"
SERVICE_NAME="${SERVICE_NAME:-lumend}"
BIN_NEW="${BIN_NEW:?missing BIN_NEW}"
BIN_ACTIVE="${BIN_ACTIVE:-/usr/local/bin/lumend}"
CHECK_INTERVAL="${CHECK_INTERVAL:-1}"
DYNAMIC_INTERVAL_THRESHOLD="${DYNAMIC_INTERVAL_THRESHOLD:-100}"
DYNAMIC_INTERVAL_FAR="${DYNAMIC_INTERVAL_FAR:-30}"
DYNAMIC_INTERVAL_NEAR="${DYNAMIC_INTERVAL_NEAR:-1}"

# RPC retry configuration
RPC_RETRY_MAX="${RPC_RETRY_MAX:-3}"           # Maximum retry attempts for RPC calls
RPC_RETRY_DELAY="${RPC_RETRY_DELAY:-2}"       # Delay between retries (seconds)

# Backup configuration
BACKUP_DIR="${BACKUP_DIR:-/var/backups/upgrade-watcher}"
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"      # Enable/disable binary backup

LOCK_DIR="${LOCK_DIR:-/run/upgrade-watcher}"
LOCKFILE="$LOCK_DIR/upgrade-watcher.lock"
ENV_FILE="${ENV_FILE:-}"

# Logging helper function with timestamp
log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [upgrade] [$level] $message" >&2
}

log_info() { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }
log_warn() { log "WARN" "$@"; }

# Check if required binary exists in PATH
require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    log_error "missing dependency: $bin"
    exit 1
  fi
}

# Validate that a file is owned by root and not writable by group/others
validate_file_permissions() {
  local file="$1"
  local file_type="$2"
  
  if [ ! -e "$file" ]; then
    return 0  # File doesn't exist, skip validation
  fi
  
  local owner mode mode_last3 g o
  owner=$(stat -c '%u' "$file")
  mode=$(stat -c '%a' "$file")
  mode_last3=${mode: -3}  # Last 3 digits (permissions for owner/group/other)
  g=${mode_last3:1:1}     # Group write bit
  o=${mode_last3:2:1}     # Other write bit
  
  if [ "$owner" != "0" ] || (( (g & 2) != 0 || (o & 2) != 0 )); then
    log_error "$file_type must be root-owned and not group/other-writable: $file"
    exit 1
  fi
}

# Get current block height from RPC with retry mechanism
get_block_height() {
  local height=""
  local attempt=1
  
  while [ $attempt -le "$RPC_RETRY_MAX" ]; do
    height=$(
      curl --connect-timeout 1 --max-time 2 -sSf "$RPC/status" 2>/dev/null \
        | jq -r '.result.sync_info.latest_block_height // empty' 2>/dev/null || true
    )
    
    if [[ "$height" =~ ^[0-9]+$ ]] && [ "$height" -gt 0 ]; then
      echo "$height"
      return 0
    fi
    
    if [ $attempt -lt "$RPC_RETRY_MAX" ]; then
      log_warn "RPC query failed (attempt $attempt/$RPC_RETRY_MAX), retrying in ${RPC_RETRY_DELAY}s..."
      sleep "$RPC_RETRY_DELAY"
    fi
    
    attempt=$((attempt + 1))
  done
  
  echo ""
  return 1
}

# Backup current binary before replacement
backup_binary() {
  if [ "$BACKUP_ENABLED" != "true" ]; then
    return 0
  fi
  
  if [ ! -f "$BIN_ACTIVE" ]; then
    log_warn "BIN_ACTIVE does not exist, skipping backup: $BIN_ACTIVE"
    return 0
  fi
  
  mkdir -p "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  
  local timestamp backup_file
  timestamp=$(date '+%Y%m%d_%H%M%S')
  backup_file="$BACKUP_DIR/${SERVICE_NAME}_${timestamp}.backup"
  
  if cp "$BIN_ACTIVE" "$backup_file"; then
    chmod 0600 "$backup_file"
    log_info "backed up binary to: $backup_file"
  else
    log_error "failed to backup binary: $BIN_ACTIVE"
    exit 1
  fi
}

# Main execution starts here
log_info "starting upgrade watcher for service: $SERVICE_NAME"

log_info "checking dependencies..."
for bin in curl jq flock systemctl install stat; do
  require_bin "$bin"
done

if ! [[ "$UPGRADE_HEIGHT" =~ ^[0-9]+$ ]] || [ "$UPGRADE_HEIGHT" -le 0 ]; then
  log_error "invalid UPGRADE_HEIGHT: $UPGRADE_HEIGHT (expected positive integer)"
  exit 1
fi

if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  validate_file_permissions "$ENV_FILE" "env file"
fi

if [ ! -f "$BIN_NEW" ] || [ -L "$BIN_NEW" ]; then
  log_error "BIN_NEW must be a regular file (not a symlink): $BIN_NEW"
  exit 1
fi

if [ -n "${BIN_NEW_SHA256:-}" ]; then
  require_bin sha256sum
  actual=$(sha256sum "$BIN_NEW" | awk '{print $1}')
  if [ "$actual" != "$BIN_NEW_SHA256" ]; then
    log_error "BIN_NEW sha256 mismatch (expected $BIN_NEW_SHA256, got $actual)"
    exit 1
  fi
  log_info "SHA256 verification passed for BIN_NEW"
fi

validate_file_permissions "$BIN_NEW" "BIN_NEW"

if [ -e "$BIN_ACTIVE" ] && [ -L "$BIN_ACTIVE" ]; then
  log_error "BIN_ACTIVE must not be a symlink: $BIN_ACTIVE"
  exit 1
fi

if [ -L "$LOCK_DIR" ]; then
  log_error "refusing to use symlinked LOCK_DIR: $LOCK_DIR"
  exit 1
fi
mkdir -p "$LOCK_DIR"
chmod 0700 "$LOCK_DIR"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log_warn "another watcher already running, exiting"
  exit 0
fi

ACTIVE_DIR=$(dirname "$BIN_ACTIVE")
if [ ! -d "$ACTIVE_DIR" ]; then
  log_error "target directory does not exist: $ACTIVE_DIR"
  exit 1
fi

WRITE_TEST="$ACTIVE_DIR/.upgrade-watcher.write-test.$$"
if ! ( umask 077 && : > "$WRITE_TEST" ) 2>/dev/null; then
  log_error "cannot write to active binary directory: $ACTIVE_DIR"
  exit 1
fi
rm -f "$WRITE_TEST"

if [ "$BACKUP_ENABLED" = "true" ]; then
  if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
    log_error "failed to create BACKUP_DIR: $BACKUP_DIR"
    exit 1
  fi
  chmod 0700 "$BACKUP_DIR" || true
fi

log_info "watching for height == $UPGRADE_HEIGHT (will fail if surpassed)"
log_info "RPC endpoint: $RPC"
log_info "new binary: $BIN_NEW"
log_info "active binary: $BIN_ACTIVE"

RPC_FAILURE_COUNT=0
while true; do
  HEIGHT=$(get_block_height)
  
  if [[ "$HEIGHT" =~ ^[0-9]+$ ]] && [ "$HEIGHT" -gt 0 ]; then
    RPC_FAILURE_COUNT=0
    
    if [ "$HEIGHT" -gt "$UPGRADE_HEIGHT" ]; then
      log_error "current height $HEIGHT already surpassed target $UPGRADE_HEIGHT; refusing to run"
      exit 1
    fi
    
    if [ "$HEIGHT" -eq "$UPGRADE_HEIGHT" ]; then
      log_info "reached target height: $HEIGHT"
      break
    fi
    
    BLOCKS_REMAINING=$((UPGRADE_HEIGHT - HEIGHT))
    if [ "$BLOCKS_REMAINING" -gt "$DYNAMIC_INTERVAL_THRESHOLD" ]; then
      CURRENT_INTERVAL=$DYNAMIC_INTERVAL_FAR
    else
      CURRENT_INTERVAL=$DYNAMIC_INTERVAL_NEAR
    fi
    
    log_info "height: $HEIGHT, remaining: $BLOCKS_REMAINING blocks, next check in ${CURRENT_INTERVAL}s"
    sleep "$CURRENT_INTERVAL"
  else
    RPC_FAILURE_COUNT=$((RPC_FAILURE_COUNT + 1))
    log_warn "RPC query failed (consecutive failures: $RPC_FAILURE_COUNT), using fallback interval: ${CHECK_INTERVAL}s"
    
    if [ "$RPC_FAILURE_COUNT" -ge 10 ]; then
      log_error "RPC has failed $RPC_FAILURE_COUNT times consecutively - may miss target height"
    fi
    
    sleep "$CHECK_INTERVAL"
  fi
done

log_info "upgrade sequence initiated at height $HEIGHT"

stopped=0
cleanup() {
  if [ "$stopped" = "1" ]; then
    systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log_info "stopping service: $SERVICE_NAME"
if ! systemctl stop "$SERVICE_NAME"; then
  log_error "failed to stop service: $SERVICE_NAME"
  exit 1
fi
stopped=1

sleep 1
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log_error "service is still active after stop command: $SERVICE_NAME"
  exit 1
fi
log_info "service stopped successfully"

backup_binary

log_info "switching binary: $BIN_ACTIVE"

TMP="$ACTIVE_DIR/.upgrade-watcher.$SERVICE_NAME.$$"
if ! install -m 0755 "$BIN_NEW" "$TMP"; then
  log_error "failed to install new binary to temporary location: $TMP"
  exit 1
fi

if ! mv -f "$TMP" "$BIN_ACTIVE"; then
  log_error "failed to replace binary: $BIN_ACTIVE"
  exit 1
fi
log_info "binary replaced successfully"

log_info "starting service: $SERVICE_NAME"
if ! systemctl start "$SERVICE_NAME"; then
  log_error "failed to start service: $SERVICE_NAME"
  exit 1
fi

sleep 2
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  log_error "service failed to start or crashed immediately: $SERVICE_NAME"
  log_error "check service logs: journalctl -u $SERVICE_NAME -n 50"
  exit 1
fi

stopped=0
trap - EXIT

log_info "upgrade completed successfully"
log_info "service $SERVICE_NAME is running with new binary at $BIN_ACTIVE"

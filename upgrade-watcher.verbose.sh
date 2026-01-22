#!/usr/bin/env bash
# Cosmos Off-chain Upgrade Watcher (Verbose/Advanced Version)
# Enhanced version with detailed logging, retry mechanism, and automatic backup
# 
# This is the verbose version with advanced features:
# - Detailed logging with timestamps
# - RPC retry mechanism for better reliability
# - Automatic binary backup before upgrade
# - Enhanced error handling and validation
# - RPC failure tracking and warnings
# 
# For the basic version, see upgrade-watcher.sh

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
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [upgrade] [$level] $message" >&2
}

log_info() {
  log "INFO" "$@"
}

log_error() {
  log "ERROR" "$@"
}

log_warn() {
  log "WARN" "$@"
}

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
  
  local owner=$(stat -c '%u' "$file")
  local mode=$(stat -c '%a' "$file")
  local mode_last3=${mode: -3}  # Last 3 digits (permissions for owner/group/other)
  local g=${mode_last3:1:1}     # Group write bit
  local o=${mode_last3:2:1}     # Other write bit
  
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
    # Query RPC endpoint with timeout to prevent hanging
    height=$(
      curl --connect-timeout 1 --max-time 2 -sSf "$RPC/status" 2>/dev/null \
        | jq -r '.result.sync_info.latest_block_height // empty' 2>/dev/null || true
    )
    
    # Validate height is a positive integer
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
  
  # Return empty string if all retries failed
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
  
  # Create backup directory if it doesn't exist
  mkdir -p "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  
  # Generate backup filename with timestamp and service name
  local timestamp=$(date '+%Y%m%d_%H%M%S')
  local backup_file="$BACKUP_DIR/${SERVICE_NAME}_${timestamp}.backup"
  
  # Copy binary to backup location
  if cp "$BIN_ACTIVE" "$backup_file"; then
    chmod 0600 "$backup_file"  # Restrict backup file permissions
    log_info "backed up binary to: $backup_file"
  else
    log_error "failed to backup binary: $BIN_ACTIVE"
    exit 1
  fi
}

# Main execution starts here
log_info "starting upgrade watcher for service: $SERVICE_NAME"

# Check for required system binaries
log_info "checking dependencies..."
for bin in curl jq flock systemctl install stat; do
  require_bin "$bin"
done

# Validate UPGRADE_HEIGHT is a positive integer
if ! [[ "$UPGRADE_HEIGHT" =~ ^[0-9]+$ ]] || [ "$UPGRADE_HEIGHT" -le 0 ]; then
  log_error "invalid UPGRADE_HEIGHT: $UPGRADE_HEIGHT (expected positive integer)"
  exit 1
fi

# Validate environment file permissions if provided
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  validate_file_permissions "$ENV_FILE" "env file"
fi

# Validate BIN_NEW exists and is a regular file (not symlink)
if [ ! -f "$BIN_NEW" ] || [ -L "$BIN_NEW" ]; then
  log_error "BIN_NEW must be a regular file (not a symlink): $BIN_NEW"
  exit 1
fi

# Verify SHA256 hash if provided (prevents tampered binaries)
if [ -n "${BIN_NEW_SHA256:-}" ]; then
  require_bin sha256sum
  actual=$(sha256sum "$BIN_NEW" | awk '{print $1}')
  if [ "$actual" != "$BIN_NEW_SHA256" ]; then
    log_error "BIN_NEW sha256 mismatch (expected $BIN_NEW_SHA256, got $actual)"
    exit 1
  fi
  log_info "SHA256 verification passed for BIN_NEW"
fi

# Validate BIN_NEW file permissions
validate_file_permissions "$BIN_NEW" "BIN_NEW"

# Validate BIN_ACTIVE is not a symlink (if it exists)
if [ -e "$BIN_ACTIVE" ] && [ -L "$BIN_ACTIVE" ]; then
  log_error "BIN_ACTIVE must not be a symlink: $BIN_ACTIVE"
  exit 1
fi

# Validate and create lock directory
if [ -L "$LOCK_DIR" ]; then
  log_error "refusing to use symlinked LOCK_DIR: $LOCK_DIR"
  exit 1
fi
mkdir -p "$LOCK_DIR"
chmod 0700 "$LOCK_DIR"

# Acquire exclusive lock to prevent multiple watchers from running
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log_warn "another watcher already running, exiting"
  exit 0
fi

log_info "watching for height == $UPGRADE_HEIGHT (will fail if surpassed)"
log_info "RPC endpoint: $RPC"
log_info "new binary: $BIN_NEW"
log_info "active binary: $BIN_ACTIVE"

# Main monitoring loop
RPC_FAILURE_COUNT=0
while true; do
  HEIGHT=$(get_block_height)
  
  if [[ "$HEIGHT" =~ ^[0-9]+$ ]] && [ "$HEIGHT" -gt 0 ]; then
    # Reset failure counter on successful RPC call
    RPC_FAILURE_COUNT=0
    
    # Safety check: refuse to run if we've already passed the target height
    if [ "$HEIGHT" -gt "$UPGRADE_HEIGHT" ]; then
      log_error "current height $HEIGHT already surpassed target $UPGRADE_HEIGHT; refusing to run"
      exit 1
    fi
    
    # Check if we've reached the target height
    if [ "$HEIGHT" -eq "$UPGRADE_HEIGHT" ]; then
      log_info "reached target height: $HEIGHT"
      break
    fi
    
    # Dynamic interval: check less frequently when far from target, more frequently when close
    BLOCKS_REMAINING=$((UPGRADE_HEIGHT - HEIGHT))
    if [ "$BLOCKS_REMAINING" -gt "$DYNAMIC_INTERVAL_THRESHOLD" ]; then
      CURRENT_INTERVAL=$DYNAMIC_INTERVAL_FAR
    else
      CURRENT_INTERVAL=$DYNAMIC_INTERVAL_NEAR
    fi
    
    log_info "height: $HEIGHT, remaining: $BLOCKS_REMAINING blocks, next check in ${CURRENT_INTERVAL}s"
    sleep "$CURRENT_INTERVAL"
  else
    # RPC query failed - use fallback interval
    RPC_FAILURE_COUNT=$((RPC_FAILURE_COUNT + 1))
    log_warn "RPC query failed (consecutive failures: $RPC_FAILURE_COUNT), using fallback interval: ${CHECK_INTERVAL}s"
    
    # If RPC fails too many times consecutively, warn but continue
    if [ "$RPC_FAILURE_COUNT" -ge 10 ]; then
      log_error "RPC has failed $RPC_FAILURE_COUNT times consecutively - may miss target height"
    fi
    
    sleep "$CHECK_INTERVAL"
  fi
done

# Upgrade sequence starts here
log_info "upgrade sequence initiated at height $HEIGHT"

# Step 1: Stop the service
log_info "stopping service: $SERVICE_NAME"
if ! systemctl stop "$SERVICE_NAME"; then
  log_error "failed to stop service: $SERVICE_NAME"
  exit 1
fi

# Wait a moment for service to fully stop
sleep 1

# Verify service is actually stopped
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log_error "service is still active after stop command: $SERVICE_NAME"
  exit 1
fi

log_info "service stopped successfully"

# Step 2: Backup current binary (if enabled)
backup_binary

# Step 3: Replace binary atomically
log_info "switching binary: $BIN_ACTIVE"
ACTIVE_DIR=$(dirname "$BIN_ACTIVE")

# Ensure target directory exists
if [ ! -d "$ACTIVE_DIR" ]; then
  log_error "target directory does not exist: $ACTIVE_DIR"
  exit 1
fi

# Use temporary file with unique name (PID-based) to ensure atomic replacement
TMP="$ACTIVE_DIR/.upgrade-watcher.$SERVICE_NAME.$$"

# Install new binary with proper permissions
if ! install -m 0755 "$BIN_NEW" "$TMP"; then
  log_error "failed to install new binary to temporary location: $TMP"
  exit 1
fi

# Atomic move: mv is atomic on same filesystem, ensuring no partial state
if ! mv -f "$TMP" "$BIN_ACTIVE"; then
  log_error "failed to replace binary: $BIN_ACTIVE"
  exit 1
fi

log_info "binary replaced successfully"

# Step 4: Start the service with new binary
log_info "starting service: $SERVICE_NAME"
if ! systemctl start "$SERVICE_NAME"; then
  log_error "failed to start service: $SERVICE_NAME"
  log_error "upgrade may have failed - check service status and logs"
  exit 1
fi

# Wait a moment for service to start
sleep 2

# Verify service is actually running
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  log_error "service failed to start or crashed immediately: $SERVICE_NAME"
  log_error "check service logs: journalctl -u $SERVICE_NAME -n 50"
  exit 1
fi

log_info "service started successfully with new binary"

# Final verification: check service status one more time
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log_info "upgrade completed successfully"
  log_info "service $SERVICE_NAME is running with new binary at $BIN_ACTIVE"
else
  log_error "service status check failed after upgrade"
  exit 1
fi


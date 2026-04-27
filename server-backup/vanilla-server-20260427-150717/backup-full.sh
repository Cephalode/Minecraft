#!/bin/bash
# Full Minecraft backup — runs every 6 hours, retains 3 days
# Compresses the world folder into a dated tar.gz

set -euo pipefail

MC_DIR="$HOME/devel/minecraft/minecraft-server"
WORLD_DIR="$MC_DIR/world"
BACKUP_DIR="$HOME/devel/minecraft/backups/full"
RETENTION_HOURS=72
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="$HOME/Library/Logs/minecraft-ngrok/backup.log"

mkdir -p "$BACKUP_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FULL] $*" >> "$LOG_FILE"
}

log "Starting full backup..."

# Try to flush saves via RCON (if available), otherwise just copy
if command -v mcrcon &>/dev/null; then
  mcrcon -H 127.0.0.1 -P 25575 -p cephalode "save-all flush" "save-off" >/dev/null 2>&1 || true
  sleep 3
fi

# Create compressed backup
BACKUP_FILE="$BACKUP_DIR/world_full_$TIMESTAMP.tar.gz"
if tar -czf "$BACKUP_FILE" -C "$MC_DIR" world 2>>"$LOG_FILE"; then
  SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
  log "Full backup created: world_full_$TIMESTAMP.tar.gz ($SIZE)"
else
  log "ERROR: Failed to create full backup"
  rm -f "$BACKUP_FILE"
fi

# Re-enable saves if we used RCON
if command -v mcrcon &>/dev/null; then
  mcrcon -H 127.0.0.1 -P 25575 -p cephalode "save-on" >/dev/null 2>&1 || true
fi

# Clean up backups older than retention period
DELETED=$(find "$BACKUP_DIR" -name "world_full_*.tar.gz" -mtime +$((RETENTION_HOURS / 24)) -delete -print 2>>"$LOG_FILE" | wc -l | tr -d ' ')
if [ "$DELETED" -gt 0 ]; then
  log "Cleaned up $DELETED old full backup(s)"
fi

# Count remaining
REMAINING=$(ls -1 "$BACKUP_DIR"/world_full_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
log "Total full backups: $REMAINING"

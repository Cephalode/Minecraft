#!/bin/bash
# Rolling Minecraft backup — runs every 10 minutes, retains 3 hours
# Fast rsync copy of the world folder with incremental hardlinks
# This is a wrapper that delegates to the main backup-quick.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MC_DIR="$HOME/devel/minecraft/minecraft-server"

# If backup-quick.sh exists in the minecraft-server dir, use it
if [ -x "$MC_DIR/backup-quick.sh" ]; then
    "$MC_DIR/backup-quick.sh"
    echo "✅ Rolling backup completed via backup-quick.sh"
    exit 0
fi

# Fallback: inline rolling backup logic
WORLD_DIR="$MC_DIR/world"
BACKUP_DIR="$HOME/devel/minecraft/backups/quick"
RETENTION_MINUTES=180
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="$HOME/Library/Logs/minecraft-ngrok/backup.log"

mkdir -p "$BACKUP_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [QUICK] $*" >> "$LOG_FILE"
}

log "Starting rolling backup..."

# Fast rsync copy — uses hardlinks for unchanged files to save space
LATEST="$BACKUP_DIR/latest"
SNAPSHOT="$BACKUP_DIR/world_quick_$TIMESTAMP"

# rsync with --link-dest for incremental copies
if [ -d "$LATEST" ]; then
  rsync -a --delete --link-dest="$LATEST" "$WORLD_DIR/" "$SNAPSHOT/" 2>>"$LOG_FILE"
else
  rsync -a --delete "$WORLD_DIR/" "$SNAPSHOT/" 2>>"$LOG_FILE"
fi

# Update latest symlink
ln -sfn "$SNAPSHOT" "$LATEST"

SIZE=$(du -sh "$SNAPSHOT" | cut -f1)
log "Rolling backup created: world_quick_$TIMESTAMP ($SIZE)"

# Clean up snapshots older than retention period
CUTOFF=$(date -v-${RETENTION_MINUTES}M '+%Y%m%d_%H%M%S' 2>/dev/null || date -d "-${RETENTION_MINUTES} minutes" '+%Y%m%d_%H%M%S' 2>/dev/null || echo "")
if [ -n "$CUTOFF" ]; then
  DELETED=0
  for dir in "$BACKUP_DIR"/world_quick_*; do
    [ -d "$dir" ] || continue
    [ -L "$dir" ] && continue  # skip symlinks
    DIRNAME=$(basename "$dir")
    STAMP=${DIRNAME#world_quick_}
    if [[ "$STAMP" < "$CUTOFF" ]]; then
      rm -rf "$dir"
      DELETED=$((DELETED + 1))
    fi
  done
  if [ "$DELETED" -gt 0 ]; then
    log "Cleaned up $DELETED old rolling backup(s)"
  fi
fi

# Count remaining
REMAINING=$(ls -1d "$BACKUP_DIR"/world_quick_* 2>/dev/null | grep -v latest | wc -l | tr -d ' ')
log "Total rolling backups: $REMAINING"
echo "Rolling backup complete: world_quick_$TIMESTAMP ($SIZE), $REMAINING snapshots retained"

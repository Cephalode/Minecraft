#!/bin/bash
# Minecraft Vanilla Server Rolling Backup
# Syncs the live server to a timestamped backup, keeping a rolling window of N backups.

set -euo pipefail

SERVER_DIR="$HOME/devel/minecraft/minecraft-server"
BACKUP_BASE="$HOME/devel/minecraft/server-backup"
BACKUP_NAME="vanilla-server-$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_BASE/$BACKUP_NAME"
MAX_BACKUPS=7  # Keep the last 7 rolling backups

echo "=== Minecraft Rolling Backup ==="
echo "Started: $(date)"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Use --link-dest to the latest existing backup for incremental (hardlinked) backups
LATEST_BACKUP=$(ls -dt "$BACKUP_BASE"/vanilla-server-* 2>/dev/null | head -1)
LINK_DEST_ARG=""
if [ -n "$LATEST_BACKUP" ] && [ "$LATEST_BACKUP" != "$BACKUP_DIR" ]; then
    LINK_DEST_ARG="--link-dest=$LATEST_BACKUP"
    echo "Incremental backup based on: $(basename "$LATEST_BACKUP")"
else
    echo "Full backup (no previous backup found)"
fi

# Rsync the server world and config files
echo "Syncing world data..."
rsync -a --delete \
    $LINK_DEST_ARG \
    --exclude='logs/' \
    --exclude='libraries/' \
    --exclude='versions/' \
    --exclude='*.jar' \
    "$SERVER_DIR/" "$BACKUP_DIR/"

echo ""
echo "Backup size:"
du -sh "$BACKUP_DIR"

# Rotate old backups — keep only the most recent MAX_BACKUPS
echo ""
echo "Rotating old backups (keeping last $MAX_BACKUPS)..."
cd "$BACKUP_BASE"
BACKUP_COUNT=$(ls -d vanilla-server-* 2>/dev/null | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    REMOVE_COUNT=$((BACKUP_COUNT - MAX_BACKUPS))
    echo "Removing $REMOVE_COUNT old backup(s)..."
    ls -dt vanilla-server-* | tail -n "$REMOVE_COUNT" | while read -r old_backup; do
        echo "  Removing: $old_backup"
        rm -rf "$old_backup"
    done
else
    echo "Only $BACKUP_COUNT backup(s) exist, no rotation needed."
fi

echo ""
echo "Current backups:"
ls -dt "$BACKUP_BASE"/vanilla-server-* 2>/dev/null | while read -r b; do
    SIZE=$(du -sh "$b" 2>/dev/null | cut -f1)
    echo "  $(basename "$b")  ($SIZE)"
done

echo ""
echo "Completed: $(date)"
echo "=== Backup Done ==="

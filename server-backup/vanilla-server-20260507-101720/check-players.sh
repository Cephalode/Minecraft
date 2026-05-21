#!/usr/bin/env bash
#
# check-players.sh — Report Minecraft player joins since last check.
#
# Tracks state in .last-player-check (epoch seconds).
# Only searches today's latest.log for "joined the game" entries
# newer than the stored timestamp.

set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_FILE="$SERVER_DIR/.last-player-check"
LOG_FILE="$SERVER_DIR/logs/latest.log"

now_epoch=$(date +%s)

# --- First-run: create the marker file and exit silently ---
if [[ ! -f "$CHECK_FILE" ]]; then
    date +%s > "$CHECK_FILE"
    exit 0
fi

last_epoch=$(cat "$CHECK_FILE")

# --- Nothing to scan if latest.log doesn't exist ---
if [[ ! -f "$LOG_FILE" ]]; then
    date +%s > "$CHECK_FILE"
    exit 0
fi

# --- Collect "joined the game" lines from today's latest.log ---
# Log line format: [HH:MM:SS] [Server thread/INFO]: playername joined the game

today=$(date +%Y-%m-%d)
summary=""
first=1

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Extract time from [HH:MM:SS]
    if [[ "$line" =~ ^\[([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        log_time="${BASH_REMATCH[1]}"
    else
        continue
    fi

    # Convert to epoch using today's date
    log_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today $log_time" +%s 2>/dev/null || echo "0")

    # Handle edge case: time is after midnight (would be future)
    if (( log_epoch > now_epoch )); then
        log_epoch=$(( log_epoch - 86400 ))
    fi

    # Only keep entries after the last check
    if (( log_epoch > last_epoch )); then
        # Extract player name
        player=$(echo "$line" | sed -n 's/.*]: \([^ ]*\) joined the game.*/\1/p')
        [[ -z "$player" ]] && continue
        hhmm="${log_time:0:5}"
        if [[ $first -eq 1 ]]; then
            summary="${player} joined at ${hhmm}"
            first=0
        else
            summary="${summary}, ${player} joined at ${hhmm}"
        fi
    fi
done < <(grep "joined the game" "$LOG_FILE" 2>/dev/null || true)

# --- Output ---
if [[ -n "$summary" ]]; then
    echo "🎮 Player activity since last check: ${summary}"
fi

# --- Update the check file ---
date +%s > "$CHECK_FILE"

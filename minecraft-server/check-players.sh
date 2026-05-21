#!/usr/bin/env bash
#
# check-players.sh — Report Minecraft player activity and server health.
#
# Tracks state in .last-player-check (epoch seconds).
# Searches today's latest.log for "joined the game" / "left the game" entries
# newer than the stored timestamp.
#
# Features:
#   - Health check endpoint (writes status JSON to .server-health.json)
#   - Uptime tracking via .server-start-time
#   - Memory usage monitoring (from OS for the java process)
#   - Works as both a cron job and standalone (color output when interactive)
#
# Usage:
#   ./check-players.sh              # Full report
#   ./check-players.sh --health     # Only write health file, no output
#   ./check-players.sh --status     # Print status summary to stdout

set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_FILE="$SERVER_DIR/.last-player-check"
LOG_FILE="$SERVER_DIR/logs/latest.log"
HEALTH_FILE="$SERVER_DIR/.server-health.json"
START_TIME_FILE="$SERVER_DIR/.server-start-time"
PID_FILE="$SERVER_DIR/.server.pid"

# --- Mode detection ---
MODE="full"
if [[ "${1:-}" == "--health" ]]; then
    MODE="health"
elif [[ "${1:-}" == "--status" ]]; then
    MODE="status"
fi

# --- Color helpers (only when running in a terminal) ---
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN='' YELLOW='' CYAN='' RED='' NC=''
fi

now_epoch=$(date +%s)

# ---------------------------------------------------------------
# Helper: count currently online players from the log
# ---------------------------------------------------------------
get_online_players() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo ""
        return
    fi
    # Find the most recent "joined"/"left" lines and track state
    # Simpler: count unique players from "joined" minus "left" since last server start
    # Or just use the last "joined the game" / "left the game" lines
    local joined left
    joined=$(grep -c "joined the game" "$LOG_FILE" 2>/dev/null || echo "0")
    left=$(grep -c "left the game" "$LOG_FILE" 2>/dev/null || echo "0")
    local count=$(( joined - left ))
    if (( count < 0 )); then count=0; fi
    echo "$count"
}

# ---------------------------------------------------------------
# Helper: get server uptime
# ---------------------------------------------------------------
get_uptime() {
    if [[ -f "$START_TIME_FILE" ]]; then
        local start_epoch
        start_epoch=$(cat "$START_TIME_FILE")
        local uptime_seconds=$(( now_epoch - start_epoch ))
        local days=$(( uptime_seconds / 86400 ))
        local hours=$(( (uptime_seconds % 86400) / 3600 ))
        local mins=$(( (uptime_seconds % 3600) / 60 ))
        if (( days > 0 )); then
            echo "${days}d ${hours}h ${mins}m"
        elif (( hours > 0 )); then
            echo "${hours}h ${mins}m"
        else
            echo "${mins}m"
        fi
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------
# Helper: get memory usage of the Java process
# ---------------------------------------------------------------
get_memory_usage() {
    local pid=""
    if [[ -f "$PID_FILE" ]]; then
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
    fi
    # Also try to find it by searching for the server.jar process
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        pid=$(pgrep -f "server.jar" 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        # macOS: use ps -o rss, linux: also works
        local rss_kb
        rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
        if [[ "$rss_kb" != "0" && -n "$rss_kb" ]]; then
            local rss_mb=$(( rss_kb / 1024 ))
            echo "${rss_mb}MB"
        else
            echo "unknown"
        fi
    else
        echo "not running"
    fi
}

# ---------------------------------------------------------------
# Helper: write health check JSON
# ---------------------------------------------------------------
write_health_file() {
    local player_count uptime_str mem_str
    player_count=$(get_online_players)
    uptime_str=$(get_uptime)
    mem_str=$(get_memory_usage)

    cat > "$HEALTH_FILE" <<EOF
{
  "timestamp": $(date +%s),
  "timestamp_iso": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "players_online": ${player_count:-0},
  "uptime": "${uptime_str}",
  "memory": "${mem_str}",
  "server_dir": "${SERVER_DIR}"
}
EOF
}

# ---------------------------------------------------------------
# Always write the health file
# ---------------------------------------------------------------
write_health_file

# In --health mode, we're done
if [[ "$MODE" == "health" ]]; then
    exit 0
fi

# ---------------------------------------------------------------
# Player join tracking (original logic, enhanced)
# ---------------------------------------------------------------

# --- First-run: create the marker file and exit silently ---
if [[ ! -f "$CHECK_FILE" ]]; then
    date +%s > "$CHECK_FILE"
    if [[ "$MODE" == "status" ]]; then
        echo "First run — check file initialized."
    fi
    exit 0
fi

last_epoch=$(cat "$CHECK_FILE")

# --- Nothing to scan if latest.log doesn't exist ---
if [[ ! -f "$LOG_FILE" ]]; then
    date +%s > "$CHECK_FILE"
    if [[ "$MODE" == "status" ]]; then
        echo "No log file found."
    fi
    exit 0
fi

# --- Collect "joined the game" lines from today's latest.log ---
today=$(date +%Y-%m-%d)
joins=""
leaves=""
first_join=1
first_leave=1

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
        hhmm="${log_time:0:5}"

        # Check for joins
        player=$(echo "$line" | sed -n 's/.*]: \([^ ]*\) joined the game.*/\1/p')
        if [[ -n "$player" ]]; then
            if [[ $first_join -eq 1 ]]; then
                joins="${player} at ${hhmm}"
                first_join=0
            else
                joins="${joins}, ${player} at ${hhmm}"
            fi
            continue
        fi

        # Check for leaves
        player=$(echo "$line" | sed -n 's/.*]: \([^ ]*\) left the game.*/\1/p')
        if [[ -n "$player" ]]; then
            if [[ $first_leave -eq 1 ]]; then
                leaves="${player} at ${hhmm}"
                first_leave=0
            else
                leaves="${leaves}, ${player} at ${hhmm}"
            fi
        fi
    fi
done < <(grep -E "(joined|left) the game" "$LOG_FILE" 2>/dev/null || true)

# ---------------------------------------------------------------
# Output
# ---------------------------------------------------------------
if [[ "$MODE" == "status" ]]; then
    # Structured status output
    echo -e "${CYAN}=== Minecraft Server Status ===${NC}"
    echo -e "  Uptime:   ${GREEN}$(get_uptime)${NC}"
    echo -e "  Memory:   ${GREEN}$(get_memory_usage)${NC}"
    echo -e "  Players:  ${GREEN}$(get_online_players) online${NC}"
    if [[ -n "$joins" ]]; then
        echo -e "  Joins:    ${YELLOW}${joins}${NC}"
    fi
    if [[ -n "$leaves" ]]; then
        echo -e "  Leaves:   ${YELLOW}${leaves}${NC}"
    fi
else
    # Original-style output (for cron / notifications)
    if [[ -n "$joins" ]]; then
        echo "🎮 Player activity since last check: ${joins}"
    fi
    if [[ -n "$leaves" ]]; then
        echo "👋 Players who left: ${leaves}"
    fi
fi

# --- Update the check file ---
date +%s > "$CHECK_FILE"

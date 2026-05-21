#!/usr/bin/env bash
#
# start.sh — Start the Minecraft server with robust process management.
#
# Features:
#   - PID file for process management
#   - Automatic backup before starting
#   - Graceful shutdown handler (SIGTERM/SIGINT)
#   - Auto-restart on crash (with configurable delay)
#   - Uptime tracking for health monitoring
#
# Usage:
#   ./start.sh                # Start with auto-restart on crash
#   ./start.sh --no-restart   # Start without auto-restart
#   ./start.sh --stop         # Gracefully stop a running server
#   ./start.sh --status       # Check if server is running
#   ./start.sh --restart      # Stop then start

set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SERVER_DIR/.server.pid"
START_TIME_FILE="$SERVER_DIR/.server-start-time"
LOG_DIR="$SERVER_DIR/logs"
STOP_TIMEOUT=60  # seconds to wait for graceful shutdown
RESTART_DELAY=10 # seconds to wait before restarting after crash
MAX_RESTARTS=5   # max consecutive restarts before giving up

# --- Java configuration ---
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}"
JAVA_BIN="$JAVA_HOME/bin/java"
JAR_FILE="$SERVER_DIR/server.jar"

# --- JVM flags (Aikar's flags for 10GB) ---
JVM_FLAGS=(
    -Xms10G -Xmx10G
    -XX:+UseG1GC -XX:+ParallelRefProcEnabled
    -XX:MaxGCPauseMillis=200
    -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch
    -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40
    -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20
    -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4
    -XX:InitiatingHeapOccupancyPercent=15
    -XX:G1MixedGCLiveThresholdPercent=90
    -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem
    -XX:MaxTenuringThreshold=1
    -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true
)

# --- Color helpers ---
if [[ -t 1 ]]; then
    GREEN='\033[0;32m' YELLOW='\033[1;33m' RED='\033[0;31m' CYAN='\033[0;36m' NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' CYAN='' NC=''
fi

log()  { echo -e "${GREEN}[MC-Start]${NC} $*"; }
warn() { echo -e "${YELLOW}[MC-Start]${NC} $*" >&2; }
err()  { echo -e "${RED}[MC-Start]${NC} $*" >&2; }

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

get_pid() {
    if [[ -f "$PID_FILE" ]]; then
        cat "$PID_FILE" 2>/dev/null || true
    fi
}

cleanup_pid() {
    rm -f "$PID_FILE"
    rm -f "$START_TIME_FILE"
}

# ---------------------------------------------------------------
# Graceful shutdown handler
# ---------------------------------------------------------------
shutdown_server() {
    local pid
    pid=$(get_pid)
    if [[ -z "$pid" ]]; then
        warn "No PID file found. Server may not be running."
        return 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        warn "Process $pid is not running. Cleaning up PID file."
        cleanup_pid
        return 1
    fi

    log "Sending SIGTERM to Minecraft server (PID: $pid)..."
    kill -TERM "$pid" 2>/dev/null || true

    # Wait for the process to exit gracefully
    local waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < STOP_TIMEOUT )); do
        sleep 1
        waited=$((waited + 1))
        if (( waited % 10 == 0 )); then
            log "Still waiting for server to stop... (${waited}s/${STOP_TIMEOUT}s)"
        fi
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "Server did not stop gracefully within ${STOP_TIMEOUT}s. Sending SIGKILL..."
        kill -KILL "$pid" 2>/dev/null || true
        sleep 2
    fi

    cleanup_pid
    log "Server stopped."
}

# ---------------------------------------------------------------
# Signal handler for the wrapper script
# ---------------------------------------------------------------
wrapper_shutdown() {
    log "Received shutdown signal. Stopping server..."
    AUTO_RESTART=false
    local pid
    pid=$(get_pid)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------
# Pre-start backup
# ---------------------------------------------------------------
run_pre_backup() {
    local backup_script="$SERVER_DIR/backup-full.sh"
    if [[ -x "$backup_script" ]]; then
        log "Running pre-start backup..."
        "$backup_script" 2>&1 || warn "Pre-start backup failed (non-fatal, continuing)"
    else
        warn "Backup script not found or not executable: $backup_script"
    fi
}

# ---------------------------------------------------------------
# Start the server
# ---------------------------------------------------------------
start_server() {
    if is_running; then
        err "Server is already running (PID: $(get_pid))"
        exit 1
    fi

    # Verify Java exists
    if [[ ! -x "$JAVA_BIN" ]]; then
        err "Java not found at: $JAVA_BIN"
        err "Set JAVA_HOME environment variable to fix this."
        exit 1
    fi

    # Verify server jar exists
    if [[ ! -f "$JAR_FILE" ]]; then
        err "Server jar not found: $JAR_FILE"
        exit 1
    fi

    # Ensure log directory exists
    mkdir -p "$LOG_DIR"

    log "Starting Minecraft server..."
    log "  Java: $JAVA_BIN"
    log "  Jar:  $JAR_FILE"
    log "  Dir:  $SERVER_DIR"

    # Record start time for uptime tracking
    date +%s > "$START_TIME_FILE"

    cd "$SERVER_DIR"
    exec "$JAVA_BIN" "${JVM_FLAGS[@]}" -jar "$JAR_FILE" --nogui &
    local server_pid=$!
    echo "$server_pid" > "$PID_FILE"
    log "Server started with PID: $server_pid"
}

# ---------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------

case "${1:-}" in
    --stop)
        if is_running; then
            shutdown_server
        else
            warn "Server is not running."
            cleanup_pid
        fi
        exit 0
        ;;
    --status)
        if is_running; then
            pid=$(get_pid)
            log "Server is running (PID: $pid)"
            # Show uptime
            if [[ -f "$START_TIME_FILE" ]]; then
                start_epoch=$(cat "$START_TIME_FILE")
                uptime_s=$(( $(date +%s) - start_epoch ))
                h=$(( uptime_s / 3600 ))
                m=$(( (uptime_s % 3600) / 60 ))
                log "  Uptime: ${h}h ${m}m"
            fi
            # Show memory
            rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
            if [[ "$rss_kb" != "0" ]]; then
                log "  Memory: $(( rss_kb / 1024 ))MB"
            fi
        else
            warn "Server is not running."
            cleanup_pid
        fi
        exit 0
        ;;
    --restart)
        if is_running; then
            shutdown_server
            sleep 3
        fi
        ;;
    --no-restart)
        # Fall through to start without auto-restart
        run_pre_backup
        start_server
        wait "$(get_pid)"
        cleanup_pid
        exit $?
        ;;
    --help|-h)
        echo "Usage: $0 [--stop|--status|--restart|--no-restart|--help]"
        exit 0
        ;;
esac

# ---------------------------------------------------------------
# Default: start with auto-restart on crash
# ---------------------------------------------------------------

# Set up signal handlers
trap wrapper_shutdown SIGTERM SIGINT
AUTO_RESTART=true
restart_count=0

run_pre_backup
start_server

while $AUTO_RESTART; do
    pid=$(get_pid)
    if [[ -n "$pid" ]]; then
        wait "$pid" 2>/dev/null || true
        exit_code=$?
    else
        exit_code=1
    fi

    if ! $AUTO_RESTART; then
        # We received a signal to stop
        cleanup_pid
        break
    fi

    restart_count=$((restart_count + 1))

    if (( restart_count > MAX_RESTARTS )); then
        err "Server has crashed ${restart_count} times. Giving up to prevent restart loop."
        err "Check the logs and restart manually."
        cleanup_pid
        exit 1
    fi

    err "Server exited with code ${exit_code} (crash #${restart_count}/${MAX_RESTARTS})"
    log "Restarting in ${RESTART_DELAY} seconds... (Ctrl+C to cancel)"
    sleep "$RESTART_DELAY"

    # Reset restart counter on successful uptime > 5 minutes
    if [[ -f "$START_TIME_FILE" ]]; then
        start_epoch=$(cat "$START_TIME_FILE")
        uptime_s=$(( $(date +%s) - start_epoch ))
        if (( uptime_s > 300 )); then
            restart_count=0
        fi
    fi

    start_server
done

cleanup_pid
log "Server wrapper exited."

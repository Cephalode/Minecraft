#!/bin/bash
# Minecraft + ngrok launcher with automatic Cloudflare SRV record updates
# Runs as a LaunchAgent on login

set -euo pipefail

# === Config ===
MC_DIR="$HOME/devel/minecraft/minecraft-server"
NGROK_BIN="/opt/homebrew/bin/ngrok"
CF_API_TOKEN='REDACTED'
CF_ZONE_ID="REDACTED"
CF_SRV_RECORD_ID="REDACTED"
SRV_NAME="_minecraft._tcp.mc.cephalode.com"
LOG_DIR="$HOME/Library/Logs/minecraft-ngrok"
NGROK_API="http://127.0.0.1:4040/api/tunnels"

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/manager.log"
}

# === Step 1: Start Minecraft server ===
log "Starting Minecraft server..."
cd "$MC_DIR"
bash start.sh >> "$LOG_DIR/minecraft.log" 2>&1 &
MC_PID=$!
log "Minecraft started (PID: $MC_PID)"

# Wait for MC to be listening on port 25565
log "Waiting for Minecraft to listen on port 25565..."
for i in $(seq 1 60); do
  if lsof -i :25565 -sTCP:LISTEN >/dev/null 2>&1; then
    log "Minecraft is ready on port 25565"
    break
  fi
  sleep 2
done

# === Step 2: Start ngrok ===
log "Starting ngrok TCP tunnel..."
"$NGROK_BIN" tcp 25565 --log=stdout --log-format=logfmt >> "$LOG_DIR/ngrok.log" 2>&1 &
NGROK_PID=$!
log "ngrok started (PID: $NGROK_PID)"

# Wait for ngrok to be ready
log "Waiting for ngrok tunnel..."
NGROK_URL=""
for i in $(seq 1 30); do
  sleep 2
  NGROK_URL=$(curl -s "$NGROK_API" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    url = data['tunnels'][0]['public_url']
    print(url)
except:
    print('')
" 2>/dev/null || true)

  if [ -n "$NGROK_URL" ]; then
    break
  fi
done

if [ -z "$NGROK_URL" ]; then
  log "ERROR: Failed to get ngrok tunnel URL after 60 seconds"
  exit 1
fi

# Parse the ngrok URL (format: tcp://hostname:port)
NGROK_HOST=$(echo "$NGROK_URL" | sed 's|tcp://||' | cut -d: -f1)
NGROK_PORT=$(echo "$NGROK_URL" | sed 's|tcp://||' | cut -d: -f2)
log "ngrok tunnel active: $NGROK_HOST:$NGROK_PORT"

# === Step 3: Update Cloudflare SRV record ===
update_srv() {
  local HOST="$1"
  local PORT="$2"
  log "Updating Cloudflare SRV record to point to $HOST:$PORT..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_SRV_RECORD_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{
      \"ttl\": 60,
      \"data\": {
        \"service\": \"_minecraft\",
        \"proto\": \"_tcp\",
        \"name\": \"mc\",
        \"priority\": 0,
        \"weight\": 5,
        \"port\": $PORT,
        \"target\": \"$HOST\"
      }
    }")

  if [ "$HTTP_CODE" = "200" ]; then
    log "SRV record updated successfully! mc.cephalode.com → $HOST:$PORT"
  else
    log "WARNING: SRV update returned HTTP $HTTP_CODE (may need manual update)"
  fi
}

update_srv "$NGROK_HOST" "$NGROK_PORT"

# === Step 4: Monitor processes ===
log "Monitoring Minecraft and ngrok..."
while true; do
  if ! kill -0 $MC_PID 2>/dev/null; then
    log "Minecraft server stopped (PID $MC_PID). Shutting down."
    kill $NGROK_PID 2>/dev/null || true
    break
  fi
  if ! kill -0 $NGROK_PID 2>/dev/null; then
    log "ngrok stopped (PID $NGROK_PID). Restarting..."
    "$NGROK_BIN" tcp 25565 --log=stdout --log-format=logfmt >> "$LOG_DIR/ngrok.log" 2>&1 &
    NGROK_PID=$!
    sleep 5
    # Re-fetch ngrok URL and update DNS
    NEW_URL=$(curl -s "$NGROK_API" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data['tunnels'][0]['public_url'])
except:
    print('')
" 2>/dev/null || true)
    if [ -n "$NEW_URL" ]; then
      NEW_HOST=$(echo "$NEW_URL" | sed 's|tcp://||' | cut -d: -f1)
      NEW_PORT=$(echo "$NEW_URL" | sed 's|tcp://||' | cut -d: -f2)
      update_srv "$NEW_HOST" "$NEW_PORT"
    fi
  fi
  sleep 10
done

log "minecraft-ngrok manager exited."

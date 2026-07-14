#!/usr/bin/env bash
# tunnel-watchdog.sh — keeps a VS Code tunnel alive across CLI self-updates,
# including the wedged-but-not-exited state after "respawn requested".
set -u

CODE="${CODE:-$HOME/code}"                 # path to the `code` CLI binary
TUNNEL_NAME="${TUNNEL_NAME:-together}"     # your tunnel name
LOG="${LOG:-$HOME/tunnel.log}"
CHECK_INTERVAL=60                          # seconds between health probes
STARTUP_GRACE=30                           # let it connect before first probe

log() { echo "[watchdog $(date '+%F %T')] $*" >> "$LOG"; }

kill_tunnel() {
  # Ask nicely, then hard-kill the whole tree (CLI + spawned code-server).
  timeout 10 "$CODE" tunnel kill >/dev/null 2>&1
  pkill -f "code tunnel" 2>/dev/null
  sleep 3
  pkill -9 -f "code tunnel" 2>/dev/null
  pkill -9 -f ".vscode/cli/servers" 2>/dev/null
}

healthy() {
  # `tunnel status` talks to the running singleton. When the process is
  # wedged post-update, this hangs (caught by timeout) or reports no tunnel.
  local out
  out="$(timeout 15 "$CODE" tunnel status 2>/dev/null)" || return 1
  grep -q '"name"' <<< "$out"
}

while true; do
  kill_tunnel
  log "starting tunnel '$TUNNEL_NAME'"
  "$CODE" tunnel --accept-server-license-terms --name "$TUNNEL_NAME" >> "$LOG" 2>&1 &
  pid=$!
  sleep "$STARTUP_GRACE"

  while kill -0 "$pid" 2>/dev/null; do
    if ! healthy; then
      sleep 10                 # debounce transient blips
      if ! healthy; then
        log "tunnel unhealthy (wedged after self-update?), restarting"
        break
      fi
    fi
    sleep "$CHECK_INTERVAL"
  done

  log "restart cycle for pid $pid"
  sleep 5
done

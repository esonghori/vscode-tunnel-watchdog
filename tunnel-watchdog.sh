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

# Markers the CLI itself prints when a post-update respawn wedges: it defers to
# a stuck existing singleton instead of taking over. `tunnel status` still
# reports the name in this state (registration survives the wedge), so the
# status probe alone misses it — we must scan the log too.
WEDGE_MARKERS='respawn requested|Command-line options will not be applied|Connected to an existing tunnel process'

healthy() {
  # 1) Status probe: catches the two failure modes `status` *can* see —
  #    hanging (caught by timeout) and reporting no tunnel.
  local out
  out="$(timeout 15 "$CODE" tunnel status 2>/dev/null)" || return 1
  grep -q '"name"' <<< "$out" || return 1

  # 2) Wedge-marker probe: catches the wedge `status` can't see, where the
  #    tunnel still reports its name but can't attach a server. Only inspect
  #    output written since this launch, so a healed wedge from a prior cycle
  #    doesn't trigger a spurious restart.
  local since
  since="$(tail -c +$((LAUNCH_OFFSET + 1)) "$LOG" 2>/dev/null)"
  grep -Eq "$WEDGE_MARKERS" <<< "$since" && return 1

  return 0
}

while true; do
  kill_tunnel
  log "starting tunnel '$TUNNEL_NAME'"
  LAUNCH_OFFSET="$(wc -c < "$LOG" 2>/dev/null || echo 0)"  # scan only this launch's log output
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

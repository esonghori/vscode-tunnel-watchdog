# vscode-tunnel-watchdog

Keeps a [VS Code Remote Tunnel](https://code.visualstudio.com/docs/remote/tunnels)
alive on machines **without systemd** (e.g. containers on cloud GPU providers).

## The problem

The `code` CLI periodically self-updates. After an update, the tunnel process
often does **not** exit cleanly — it stays alive but wedged:

```
[rpc.25] Updating CLI to 1.127.0 (commit ...)
[rpc.25] Disposed of connection to running server.
warn respawn requested, starting new server
```

At this point clients (vscode.dev, desktop VS Code) can no longer connect, but
because the process never exits, a plain restart loop or `autorestart=true`
supervisor never fires. The official fix, `code tunnel service install`, only
works on systemd Linux / Windows / macOS — not inside most containers.

## The fix

`tunnel-watchdog.sh` runs the tunnel and actively **health-checks** it with
`code tunnel status` (with a timeout — a wedged singleton hangs or reports no
tunnel). On two consecutive failed probes it kills the whole process tree and
relaunches. Worst-case downtime after a self-update is ~90 seconds, with the
default probe interval, instead of "until you SSH in and fix it".

## Usage

```bash
chmod +x tunnel-watchdog.sh

# stop any existing tunnel first
pkill -f "code tunnel"

# run detached under tmux
tmux new-session -d -s tunnel \
  'CODE=$HOME/code TUNNEL_NAME=my-machine ./tunnel-watchdog.sh'

# ...or with nohup if tmux is unavailable
nohup env CODE=$HOME/code TUNNEL_NAME=my-machine \
  ./tunnel-watchdog.sh >/dev/null 2>&1 &
```

Verify:

```bash
tail -f ~/tunnel.log     # watchdog + tunnel output
~/code tunnel status     # should report your tunnel once connected
```

> **Note:** on the very first run the CLI may prompt for GitHub/Microsoft
> auth. Run it once in the foreground (`./code tunnel`) to cache credentials
> in `~/.vscode/cli` before launching the watchdog detached.

## Configuration

All via environment variables:

| Variable    | Default            | Description                          |
|-------------|--------------------|--------------------------------------|
| `CODE`      | `$HOME/code`       | Path to the `code` CLI binary        |
| `TUNNEL_NAME` | `together`       | Tunnel name (`--name`)               |
| `LOG`       | `$HOME/tunnel.log` | Combined watchdog + tunnel log file  |

Probe cadence is set inside the script: `CHECK_INTERVAL` (default 60 s
between health probes) and `STARTUP_GRACE` (default 30 s before the first
probe after a launch).

## Testing the self-heal

Simulate a wedged tunnel without waiting for a VS Code release:

```bash
kill -STOP $(pgrep -f "code tunnel" | head -1)
```

The process stays alive but unresponsive. Within ~90 s the log should show
`tunnel unhealthy (wedged after self-update?), restarting` followed by a
fresh launch.

## If it keeps wedging

A corrupted mid-update server directory can cause repeated failures. Add this
line inside `kill_tunnel()` to force a fresh server download on every
restart:

```bash
rm -rf ~/.vscode/cli/servers/*
```

## Surviving container restarts

The watchdog is now the process that must not die. If your container
restarts, relaunch the watchdog from your entrypoint or a startup hook —
e.g. add the `tmux`/`nohup` line above to the image entrypoint script.


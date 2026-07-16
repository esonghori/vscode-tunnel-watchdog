# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script (`tunnel-watchdog.sh`) that supervises a VS Code Remote
Tunnel on systemd-less hosts (containers on cloud GPU providers). No build, no
tests, no dependencies beyond a POSIX shell + `code` CLI + `timeout`/`pkill`.

## The core problem it solves

The `code` CLI self-updates and afterward often enters a **wedged-but-alive**
state ("respawn requested" in the log): clients can't connect, but the process
never exits — so `autorestart` supervisors and restart loops never fire. This
script exists precisely because a liveness check (`kill -0`) is insufficient;
it does an active **readiness** probe instead.

## Architecture (why the loop is shaped the way it is)

Two nested loops in `tunnel-watchdog.sh`:

- **Outer loop**: `kill_tunnel` → launch tunnel → monitor → repeat. Always kills
  first so a wedged predecessor can't linger.
- **Inner loop**: while the pid is alive, probe `healthy()` every
  `CHECK_INTERVAL`. A restart is triggered by *unhealthiness*, not by the
  process dying.

Key design points to preserve when editing:

- `healthy()` has **two** probes, and both must stay:
  1. `code tunnel status` under `timeout`, grepping for `"name"` — catches the
     failure modes `status` can see: hanging (caught by `timeout`) and
     reporting no tunnel.
  2. A scan of the log (only output written since the current launch, tracked
     via `LAUNCH_OFFSET`) for the CLI's own wedge markers — `respawn
     requested`, `Command-line options will not be applied`, `Connected to an
     existing tunnel process`. This exists because a real incident showed the
     status probe is **insufficient on its own**: after a self-update wedge the
     singleton stays *registered*, so `status` still returns `"name"` and reads
     healthy even though clients can't connect. The CLI announces the wedge in
     the log; probe #2 is what actually catches it.

  Don't replace either probe with a process/port check; that reintroduces the
  original bug. The `LAUNCH_OFFSET` window is what stops a wedge already healed
  in a prior cycle from causing spurious restarts — keep it.
- Health failures are **debounced**: two consecutive failed probes (10 s apart)
  before restart, to ride out transient blips.
- `kill_tunnel` tears down the **whole tree** — the `code tunnel` CLI *and* the
  spawned `.vscode/cli/servers` process — with graceful-then-`-9` escalation.
  Killing only the CLI leaves an orphaned server.

## Configuration

Env vars: `CODE` (CLI path, default `$HOME/code`), `TUNNEL_NAME` (default
`together`), `LOG` (default `$HOME/tunnel.log`). Timing constants
`CHECK_INTERVAL` (60 s) and `STARTUP_GRACE` (30 s) are hardcoded at the top of
the script.

## Running / manually testing self-heal

```bash
# run detached
tmux new-session -d -s tunnel 'CODE=$HOME/code TUNNEL_NAME=my-machine ./tunnel-watchdog.sh'

# simulate a wedged tunnel (process alive but unresponsive)
kill -STOP $(pgrep -f "code tunnel" | head -1)
# within ~90s the log shows "tunnel unhealthy ..., restarting"
```

First run may need foreground auth (`./code tunnel`) to cache GitHub/Microsoft
credentials in `~/.vscode/cli` before running detached.

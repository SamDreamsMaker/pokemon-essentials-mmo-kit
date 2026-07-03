@echo off
rem ============================================================================
rem  Starts the PEMK dedicated server (Ruby + Postgres) in WSL Debian for local
rem  testing. Keep this window OPEN while you play; close it (or Ctrl-C) to stop.
rem  Game clients connect to 127.0.0.1:9998.
rem
rem  All the logic lives in server/bin/dev-server.sh (LF, robust) so there is no
rem  fragile cmd<->bash quoting here. Prereqs (one-time on this machine): ruby-full
rem  + postgresql in WSL and the ~/pemk-env.sh + ~/pemk-pgdata dev cluster.
rem ============================================================================
echo Starting PEMK dedicated server in WSL (127.0.0.1:9998) -- keep this open...
wsl -d Debian bash -c "cd '/mnt/c/Pokemon Essentials MMO Kit/server' && bash bin/dev-server.sh"
echo.
echo Server stopped.
pause

@echo off
rem ============================================================================
rem  Starts the PEMK dedicated server (Ruby + Postgres) inside WSL Debian for
rem  local testing. Keep this window OPEN while you play; close it (or Ctrl-C)
rem  to stop the server. Game clients connect to 127.0.0.1:9998.
rem
rem  Prereqs (one-time, already done on this machine): ruby-full + postgresql in
rem  WSL, and the ~/pemk-env.sh + ~/pemk-pgdata dev cluster.
rem ============================================================================
echo Starting PEMK dedicated server in WSL (127.0.0.1:9998) -- keep this open...
wsl -d Debian bash -lc "source ~/pemk-env.sh; ( \"$PGBIN/pg_isready\" -h 127.0.0.1 -p \"$PGPORT\" >/dev/null 2>&1 || \"$PGBIN/pg_ctl\" -D ~/pemk-pgdata -o \"-p $PGPORT -k /tmp -c listen_addresses=127.0.0.1\" -l ~/pemk-pgdata/server.log -w start ); cd '/mnt/c/Pokemon Essentials MMO Kit/server'; bundle exec rake db:migrate; PEMK_BIND=0.0.0.0 PEMK_PORT=9998 bundle exec ruby bin/pemk_server.rb"
echo.
echo Server stopped.
pause

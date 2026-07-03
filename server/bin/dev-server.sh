#!/usr/bin/env bash
# Local WSL dev launcher for the PEMK dedicated server: bring up the user-level
# Postgres cluster if needed, free the port from any stale instance, migrate, and
# run the server on 0.0.0.0:9998. Assumes the WSL dev setup (~/pemk-env.sh with
# PGBIN/PGPORT/DATABASE_URL). For a real deployment use `docker compose up` instead.
set -e

[ -f "$HOME/pemk-env.sh" ] && . "$HOME/pemk-env.sh"
: "${PGBIN:=/usr/lib/postgresql/15/bin}"
: "${PGPORT:=55432}"
: "${DATABASE_URL:=postgres://sam@127.0.0.1:${PGPORT}/pemk}"
export DATABASE_URL

# Ensure the dev Postgres cluster is running (no-op if already up or absent).
if [ -x "$PGBIN/pg_ctl" ] && ! "$PGBIN/pg_isready" -h 127.0.0.1 -p "$PGPORT" >/dev/null 2>&1; then
  "$PGBIN/pg_ctl" -D "$HOME/pemk-pgdata" \
    -o "-p $PGPORT -k /tmp -c listen_addresses=127.0.0.1" \
    -l "$HOME/pemk-pgdata/server.log" -w start
fi

# Free the port from a previous instance (a re-launch takes over cleanly).
pkill -f 'ruby bin/pemk_server.rb' 2>/dev/null || true
sleep 0.5

cd "$(dirname "$0")/.."   # -> server/
bundle exec rake db:migrate
echo "PEMK server starting on 0.0.0.0:9998 (Ctrl-C to stop)"
exec env PEMK_BIND=0.0.0.0 PEMK_PORT=9998 bundle exec ruby bin/pemk_server.rb

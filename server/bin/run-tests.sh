#!/usr/bin/env bash
#==============================================================================
# Run the PEMK server test suite against an ISOLATED `pemk_test` database, so it
# never touches your dev data. Migrates pemk_test to the latest schema, syntax-
# checks every source + test file, then runs the suite. Run bin/setup.sh once first.
#==============================================================================
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HOME/pemk-env.sh" ] && source "$HOME/pemk-env.sh"
: "${PGBIN:=/usr/lib/postgresql/15/bin}"
: "${PGPORT:=55432}"
PGUSER="$(id -un)"

cd "$SERVER_DIR"

# Bring the dev cluster up if it isn't (no-op if already running).
if [ -x "$PGBIN/pg_isready" ] && ! "$PGBIN/pg_isready" -h 127.0.0.1 -p "$PGPORT" >/dev/null 2>&1; then
  "$PGBIN/pg_ctl" -D "$HOME/pemk-pgdata" \
    -o "-p $PGPORT -k /tmp -c listen_addresses=127.0.0.1" \
    -l "$HOME/pemk-pgdata/server.log" -w start
fi

# Isolated test DB (create if missing).
"$PGBIN/createdb" -h 127.0.0.1 -p "$PGPORT" -U "$PGUSER" pemk_test 2>/dev/null || true
export DATABASE_URL="postgres://$PGUSER@127.0.0.1:$PGPORT/pemk_test"

echo "== migrate pemk_test =="
bundle exec rake db:migrate

echo "== syntax check =="
for f in lib/pemk.rb lib/pemk/*.rb bin/*.rb ../protocol/*.rb test/*.rb; do
  ruby -c "$f" >/dev/null && echo "ok  $f"
done

echo "== rake test =="
bundle exec rake test

#!/usr/bin/env bash
# Applies the engagement-loop migrations (143+) on a throwaway database and
# runs every test_*.sql in this directory. Needs a reachable PostgreSQL 15
# (vanilla is fine: PostGIS / pg_cron / pg_net are stubbed by 00_fixtures.sql).
#
#   PGHOST=localhost PGPORT=54329 PGUSER=postgres supabase/tests/engagement/run.sh
#   supabase/tests/engagement/run.sh test_143_engagement_push_queue.sql   # one file
#
# Env: PGBIN (dir with psql/createdb/dropdb; defaults to the Homebrew
# postgresql@15 path), PGHOST, PGPORT, PGUSER. Set KEEP_DB=1 to leave the
# database behind for inspection.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@15/bin}"
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-54329}"
export PGUSER="${PGUSER:-postgres}"

DB="engagement_test_$$_$RANDOM"
PSQL=("$PGBIN/psql" -v ON_ERROR_STOP=1 -X -q -d "$DB")

cleanup() {
  if [[ "${KEEP_DB:-0}" != "1" ]]; then
    "$PGBIN/dropdb" --if-exists "$DB" >/dev/null 2>&1 || true
  else
    echo "kept database $DB"
  fi
}
trap cleanup EXIT

"$PGBIN/createdb" "$DB"

echo "== fixtures"
"${PSQL[@]}" -f "$HERE/00_fixtures.sql"

echo "== migrations"
for f in "$ROOT"/supabase/migrations/14[3-9]_*.sql "$ROOT"/supabase/migrations/1[5-9][0-9]_*.sql; do
  [[ -e "$f" ]] || continue
  echo "   $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done

echo "== tests"
if [[ $# -gt 0 ]]; then
  tests=("$@")
else
  tests=()
  for t in "$HERE"/test_*.sql; do
    [[ -e "$t" ]] && tests+=("$(basename "$t")")
  done
fi

failed=0
for t in ${tests[@]+"${tests[@]}"}; do
  if "${PSQL[@]}" -f "$HERE/$t" >/tmp/engagement_test_out.$$ 2>&1; then
    echo "   ok   $t"
  else
    echo "   FAIL $t"
    cat /tmp/engagement_test_out.$$
    failed=1
  fi
done
rm -f /tmp/engagement_test_out.$$

exit $failed

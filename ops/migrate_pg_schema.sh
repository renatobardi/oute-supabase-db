#!/usr/bin/env bash
#
# migrate_pg_schema.sh — moves one app's data from its own Postgres container into its schema here.
# Runs on the Mac; everything on the server goes through ssh (no sudo). Pilot 3 (hanko) is the first user.
#
#   ./ops/migrate_pg_schema.sh rehearse   # copy into a scratch database, compare row counts, drop it. Does not touch the app.
#   ./ops/migrate_pg_schema.sh cutover    # target schema must be empty; stops the app, copies, compares, restores into it.
#
# Path of the data (both modes): pg_dump -Fc of the source schema inside the app LXC → file in a 0700 temp dir on the
# host → streamed into supabase-db → restored into the scratch database migr_<schema> → source schema renamed to <schema>
# → exact row count per table on both sides (one query, query_to_xml) and diff.
# cutover then dumps <schema> from the scratch database and restores it into database `postgres` as app_<schema>
# (--role, so the app role owns every object and the default privileges grant SELECT to ro_<schema>), in one transaction,
# without the schema entry (the schema exists and belongs to the app role), and compares the counts again.
# Nothing here prints a secret. The app is left STOPPED after cutover: point its URL at the new schema and deploy.
#
# Defaults are for hanko; override with env vars:
#   SRC_LXC=hanko-prd SRC_CONTAINER=hanko-postgres-1 SRC_USER=hanko SRC_DB=hanko SRC_SCHEMA=public
#   SRC_APP_DIR=/opt/app SRC_STOP_SERVICES=hanko SCHEMA=hanko_prd

set -euo pipefail

MODE="${1:-}"
case "$MODE" in rehearse|cutover) ;; *) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac

HOST="${OUTE_HOST:-oute-server}"
DB_LXC="${LXC_NAME:-oute-supabase-db}"
DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
SRC_LXC="${SRC_LXC:-hanko-prd}"
SRC_CONTAINER="${SRC_CONTAINER:-hanko-postgres-1}"
SRC_USER="${SRC_USER:-hanko}"
SRC_DB="${SRC_DB:-hanko}"
SRC_SCHEMA="${SRC_SCHEMA:-public}"
SRC_APP_DIR="${SRC_APP_DIR:-/opt/app}"
SRC_STOP_SERVICES="${SRC_STOP_SERVICES:-hanko}"
SCHEMA="${SCHEMA:-hanko_prd}"

for v in SRC_SCHEMA SCHEMA; do
  [[ "${!v}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || { echo "  [ERROR] ${v}='${!v}' is not a plain lowercase identifier" >&2; exit 2; }
done

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
echo ">> ${MODE}: ${SRC_LXC}/${SRC_CONTAINER} ${SRC_DB}.${SRC_SCHEMA} → ${DB_LXC} postgres.${SCHEMA}"

# The whole job runs on the host: the script is copied to a temp file there and run with stdin closed, so no
# `lxc exec`/`docker exec -i` inside it can swallow the rest of the script. Variables travel quoted at its top.
{
  for v in MODE DB_LXC DB_CONTAINER SRC_LXC SRC_CONTAINER SRC_USER SRC_DB SRC_SCHEMA SRC_APP_DIR SRC_STOP_SERVICES SCHEMA; do
    printf '%s=%q\n' "$v" "${!v}"
  done
  cat <<'REMOTE'
set -euo pipefail
ok()   { printf '  [ok]   %s\n' "$*"; }
die()  { printf '  [ERROR] %s\n' "$*" >&2; exit 1; }
SCRATCH="migr_${SCHEMA}"
ROLE="app_${SCHEMA}"
T="$(mktemp -d /tmp/migr-${SCHEMA}.XXXXXX)"; chmod 700 "$T"
# `lxc exec` eats stdin: every call that needs none gets </dev/null
src()  { lxc exec "$SRC_LXC" -- "$@"; }
dbx()  { lxc exec "$DB_LXC" -- docker exec -i "$DB_CONTAINER" "$@"; }
dpsql() { local d="$1"; shift; dbx psql -U supabase_admin -d "$d" -v ON_ERROR_STOP=1 -qAtX "$@"; }
cleanup() {
  dbx rm -rf /tmp/migr </dev/null >/dev/null 2>&1 || true
  dpsql postgres -c "DROP DATABASE IF EXISTS ${SCRATCH} WITH (FORCE)" </dev/null >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

# count_sql SCHEMA: one row "table<TAB>rows" per base table, exact counts in a single query
count_sql() {
  cat <<SQL
SELECT t.table_name || E'\t' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', t.table_schema, t.table_name), false, true, '')))[1]::text
FROM information_schema.tables t WHERE t.table_schema = '$1' AND t.table_type = 'BASE TABLE' ORDER BY t.table_name;
SQL
}
src_counts() { count_sql "$SRC_SCHEMA" | src docker exec -i "$SRC_CONTAINER" psql -U "$SRC_USER" -d "$SRC_DB" -v ON_ERROR_STOP=1 -qAtX; }
dst_counts() { count_sql "$SCHEMA" | dpsql "$1"; }
compare() { # label file_a file_b
  local n; n="$(wc -l < "$2")"
  [[ "$n" -gt 0 ]] || die "$1: no tables on the source side"
  if diff "$2" "$3" > "$T/diff"; then
    ok "$1: ${n} tables, $(awk -F'\t' '{s+=$2} END {print s}' "$2") rows, identical counts"
  else
    cat "$T/diff" >&2; die "$1: row counts differ (above: < source, > target)"
  fi
}

# 0) preconditions
src docker inspect -f '{{.State.Running}}' "$SRC_CONTAINER" </dev/null | grep -qx true || die "source container ${SRC_CONTAINER} not running in ${SRC_LXC}"
[[ "$(dpsql postgres -c "SELECT 1 FROM pg_namespace WHERE nspname = '${SCHEMA}'" </dev/null)" == 1 ]] || die "schema ${SCHEMA} does not exist (PG_PROJECTS + init-projects.sh)"
[[ "$(dpsql postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '${ROLE}'" </dev/null)" == 1 ]] || die "role ${ROLE} does not exist"
sv="$(src docker exec "$SRC_CONTAINER" psql -U "$SRC_USER" -d "$SRC_DB" -qAtX -c 'SHOW server_version_num' </dev/null)"
dv="$(dpsql postgres -c 'SHOW server_version_num' </dev/null)"
(( sv / 10000 <= dv / 10000 )) || die "source Postgres ${sv} is newer than the target ${dv}"
ok "source ${sv}, target ${dv}"
inside="$(dpsql postgres -c "SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '${SCHEMA}')
  + (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = '${SCHEMA}')
  + (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = '${SCHEMA}' AND t.typtype <> 'c')" </dev/null)"
if [[ "$MODE" == cutover ]]; then
  [[ "$inside" == 0 ]] || die "schema ${SCHEMA} is not empty (${inside} objects); refusing to restore over it"
  ok "schema ${SCHEMA} is empty"
else
  ok "schema ${SCHEMA} has ${inside} objects (rehearse does not touch it)"
fi

# 1) stop the app (cutover): nothing writes after the dump
if [[ "$MODE" == cutover ]]; then
  # shellcheck disable=SC2086
  src docker compose -f "${SRC_APP_DIR}/docker-compose.yml" --project-directory "$SRC_APP_DIR" stop $SRC_STOP_SERVICES </dev/null
  ok "stopped in ${SRC_LXC}: ${SRC_STOP_SERVICES}"
fi

# 2) dump of the source schema → host file (0600) → supabase-db /tmp/migr (written by the container's own user)
umask 077
src docker exec "$SRC_CONTAINER" pg_dump -U "$SRC_USER" -Fc --no-owner --no-acl -n "$SRC_SCHEMA" "$SRC_DB" </dev/null > "$T/src.dump"
[[ -s "$T/src.dump" ]] || die "empty dump"
ok "source dump: $(du -h "$T/src.dump" | cut -f1)"
src_counts </dev/null > "$T/src.counts"
dbx sh -c 'umask 077; mkdir -p /tmp/migr && cat > /tmp/migr/src.dump' < "$T/src.dump"
rm -f "$T/src.dump"

# 3) scratch database: restore without the schema entry, rename the schema, compare
dpsql postgres -c "DROP DATABASE IF EXISTS ${SCRATCH} WITH (FORCE)" -c "CREATE DATABASE ${SCRATCH}" </dev/null
dbx sh -c 'pg_restore -l /tmp/migr/src.dump | grep -v -E "^[0-9]+; [0-9]+ [0-9]+ (SCHEMA - |COMMENT - SCHEMA )" > /tmp/migr/src.list' </dev/null
dbx pg_restore -U supabase_admin -d "$SCRATCH" --no-owner --no-acl --exit-on-error -L /tmp/migr/src.list /tmp/migr/src.dump </dev/null
[[ "$SRC_SCHEMA" == "$SCHEMA" ]] || dpsql "$SCRATCH" -c "ALTER SCHEMA ${SRC_SCHEMA} RENAME TO ${SCHEMA}" </dev/null
dst_counts "$SCRATCH" </dev/null > "$T/scratch.counts"
compare "scratch ${SCRATCH}" "$T/src.counts" "$T/scratch.counts"
dbx sh -c "pg_dump -U supabase_admin -Fc --no-owner --no-acl -n ${SCHEMA} ${SCRATCH} > /tmp/migr/dst.dump && pg_restore -l /tmp/migr/dst.dump | grep -v -E '^[0-9]+; [0-9]+ [0-9]+ (SCHEMA - |COMMENT - SCHEMA )' > /tmp/migr/dst.list" </dev/null
ok "schema dump for the target: $(dbx sh -c 'grep -c " TABLE DATA " /tmp/migr/dst.list' </dev/null) tables with data"

if [[ "$MODE" == rehearse ]]; then
  echo ">> rehearse ok: nothing changed in ${SRC_LXC} nor in postgres.${SCHEMA}; scratch database and files removed"
  exit 0
fi

# 4) cutover: restore into postgres.<schema> as the app role, one transaction
dbx pg_restore -U supabase_admin -d postgres --role="$ROLE" --no-owner --no-acl --single-transaction --exit-on-error \
  -L /tmp/migr/dst.list /tmp/migr/dst.dump </dev/null
dst_counts postgres </dev/null > "$T/dst.counts"
compare "postgres.${SCHEMA}" "$T/src.counts" "$T/dst.counts"
owners="$(dpsql postgres -c "SELECT string_agg(DISTINCT pg_get_userbyid(c.relowner)::text, ',') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '${SCHEMA}'" </dev/null)"
[[ "$owners" == "$ROLE" ]] || die "objects in ${SCHEMA} owned by '${owners}', expected ${ROLE}"
ok "every object in ${SCHEMA} is owned by ${ROLE}"
cat <<EOT
>> cutover ok. ${SRC_LXC} is STOPPED (${SRC_STOP_SERVICES}); its old database is untouched (rollback = start it again).
   Next: put the app URL (role ${ROLE}) in ${SRC_LXC}:${SRC_APP_DIR}/.env and in the vault, then deploy the app.
EOT
REMOTE
} | ssh "${SSH_OPTS[@]}" "$HOST" 'f="$(mktemp /tmp/migrate_pg_schema.XXXXXX)"; cat > "$f"; bash "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc'

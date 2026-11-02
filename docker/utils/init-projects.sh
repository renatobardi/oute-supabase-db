#!/usr/bin/env bash
#
# Creates one schema per project in database `postgres`, with two roles (idempotent):
#   app_<schema>  owner of the schema (the application)      ro_<schema>  read-only (backup, queries)
# <schema> = <project with _>_<env>. Reads PG_PROJECTS from .env ("project:env1,env2 ...").
# Multi-schema tenants (PG_MULTISCHEMA, e.g. "backstage:prd"): one role app_<project>_<env> with CREATE on
# database postgres, no schema created here: the app creates its own (Backstage: one schema per plugin,
# backstage_<plugin>). No ro_ role: the lab dump (supabase_admin) covers them. See docs/DESIGN.md.
# Runs INSIDE the LXC, from docker/. Studio (role postgres) sees every schema.
#
#   ./utils/init-projects.sh                  # creates what is missing; existing roles untouched
#   ./utils/init-projects.sh --rotate [proj]  # new passwords (all, or one project)
#
# Passwords are printed once, never stored. Save them in the vault.

set -euo pipefail
cd "$(dirname "$0")/.."

ROTATE=0; ONLY=""
if [ "${1:-}" = "--rotate" ]; then ROTATE=1; ONLY="${2:-}"; fi

PG_PROJECTS="$(grep '^PG_PROJECTS=' .env | cut -d= -f2- | tr -d '"')"
PG_MULTISCHEMA="$({ grep '^PG_MULTISCHEMA=' .env || true; } | cut -d= -f2- | tr -d '"')"
[ -n "${PG_PROJECTS}" ] || { echo "ERROR: PG_PROJECTS empty in .env" >&2; exit 1; }

psqlx() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -qAt; }

ensure_role() { # <role> <project>
  local role="$1" project="$2" exists pass
  exists="$(psqlx <<<"SELECT 1 FROM pg_roles WHERE rolname='${role}';")"
  if [ -z "${exists}" ]; then
    pass="$(openssl rand -base64 32 | tr -d '/+=\n')"
    psqlx >/dev/null <<<"CREATE ROLE ${role} LOGIN PASSWORD '${pass}';"
  elif [ "${ROTATE}" -eq 1 ] && { [ -z "${ONLY}" ] || [ "${ONLY}" = "${project}" ]; }; then
    pass="$(openssl rand -base64 32 | tr -d '/+=\n')"
    psqlx >/dev/null <<<"ALTER ROLE ${role} PASSWORD '${pass}';"
  else
    return 0
  fi
  echo "schema=${schema} user=${role} pass=${pass}"
}

for entry in ${PG_PROJECTS}; do
  project="${entry%%:*}"
  envs="${entry#*:}"
  [ "${envs}" != "${entry}" ] || { echo "ERROR: '${entry}' has no environments (use project:prd,test)" >&2; exit 1; }
  for env in ${envs//,/ }; do
    schema="${project//-/_}_${env}"
    ensure_role "app_${schema}" "${project}"
    ensure_role "ro_${schema}" "${project}"
    psqlx >/dev/null <<SQL
CREATE SCHEMA IF NOT EXISTS ${schema} AUTHORIZATION app_${schema};
ALTER SCHEMA ${schema} OWNER TO app_${schema};
ALTER ROLE app_${schema} SET search_path = ${schema};
ALTER ROLE ro_${schema} SET search_path = ${schema};
GRANT USAGE ON SCHEMA ${schema} TO ro_${schema};
GRANT SELECT ON ALL TABLES IN SCHEMA ${schema} TO ro_${schema};
ALTER DEFAULT PRIVILEGES FOR ROLE app_${schema} IN SCHEMA ${schema} GRANT SELECT ON TABLES TO ro_${schema};
GRANT app_${schema} TO postgres WITH INHERIT TRUE;
SQL
  done
done

for entry in ${PG_MULTISCHEMA}; do
  project="${entry%%:*}"
  envs="${entry#*:}"
  [ "${envs}" != "${entry}" ] || { echo "ERROR: '${entry}' has no environments (use project:prd)" >&2; exit 1; }
  for env in ${envs//,/ }; do
    role="app_${project//-/_}_${env}"
    schema="${project//-/_}_*"   # only for the printed line; the app creates its schemas
    ensure_role "${role}" "${project}"
    psqlx >/dev/null <<SQL
GRANT CONNECT, CREATE ON DATABASE postgres TO ${role};
GRANT ${role} TO postgres WITH INHERIT TRUE;
SQL
  done
done

echo >&2
echo ">> Save the passwords above in the vault. They are not stored on disk." >&2

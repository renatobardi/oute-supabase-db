#!/usr/bin/env bash
#
# Creates one database per project with two roles (idempotent):
#   app_<db>  owner (the application)      ro_<db>  read-only (backup, queries)
# Reads PG_PROJECTS from .env ("project:env1,env2 ..."). Runs INSIDE the LXC, from docker/.
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
[ -n "${PG_PROJECTS}" ] || { echo "ERROR: PG_PROJECTS empty in .env" >&2; exit 1; }

psqlx() { docker exec -i supabase-db psql -U supabase_admin -d "$1" -v ON_ERROR_STOP=1 -qAt; }

ensure_role() { # <role> <project>
  local role="$1" project="$2" exists pass
  exists="$(psqlx postgres <<<"SELECT 1 FROM pg_roles WHERE rolname='${role}';")"
  if [ -z "${exists}" ]; then
    pass="$(openssl rand -base64 32 | tr -d '/+=\n')"
    psqlx postgres >/dev/null <<<"CREATE ROLE ${role} LOGIN PASSWORD '${pass}';"
  elif [ "${ROTATE}" -eq 1 ] && { [ -z "${ONLY}" ] || [ "${ONLY}" = "${project}" ]; }; then
    pass="$(openssl rand -base64 32 | tr -d '/+=\n')"
    psqlx postgres >/dev/null <<<"ALTER ROLE ${role} PASSWORD '${pass}';"
  else
    return 0
  fi
  echo "db=${db} user=${role} pass=${pass}"
}

for entry in ${PG_PROJECTS}; do
  project="${entry%%:*}"
  envs="${entry#*:}"
  [ "${envs}" != "${entry}" ] || { echo "ERROR: '${entry}' has no environments (use project:prd,test)" >&2; exit 1; }
  for env in ${envs//,/ }; do
    db="${project//-/_}_${env}"
    ensure_role "app_${db}" "${project}"
    ensure_role "ro_${db}" "${project}"
    exists="$(psqlx postgres <<<"SELECT 1 FROM pg_database WHERE datname='${db}';")"
    [ -n "${exists}" ] || psqlx postgres >/dev/null <<<"CREATE DATABASE ${db} OWNER app_${db};"
    psqlx postgres >/dev/null <<SQL
REVOKE CONNECT ON DATABASE ${db} FROM PUBLIC;
GRANT CONNECT ON DATABASE ${db} TO app_${db}, ro_${db};
SQL
    psqlx "${db}" >/dev/null <<SQL
REVOKE ALL ON SCHEMA public FROM PUBLIC;
ALTER SCHEMA public OWNER TO app_${db};
GRANT USAGE ON SCHEMA public TO ro_${db};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ro_${db};
ALTER DEFAULT PRIVILEGES FOR ROLE app_${db} IN SCHEMA public GRANT SELECT ON TABLES TO ro_${db};
SQL
  done
done

echo >&2
echo ">> Save the passwords above in the vault. They are not stored on disk." >&2

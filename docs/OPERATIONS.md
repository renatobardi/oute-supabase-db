# Operations (runbooks)

Prereqs: `ssh oute-server` without password; `lxc` without sudo. `ops/*` run on your Mac from the repo root and send the
**committed** `docker/` of HEAD (`git archive`): commit first.
Shorthand: `L="ssh oute-server lxc exec oute-supabase-db --"`.

> Trap: `lxc exec` eats stdin. In scripts use `</dev/null` on `lxc exec` calls that need no input.

## 1. Provision / update
```sh
./ops/provision_lxc.sh --check   # read-only preconditions
./ops/provision_lxc.sh           # create/update, up, init, verify isolation
```
Save the printed secrets in the vault (shown once).

## 2. Health
```sh
ssh oute-server 'lxc list oute-supabase-db -c ns4 -f csv'
ssh oute-server 'lxc exec oute-supabase-db -- docker compose -f /opt/oute-supabase-db/docker/docker-compose.yml ps'
ssh oute-server 'lxc exec oute-supabase-db -- nft list chain inet oute_pgdb pgdb_forward'   # drop counter
```

## 3. Studio / psql
Studio: https://db-console.oute.pro (tailnet only; user `supabase`, password `DASHBOARD_PASSWORD` from the vault).
It shows every project schema (database `postgres`).
From the Mac, `./ops/admin_tunnel.sh` gives Studio on http://localhost:8000 and Postgres on `localhost:5433`
(`psql "postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5433/postgres"`). It is the fallback if the vhost is down.

## 4. Connect an app
`DATABASE_URL=postgresql://app_<schema>:<pass>@10.173.117.51:5433/postgres` (the role's `search_path` is already its schema). The app's LXC **must be in the client list** (section 5),
otherwise the connection times out and the nft drop counter rises.

## 5. Add a client project (new authorized IP)
1. Fixed IP of the project LXC (`ssh oute-server 'lxc list -c n4 -f csv'`).
2. Add it to `PG_CLIENT_IPS` default in `ops/provision_lxc.sh` and commit (PR).
3. `./ops/provision_lxc.sh` (reapplies firewall, tests the negative).

## 6. Add a project/schema
1. Add `project:env` to `PG_PROJECTS` in `docker/.env.example` (docs) and in the LXC `.env`:
   `ssh -t oute-server 'lxc exec oute-supabase-db -- vi /opt/oute-supabase-db/docker/.env'`.
2. `ssh oute-server 'lxc exec oute-supabase-db -- bash -c "cd /opt/oute-supabase-db/docker && ./utils/init-projects.sh"' </dev/null`
   (creates only what is missing; new passwords printed once).

## 7. Credentials
Rotate a project: same command with `--rotate <project>`; update the app and the vault. This rotates **both** `app_<schema>` and
`ro_<schema>` of that project; the new passwords are printed once.
Postgres admin / dashboard password live only in the LXC `.env` and the vault.

To hand a rotated URL to the vault without it passing through a chat or a log, run the rotation from a small local script (under the
git-ignored `scripts/ops/`) that parses the `schema=... user=... pass=...` line, builds
`postgresql://app_<schema>:<pass>@10.173.117.51:5433/postgres` and puts it on the clipboard (or shows it only on your own terminal and
clears the screen). Save it as a Login in Vaultwarden named `<app-lxc> <ENV_VAR>` with the URL in the password field; the lab's
secrets helper for the app then writes it into the app's `.env`. Check the item name for stray spaces: the helper matches it exactly.

## 8. Backup and restore
**What is backed up** (lab `backup-all.sh`, restic, `strategy: pg_dump`, inventory entry `oute-supabase-db`):
- `pg_dump -Fc` of database `postgres` **keeping owners and grants** (`pg_dump_args: ""`), run as `supabase_admin`: every project schema, Auth, Storage metadata.
- Docker volume `supabase_db-config`: the **pgsodium root key**. Without it Vault secrets in Postgres are unrecoverable.
- `volumes/storage` (uploaded files) and `volumes/functions`.
- `/var/backups/oute-supabase-db`: a copy of `.env` (JWT secret, encryption keys), refreshed by every `./ops/provision_lxc.sh` run.
  After editing the LXC `.env` by hand, re-run the provision (or copy it) so the backup sees the change.

This matches what Supabase documents for self-hosting: no automatic backup is shipped; the guide asks for `pg_dump`/`pg_dumpall` plus
the `db-config` volume (pgsodium key) and the storage files. The hosted platform's physical backup + WAL (PITR) is not part of self-host.

**Before a migration:** `pg_dump` of the schema (below), plus an LXC snapshot only if you really want one.
```sh
ssh oute-server 'lxc exec oute-supabase-db -- docker exec supabase-db pg_dump -U supabase_admin -Fc -n <schema> postgres' > <schema>.dump
```

**Restore test (done 2026-10-19, repeat after changes to the backup):** dump with owners/grants, restore into a scratch database, check a canary row,
its owner and the read-only grant, drop the scratch database:
```sh
docker exec -i supabase-db pg_dump -U supabase_admin -Fc postgres > x.dump
docker exec supabase-db psql -U supabase_admin -d postgres -c "CREATE DATABASE restore_test TEMPLATE template0"
docker exec -i supabase-db pg_restore -U supabase_admin -d restore_test --no-comments < x.dump
# verify, then: DROP DATABASE restore_test
```
Result: `pg_restore` rc 0, 0 errors, canary row present, owner `app_<schema>` kept, `ro_<schema>` SELECT kept, all schemas present.

**Disaster recovery (new LXC):** run the provision, stop the stack, restore `db-config` and `.env` first, start `db`, then `pg_restore --clean --if-exists -d postgres`
from the restic dump, then bring the rest up. Role passwords are in the dump's owners/grants only by name: rotate with `init-projects.sh --rotate`.

> Trap: the LXD pool `oute-pool` is `dir`, so `lxc snapshot` of this running LXC copies the whole rootfs and freezes it for the
> duration (minutes). Interrupting it leaves the LXC `FROZEN` (`lxc start oute-supabase-db` thaws it). Prefer `pg_dump` for data;
> take an LXC snapshot only on purpose, and let it finish (run it detached, not under a short timeout).

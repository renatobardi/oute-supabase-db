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

## 3. Studio / psql from the Mac
`./ops/admin_tunnel.sh` then open http://localhost:8000 (user/password `DASHBOARD_*`), or
`psql "postgresql://postgres:<POSTGRES_PASSWORD>@localhost:5433/postgres"`.

## 4. Connect an app
`DATABASE_URL=postgresql://app_<db>:<pass>@10.173.117.51:5433/<db>`. The app's LXC **must be in the client list** (section 5),
otherwise the connection times out and the nft drop counter rises.

## 5. Add a client project (new authorized IP)
1. Fixed IP of the project LXC (`ssh oute-server 'lxc list -c n4 -f csv'`).
2. Add it to `PG_CLIENT_IPS` default in `ops/provision_lxc.sh` and commit (PR).
3. `./ops/provision_lxc.sh` (reapplies firewall, tests the negative).

## 6. Add a project/database
1. Add `project:env` to `PG_PROJECTS` in `docker/.env.example` (docs) and in the LXC `.env`:
   `ssh -t oute-server 'lxc exec oute-supabase-db -- vi /opt/oute-supabase-db/docker/.env'`.
2. `ssh oute-server 'lxc exec oute-supabase-db -- bash -c "cd /opt/oute-supabase-db/docker && ./utils/init-projects.sh"' </dev/null`
   (creates only what is missing; new passwords printed once).

## 7. Credentials
Rotate a project: same command with `--rotate <project>`; update the app and the vault.
Postgres admin / dashboard password live only in the LXC `.env` and the vault.

## 8. Snapshot and dump
```sh
ssh oute-server 'lxc snapshot oute-supabase-db <name>'
ssh oute-server 'lxc exec oute-supabase-db -- docker exec supabase-db pg_dump -U supabase_admin -Fc <db>' > <db>.dump
```
Take both before each app migration.

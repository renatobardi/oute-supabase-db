# Design

## Goal
One isolated Supabase self-hosted stack for the Oute projects that need Postgres (and, later, Auth/REST/Storage),
instead of SQLite files per app. Companion of [oute-surreal-db](https://github.com/renatobardi/oute-surreal-db),
same house pattern: one LXC per stack on `oute-server`, firewall inside the LXC, repo as source of truth.

## Scope

| Project | Today | Plan |
|---|---|---|
| financial-control | SQLite (1.4 MB) | pilot 1: own database |
| frentes-engenharia | SQLite (123 MB) | pilot 2: own database |
| hanko | Postgres 17 own container (~1.1 GB) | pilot 3: own database, only `HANKO_DATABASE_URL` changes |
| kubo, obo | → oute-surreal-db | out |
| oute-agent, vaultwarden, studio | out | out (ADR-08 / isolated vault / discontinued Oute project) |

"studio" in scope notes is the discontinued Oute project, **not** Supabase Studio (which is part of this stack).

## Topology
- LXC `oute-supabase-db` on `lxdbr0` (`10.173.117.0/24`), IP `10.173.117.51`, 3 CPU, 6 GiB, nesting, autostart, snapshots 7d.
- Inside: `docker.io` + compose v2; stack in `/opt/oute-supabase-db/docker` (upstream `docker/`, full: Studio, Auth, REST,
  Realtime, Storage, imgproxy, Meta, Edge Functions, Supavisor, Envoy gateway, Logflare + Vector).
- `COMPOSE_FILE=docker-compose.yml:docker-compose.logs.yml:docker-compose.oute.yml`. Images are pinned by upstream tags.
- Source is an upstream snapshot (see `UPSTREAM.md`); the variant adds only `docker-compose.oute.yml`,
  `utils/init-projects.sh`, `ops/`, `docs/`.

## Data model: one database per project
Supabase's own services (Auth, Storage, Realtime, Studio) live in database `postgres` and assume one project.
So each Oute project gets its **own database** on the same Postgres, and `postgres` stays reserved for the
Supabase services and for **the one app that will use Auth/REST/Storage/Realtime** (not decided yet; decided when
reading each app's code for the migration issues).

| Dimension | Convention |
|---|---|
| Database | `<project with _>_<env>` e.g. `financial_control_prd`. Only existing envs (`PG_PROJECTS` in `.env`) |
| Roles | `app_<db>` owner of the database and of schema `public`; `ro_<db>` SELECT only (backup, queries). No superuser/createdb |
| Isolation | `CONNECT` revoked from PUBLIC on each project database; a role connects only to its own database |
| Access | Apps connect **directly** to Postgres on `10.173.117.51:5433` (override publishes `db`). The pooler (5432/6543) is tenant-bound to `postgres`, so it is not used for project databases |
| Env vars in apps | `DATABASE_URL=postgresql://app_<db>:<pass>@10.173.117.51:5433/<db>` (hanko: `HANKO_DATABASE_URL`) |
| Vault | `oute-supabase-db/postgres`, `oute-supabase-db/dashboard`, `oute-supabase-db/<db>/<role>` |

Residual: project roles can `CONNECT` to `postgres` (default PUBLIC grant, kept so Supabase services keep working)
but have no privilege on any schema there (tested: `auth`, `storage`, `vault` denied); they only see catalog metadata.

## Network isolation
Same finding as oute-surreal-db: host Docker containers reach LXC IPs; LXD ACL is unavailable on bridge NICs.
- nft table `inet oute_pgdb` (hook forward) inside the LXC: only client LXC IPs reach ports `5432, 5433, 6543` and `8000`.
- Clients today: `10.173.117.42` (financial-control-prd), `.41` (frentes-engenharia-prd), `.43` (hanko-prd).
- **Exception:** the host (`10.173.117.1`) may reach `8000` only, so the host nginx can publish Studio. Postgres ports stay closed to it.
  Host Docker containers are masqueraded as the same IP, so they can also reach the gateway on `8000` (dashboard login and API keys
  are still required; they cannot reach any project database). Tracked for a uniform fix in renatobardi/lab#285.
- `provision_lxc.sh` tests on every run: clients reach 5433; vaultwarden is blocked on 5433 and 8000; host Docker networks are blocked on 5433;
  the host reaches the gateway; exit 2 if anything leaks.

## Access
- **Studio:** `https://db-console.oute.pro`, tailnet only (`100.66.254.24:443`, host nginx vhost + certbot, lab#286, ADR-0001).
  The vhost proxies the whole Envoy gateway, so `/rest/v1`, `/auth/v1`, `/storage/v1`, `/realtime/v1` and `/pg/` share the name (API keys required).
  Vhost, deploy script and tests live in `renatobardi/lab` (`servers/oute-server/nginx/db-console.oute.pro`).
- `SUPABASE_PUBLIC_URL` / `API_EXTERNAL_URL` = `https://db-console.oute.pro` (Envoy CORS and Studio links use it).
- **Fallback / psql from the Mac:** LXD proxy devices bind the host loopback (`18000`→8000, `15433`→5433);
  `ops/admin_tunnel.sh` forwards them over ssh (`localhost:8000` is still allowed by CORS).

## Secrets
Generated inside the LXC (`utils/generate-keys.sh`, `add-new-auth-keys.sh`); `.env` is `600`, never in git. Shown once by the
provision script (postgres, dashboard) and by `init-projects.sh` (project roles). Saved in Vaultwarden.

## Decisions (2026-10-19)
1. Start from a **snapshot of upstream `master`** (no history, not a fork) to keep all Supabase capabilities.
2. LXC per stack; full stack on; database per project; direct Postgres access; Studio at `db-console.oute.pro` (tailnet only), tunnel as fallback.
3. Migrations of each app are tracked as issues **in each app's repo**, not here.
4. Backup: LXC snapshot for now; policy and `pg_dump` later (open).

## Risks
| Risk | Mitigation |
|---|---|
| Full stack uses RAM (Logflare, Realtime, Studio) on a 23 GiB host shared with other LXCs | LXC `limits.memory=6GiB`; measure after boot; logs override can be dropped from `COMPOSE_FILE` |
| Upstream drift | `UPSTREAM.md` records the base commit; diff against upstream `docker/` by hand |
| Crash-consistent snapshots only | `pg_dump` per database before each migration (runbook) |
| Allowlist of client IPs needs upkeep | Runbook "Add a client project" |

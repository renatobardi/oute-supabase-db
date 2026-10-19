# Design

## Goal
One isolated Supabase self-hosted stack for the Oute projects that need Postgres (and, later, Auth/REST/Storage),
instead of SQLite files per app. Companion of [oute-surreal-db](https://github.com/renatobardi/oute-surreal-db),
same house pattern: one LXC per stack on `oute-server`, firewall inside the LXC, repo as source of truth.

## Scope

| Project | Today | Plan |
|---|---|---|
| financial-control | SQLite (1.4 MB) | pilot 1: own schema |
| frentes-engenharia | SQLite (123 MB) | pilot 2: own schema |
| hanko | Postgres 17 own container (~1.1 GB) | pilot 3: own schema, only `HANKO_DATABASE_URL` changes |
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

## Data model: one schema per project, in `postgres`
oute-supabase-db is a **shared piece**, not a project's database. All projects live in database `postgres`, one **schema** each, so Studio
(and Auth, REST, Storage, Realtime, the pooler) see and serve all of them. A project that wants the Supabase platform (Auth, REST, Storage,
Realtime) just uses it; none of the three current apps needs it yet.

| Dimension | Convention |
|---|---|
| Schema | `<project with _>_<env>` e.g. `financial_control_prd`. Only existing envs (`PG_PROJECTS` in `.env`) |
| Roles | `app_<schema>` owns the schema; `ro_<schema>` SELECT only (backup, queries). No superuser/createdb; `search_path` fixed to the schema |
| Isolation | A role has no privilege on any other project schema, on `public`, or on Supabase schemas (`auth`, `storage`, `vault`...). It sees catalog metadata only (tested) |
| Studio | Connects as role `postgres`, which is a member of every `app_<schema>`, so it sees and edits all project schemas |
| Access | Apps connect to database `postgres` as their `app_<schema>` role: directly on `10.173.117.51:5433`, or through the pooler (5432 session, 6543 transaction) |
| REST/Realtime | `PGRST_DB_SCHEMAS` stays `public,graphql_public`: a project schema is **not** exposed over REST until that project opts in (add the schema and grants for `anon`/`authenticated`) |
| `auth.users` | Shared by every project that uses Supabase Auth (accepted: the stack is one shared platform) |
| Env vars in apps | `DATABASE_URL=postgresql://app_<schema>:<pass>@10.173.117.51:5433/postgres` (hanko: `HANKO_DATABASE_URL`) |
| Vault | `oute-supabase-db/postgres`, `oute-supabase-db/dashboard`, `oute-supabase-db/<schema>/<role>` |

History: the first cut used one database per project. It was dropped (2026-10-19) because Studio only manages `postgres`, which left the
published console blind to the project data; the roles and their passwords were kept.

## Network isolation
Same finding as oute-surreal-db: host Docker containers reach LXC IPs; LXD ACL is unavailable on bridge NICs.
- nft table `inet oute_pgdb` (hook forward) inside the LXC: only client LXC IPs reach ports `5432, 5433, 6543` and `8000`.
- Clients today: `10.173.117.42` (financial-control-prd), `.41` (frentes-engenharia-prd), `.43` (hanko-prd).
- **Exception:** the host (`10.173.117.1`) may reach `8000` only, so the host nginx can publish Studio. Postgres ports stay closed to it.
  Host Docker containers share that source IP, but the **host forward rule** (renatobardi/lab ADR 0006, `table inet oute_isolation`,
  applied 2026-10-19) drops their traffic towards `lxdbr0`, so they cannot use the exception. The host's own processes (nginx) are unaffected.
- `provision_lxc.sh` tests on every run: clients reach 5433; vaultwarden is blocked on 5433 and 8000; host Docker networks are blocked on 5433 and 8000;
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
2. LXC per stack; full stack on; schema per project in `postgres`; direct Postgres access; Studio at `db-console.oute.pro` (tailnet only), tunnel as fallback.
3. Migrations of each app are tracked as issues **in each app's repo**, not here.
4. Backup: lab restic `pg_dump` of `postgres` (owners kept) + `db-config` volume + storage + functions + `.env` copy; restore tested 2026-10-19 (OPERATIONS §8).

## Risks
| Risk | Mitigation |
|---|---|
| Full stack uses RAM (Logflare, Realtime, Studio) on a 23 GiB host shared with other LXCs | LXC `limits.memory=6GiB`; measure after boot; logs override can be dropped from `COMPOSE_FILE` |
| Upstream drift | `UPSTREAM.md` records the base commit; diff against upstream `docker/` by hand |
| Crash-consistent snapshots only | `pg_dump` per database before each migration (runbook) |
| Allowlist of client IPs needs upkeep | Runbook "Add a client project" |

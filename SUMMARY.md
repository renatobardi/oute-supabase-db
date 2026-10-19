# oute-supabase-db — project state

Two isolated stacks on `oute-server`, each in its own LXC on `lxdbr0` (house pattern):

| Stack | Repo | Projects |
|---|---|---|
| oute-surreal-db | `renatobardi/oute-surreal-db` | kubo, obo |
| **oute-supabase-db** | this | financial-control, frentes-engenharia, hanko |

Out of scope: oute-agent (ADR-08), vaultwarden (isolated SQLite), studio (discontinued Oute project; not Supabase Studio).

## Decisions (2026-10-19)
- Repo = snapshot of upstream `master` (no history, not a fork; recreated on GitHub), all Supabase capabilities kept. Base commit in `UPSTREAM.md`.
- Full stack on (Studio, Auth, REST, Realtime, Storage, Functions, Pooler, Logs). One database per project; `postgres` reserved for Supabase services and for the one app that will use Auth/REST/Storage (open).
- Details, isolation and conventions: `docs/DESIGN.md`. Runbooks: `docs/OPERATIONS.md`.
- App migrations (SQLite → Postgres) are issues **in each app's repo**, written after the server is up and after reading each app's code.
- Pilots: financial-control → frentes-engenharia → hanko (only `HANKO_DATABASE_URL`).

## Open
- Which app owns database `postgres` (and uses Auth/REST/Storage/Realtime).
- Backup policy (LXC snapshot now; `pg_dump` schedule later).
- RAM check of the full stack after first boot (LXC limit 6 GiB; logs override can be dropped).

## Phases
1. Repo from upstream snapshot ✔
2. Provisioning code + docs (`ops/`, `docker/utils/init-projects.sh`, `docs/`) — branch `feat/provision-lxc`
3. Apply on the server (LXC `10.173.117.51`), verify isolation, snapshot
4. Issues in each app's repo (code read first)
5. Pilot migrations, then backup policy

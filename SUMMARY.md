# oute-supabase-db — project state

Two isolated stacks on `oute-server`, each in its own LXC on `lxdbr0` (house pattern):

| Stack | Repo | Projects |
|---|---|---|
| oute-surreal-db | `renatobardi/oute-surreal-db` | kubo, obo |
| **oute-supabase-db** | this | financial-control, frentes-engenharia, hanko |

Out of scope: oute-agent (ADR-08), vaultwarden (isolated SQLite), studio (discontinued Oute project; not Supabase Studio).

## Decisions (2026-10-19)
- Repo = snapshot of upstream `master` (no history, not a fork; recreated on GitHub), all Supabase capabilities kept. Base commit in `UPSTREAM.md`.
- Full stack on (Studio, Auth, REST, Realtime, Storage, Functions, Pooler, Logs). One **schema per project** in database `postgres` (shared platform: Studio sees all; Auth/REST/Storage available to any project that opts in).
- Studio published at `https://db-console.oute.pro`, tailnet only (vhost in `renatobardi/lab`, issue lab#286); host allowed on :8000 only; host Docker containers are blocked towards every LXC by the host forward rule (lab ADR 0006, #285).
- Details, isolation and conventions: `docs/DESIGN.md`. Runbooks: `docs/OPERATIONS.md`.
- App migrations (SQLite → Postgres) are issues **in each app's repo**, written after the server is up and after reading each app's code.
- Pilots: financial-control → frentes-engenharia → hanko (only `HANKO_DATABASE_URL`).
- **Pilot 1 done (2026-10-24):** financial-control runs on schema `financial_control_prd` (renatobardi/financial-control#68, ADR-0004 there). Cutover tested by the owner, SQLite and its restic snapshots removed. Lessons for the next two: money columns must be `BIGINT`; a constraint violation aborts the transaction, so catch sites roll back; rehearse the data copy on a consistent copy of the real database (it found a bug the unit tests did not); the app's `.env` gets the role URL from the vault through the lab's secrets helper before the deploy.
- **Pilot 2 done (2026-10-25):** frentes-engenharia runs on schema `frentes_engenharia_prd` (renatobardi/frentes-engenharia#162, ADR-0002 there). 19,107 rows copied and compared one by one, cutover tested by the owner, SQLite volume removed. New lesson: this server returns `double precision` with 15 digits (`extra_float_digits` below 3), so a rehearsal against the real database flagged diffs the local Postgres never showed; clients should ask for `extra_float_digits=3`. The app role password was rotated once (shown once, saved to the vault).

## Open
- **hanko** (pilot 3) is on hold at the owner's request; schema `hanko_prd` and its roles exist, no app uses them yet.
- Both migrated apps are covered by the weekly lab dump of `oute-supabase-db` (Saturdays 02:00 UTC); their own inventory entries are `backup: none` with a note pointing here.
- RAM check of the full stack under real load (LXC limit 6 GiB; logs override can be dropped).

## Phases
1. Repo from upstream snapshot ✔
2. Provisioning code + docs (`ops/`, `docker/utils/init-projects.sh`, `docs/`) ✔
3. Apply on the server (LXC `10.173.117.51`), verify isolation ✔
4. Issues in each app's repo (code read first): financial-control ✔ (#68), frentes-engenharia ✔ (#162), hanko pending
5. Pilot migrations: financial-control ✔, frentes-engenharia ✔, hanko on hold. Backup policy ✔ (lab restic, restore tested)
6. Client conventions from the pilots: `docs/DESIGN.md`, "Client conventions"

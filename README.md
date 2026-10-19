# oute-supabase-db

Own variant of [supabase/supabase](https://github.com/supabase/supabase) (Apache-2.0, see `LICENSE`).
Single snapshot of upstream `master`, no history, not a fork. Exact origin in `UPSTREAM.md`.

Runs the self-hosted Supabase stack of the Oute projects (financial-control, frentes-engenharia, hanko) in its own LXC on
`oute-server`, one schema per project in `postgres`. Companion of [oute-surreal-db](https://github.com/renatobardi/oute-surreal-db).

**This repo is the source of truth** for the deployment: if the server diverges, the server is wrong (or this repo needs a PR).

| I need to… | Go to |
|---|---|
| Understand the design | [`docs/DESIGN.md`](docs/DESIGN.md) |
| Operate (provision, connect an app, add project/client, rotate, dump) | [`docs/OPERATIONS.md`](docs/OPERATIONS.md) |
| Current state / memory between sessions | [`SUMMARY.md`](SUMMARY.md) |

| Path | Role |
|---|---|
| `docker/` | Upstream self-host stack + `docker-compose.oute.yml` (direct Postgres) + `utils/init-projects.sh` |
| `ops/provision_lxc.sh` | Runs on the Mac: creates/updates the LXC, firewall, stack, init, verifies isolation. `--check` is read-only |
| `ops/admin_tunnel.sh` | Runs on the Mac: Studio on `localhost:8000`, Postgres on `localhost:5433` |
| everything else | Upstream monorepo snapshot, untouched |

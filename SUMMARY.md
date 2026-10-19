# oute-supabase-db — estado do projeto

## Decisões (2026-10-18)
- Repo próprio, só `docker/` + nossos arquivos (reset do fork do monorepo; histórico anterior fica no git).
- Roda em **LXC próprio** na `lxdbr0` (padrão da casa), isolado do oute-surreal-db: sem porta no host, sem conflito de 8000.
- Projetos: **hanko** (app próprio, já Postgres: só troca `HANKO_DATABASE_URL`), **frentes-engenharia** e **financial-control** (SQLite → Postgres).
- Fora: oute-agent (ADR-08), vaultwarden (cofre isolado em SQLite), studio (descontinuado).
- Pilotos, nesta ordem: financial-control (1,4 MB) → frentes-engenharia (123 MB) → hanko.
- Backup: snapshot do LXC (política na fase final).

## Pendente
- Assessment de RAM/disco para o LXC (stack ~3–4 GB; host tem ~13 GB livres).
- Decidir quais serviços ligar (logs/Logflare, Edge Functions, Storage) — começar enxuto.
- Adaptar compose ao nosso gosto (`.env.example`, portas, limites, versões fixadas).
- Esquema de roles/databases por projeto no Postgres (um schema ou database por projeto).
- `docker/update.sh` aponta para o upstream: decidir se mantém ou remove.

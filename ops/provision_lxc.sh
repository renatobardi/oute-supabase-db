#!/usr/bin/env bash
#
# provision_lxc.sh — creates/updates the oute-supabase-db LXC on oute-server and brings the Supabase stack up.
# Runs on the Mac; everything on the server goes through ssh. No sudo.
#
#   ./ops/provision_lxc.sh --check   # preconditions only (changes nothing)
#   ./ops/provision_lxc.sh           # create/update and verify
#
# Idempotent: re-running reapplies the firewall, refreshes docker/ in the LXC, brings compose up and runs
# the project init (existing .env, roles and data are kept).
# Sends the COMMITTED docker/ of HEAD (git archive): commit before running.
#
# Isolation: nft firewall INSIDE the LXC (own table; only the listed clients reach the DB/API ports).
# Needed because Docker containers on the HOST reach LXC IPs (measured 2026-10-18); they arrive masqueraded
# as the lxdbr0 IP (10.173.117.1), which is not on the list. Same design as oute-surreal-db.
# Admin access (Studio, psql) goes through LXD proxy devices bound to the HOST loopback + ssh tunnel
# (ops/admin_tunnel.sh); never through the lxdbr0 IP.
# Secrets: generated inside the LXC (.env, 600), shown ONCE at the end; save them in the vault.

set -euo pipefail

HOST="${OUTE_HOST:-oute-server}"
NAME="${LXC_NAME:-oute-supabase-db}"
IP="${LXC_IP:-10.173.117.51}"
LXC_CPU="${LXC_CPU:-3}"
LXC_MEM="${LXC_MEM:-6GiB}"
# Authorized clients (project LXC IPs): financial-control-prd, frentes-engenharia-prd, hanko-prd.
CLIENTS="${PG_CLIENT_IPS:-10.173.117.42 10.173.117.41 10.173.117.43}"
POS_LXC="${POS_LXC:-financial-control-prd}"   # must reach
NEG_LXC="${NEG_LXC:-vaultwarden}"             # must NOT reach (not on the list)
PORTS="5432, 5433, 6543, 8000"                # pooler session, direct pg, pooler transaction, API gateway
TEST_PORT=5433
REMOTE_DIR=/opt/oute-supabase-db
PUBLIC_URL="http://localhost:8000"            # reached via ssh tunnel; change when exposing

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
r() { ssh "${SSH_OPTS[@]}" "${HOST}" "$@"; }
x() { r "lxc exec ${NAME} -- bash -s"; }

ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
die()  { printf '  [ERROR] %s\n' "$*" >&2; exit 1; }

echo ">> Pre-checks"
r true 2>/dev/null || die "no ssh to '${HOST}'"
ok "ssh ${HOST}"
for c in ${CLIENTS}; do r "lxc list -c 4 -f csv | grep -q '^${c} '" || warn "client ${c} not found in any LXC"; done
EXISTS=0; r "lxc info ${NAME} >/dev/null 2>&1" && EXISTS=1
if [ "${EXISTS}" -eq 0 ]; then
  r "lxc list -c n4 -f csv | grep '${IP} '" >/dev/null 2>&1 && die "IP ${IP} already used by another LXC"
  ok "IP ${IP} free; LXC ${NAME} does not exist yet (will be created)"
else
  ok "LXC ${NAME} already exists (will be updated)"
fi
for l in "${POS_LXC}" "${NEG_LXC}"; do r "lxc info ${l} >/dev/null 2>&1" || die "test LXC '${l}' does not exist"; done
ok "test LXCs: ${POS_LXC} (positive), ${NEG_LXC} (negative)"
AVAIL="$(r "free -m | awk '/^Mem:/{print \$7}'")"
[ "${AVAIL}" -gt 7000 ] && ok "available host RAM: ${AVAIL} MiB" || warn "low available RAM (${AVAIL} MiB) for ${LXC_MEM}"
DISK="$(r "lxc storage info oute-pool | awk '/total space/{t=\$3} /space used/{u=\$3} END{print t\" total, \"u\" used\"}'")"
ok "pool oute-pool: ${DISK}"
[ -z "$(git -C "${REPO_DIR}" status --porcelain)" ] || warn "uncommitted changes in repo: only the HEAD docker/ is sent"
[ "${CHECK_ONLY}" -eq 1 ] && { echo ">> --check done; nothing changed."; exit 0; }

echo ">> LXC ${NAME}"
if [ "${EXISTS}" -eq 0 ]; then
  r "lxc init ubuntu:24.04 ${NAME} -c security.nesting=true -c boot.autostart=true -c limits.cpu=${LXC_CPU} -c limits.memory=${LXC_MEM} -c snapshots.expiry=7d"
  ok "LXC created"
fi
r "lxc config set ${NAME} security.nesting=true boot.autostart=true limits.cpu=${LXC_CPU} limits.memory=${LXC_MEM} snapshots.expiry=7d"
CUR_IP="$(r "lxc config device get ${NAME} eth0 ipv4.address 2>/dev/null || true")"
if [ "${CUR_IP}" != "${IP}" ]; then
  r "lxc config device override ${NAME} eth0 ipv4.address=${IP} 2>/dev/null || lxc config device set ${NAME} eth0 ipv4.address=${IP}"
fi
ok "fixed IP ${IP}"
# Admin: host-loopback proxies (Studio/API gateway and direct Postgres); see ops/admin_tunnel.sh
r "lxc config device show ${NAME} | grep -q '^admin_api:'" </dev/null || r "lxc config device add ${NAME} admin_api proxy listen=tcp:127.0.0.1:18000 connect=tcp:127.0.0.1:8000"
r "lxc config device show ${NAME} | grep -q '^admin_pg:'" </dev/null || r "lxc config device add ${NAME} admin_pg proxy listen=tcp:127.0.0.1:15433 connect=tcp:127.0.0.1:5433"
ok "admin proxy devices on host loopback (18000 -> 8000, 15433 -> 5433)"
r "lxc info ${NAME} | grep -q '^Status: RUNNING'" || { r "lxc start ${NAME}"; ok "LXC started"; }

echo ">> Waiting for LXC boot/network"
r "lxc exec ${NAME} -- cloud-init status --wait >/dev/null 2>&1 || true"
x <<'EOS'
for i in $(seq 1 30); do getent hosts archive.ubuntu.com >/dev/null 2>&1 && exit 0; sleep 2; done
echo "no DNS/network in LXC" >&2; exit 1
EOS
ok "LXC network ok"

echo ">> Docker in the LXC (house standard: docker.io + compose v2, dns 1.1.1.1)"
x <<EOS
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 curl openssl >/dev/null
fi
mkdir -p /etc/docker
[ -f /etc/docker/daemon.json ] || echo '{"dns":["1.1.1.1","1.0.0.1"]}' > /etc/docker/daemon.json
systemctl enable --now docker >/dev/null 2>&1
mkdir -p ${REMOTE_DIR}
docker --version
EOS

echo ">> Firewall in the LXC (nft): only ${CLIENTS} -> ${PORTS}"
CLIENTS_CSV="$(echo "${CLIENTS}" | sed 's/ /, /g')"
x <<EOS
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
command -v nft >/dev/null 2>&1 || apt-get install -y -qq nftables >/dev/null
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
# Generated by ops/provision_lxc.sh. Own table: does not touch Docker rules.
NFT
cat >> /etc/nftables.conf <<NFT
add table inet oute_pgdb
delete table inet oute_pgdb
table inet oute_pgdb {
  chain pgdb_forward {
    type filter hook forward priority -10; policy accept;
    iifname "eth0" tcp dport { ${PORTS} } ip saddr != { ${CLIENTS_CSV} } counter drop
  }
}
NFT
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1
nft list table inet oute_pgdb
EOS
ok "firewall applied and persisted (/etc/nftables.conf)"

echo ">> Sending docker/ (committed HEAD)"
git -C "${REPO_DIR}" archive --format=tar HEAD docker | r "lxc exec ${NAME} -- tar -x -C ${REMOTE_DIR}"
ok "docker/ in ${REMOTE_DIR}"

echo ">> .env"
FIRST_ENV_OUT="$(x <<EOS
set -euo pipefail
cd ${REMOTE_DIR}/docker
if [ ! -f .env ]; then
  cp .env.example .env
  sed -i -e "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=${PUBLIC_URL}|" \
         -e "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=${PUBLIC_URL}/auth/v1|" .env
  sh utils/generate-keys.sh --update-env >/dev/null
  sh utils/add-new-auth-keys.sh --update-env >/dev/null
  chmod 600 .env
  echo "NEW"
  grep -E '^(POSTGRES_PASSWORD|DASHBOARD_USERNAME|DASHBOARD_PASSWORD)=' .env
fi
EOS
)"
case "${FIRST_ENV_OUT}" in NEW*) ok ".env created (600) with new secrets";; *) ok ".env already existed (kept)";; esac

echo ">> Compose up (pulls images; may take several minutes)"
x <<EOS
set -euo pipefail
cd ${REMOTE_DIR}/docker
docker compose pull --quiet
docker compose up -d --wait --wait-timeout 600 >/dev/null
docker compose ps --format '{{.Name}} {{.Status}}'
EOS
ok "stack healthy"

echo ">> Init (databases/roles per project) — passwords below, ONCE:"
echo "------------------------------------------------------------------"
x <<EOS 2>&1
cd ${REMOTE_DIR}/docker && ./utils/init-projects.sh
EOS
case "${FIRST_ENV_OUT}" in NEW*) echo "${FIRST_ENV_OUT}" | tail -n +2;; esac
echo "------------------------------------------------------------------"

echo ">> Isolation check"
FAIL=0
reach() { # <lxc> -> REACHES|BLOCKED
  r "lxc exec $1 -- timeout 5 bash -c 'exec 3<>/dev/tcp/${IP}/${TEST_PORT}'" </dev/null >/dev/null 2>&1 && echo REACHES || echo BLOCKED
}
res="$(reach "${POS_LXC}")"; [ "${res}" = REACHES ] && ok "${POS_LXC} -> ${IP}:${TEST_PORT}: reaches (expected)" || { warn "${POS_LXC} does NOT reach (expected to reach)"; FAIL=1; }
res="$(reach "${NEG_LXC}")"; [ "${res}" = BLOCKED ] && ok "${NEG_LXC} (not listed): blocked (expected)" || { warn "${NEG_LXC} REACHES the database (expected blocked)"; FAIL=1; }
for net in bridge oute-agent_oute; do
  res="$(r "docker run --rm --network ${net} alpine sh -c 'nc -z -w 4 ${IP} ${TEST_PORT} && echo REACHES || echo BLOCKED' 2>/dev/null | tail -1")"
  [ "${res}" = BLOCKED ] && ok "host Docker container (network ${net}): blocked (expected)" || { warn "host Docker container (network ${net}) REACHES the database"; FAIL=1; }
done

echo
if [ "${FAIL}" -eq 0 ]; then
  echo ">> Done: ${NAME} at ${IP}, isolation verified."
  echo ">> Next: save the secrets in the vault; snapshot: ssh ${HOST} lxc snapshot ${NAME} <name>; Studio: ./ops/admin_tunnel.sh"
else
  echo ">> Applied, BUT the isolation check failed (see WARN). Do not migrate data before resolving." >&2
  exit 2
fi

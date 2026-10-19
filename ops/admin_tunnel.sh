#!/usr/bin/env bash
#
# admin_tunnel.sh — opens Studio/API (http://localhost:8000) and direct Postgres (localhost:5433)
# on the Mac, through ssh to oute-server and the LXD proxy devices created by provision_lxc.sh.
# Ctrl-C closes it. Studio login: DASHBOARD_USERNAME / DASHBOARD_PASSWORD (vault).

set -euo pipefail
HOST="${OUTE_HOST:-oute-server}"
echo ">> Studio: http://localhost:8000   Postgres: localhost:5433   (Ctrl-C to close)"
exec ssh -N -o ExitOnForwardFailure=yes -L 8000:127.0.0.1:18000 -L 5433:127.0.0.1:15433 "${HOST}"

#!/usr/bin/env bash
set -euo pipefail

cd /home/micu/julia
source .env

echo "Checking local health endpoint..."
for _ in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "http://127.0.0.1:${APP_PORT}/health"
echo
curl -fsS "http://127.0.0.1:${APP_PORT}/health" | jq -e '.storage == "postgres" and .status == "ok"' >/dev/null

echo "Checking public HTTPS endpoint..."
curl -fsS "https://julia.micutu.com/health"
echo

echo "Checking systemd service..."
systemctl --no-pager --full status julia-benchmark-lab.service

#!/usr/bin/env bash
set -euo pipefail

cd /home/micu/julia
source .env

echo "Checking local health endpoint..."
curl -fsS "http://127.0.0.1:${APP_PORT}/health"
echo

echo "Checking public HTTPS endpoint..."
curl -fsS "https://julia.micutu.com/health"
echo

echo "Checking systemd service..."
systemctl --no-pager --full status julia-benchmark-lab.service

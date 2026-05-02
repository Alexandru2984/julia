#!/usr/bin/env bash
set -euo pipefail

start="${1:-8095}"
end="${2:-8999}"

for port in $(seq "$start" "$end"); do
  if ! ss -ltn "( sport = :$port )" | grep -q ":$port"; then
    echo "$port"
    exit 0
  fi
done

echo "No free port found in range $start-$end" >&2
exit 1

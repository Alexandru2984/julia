# Julia Scientific Benchmark Lab

Julia Scientific Benchmark Lab is a production-oriented Julia web dashboard for small scientific-computing demos, numerical simulations, and benchmark runs.

## Features

- Dark responsive dashboard with benchmark cards, status, quick stats, and recent history.
- JSON API for health checks, recent runs, and benchmark execution.
- Benchmarks for dense matrix multiplication, Monte Carlo pi, 2D heat diffusion, random walk, and DataFrame processing.
- SQLite-backed recent run history.
- Strict input validation and hard limits to protect the VPS.
- Nginx reverse proxy with HTTPS via Certbot.

## Stack

- Julia 1.12.6 installed under `/home/micu/julia/runtime`.
- HTTP.jl for the web server.
- JSON3.jl for JSON.
- SQLite.jl and DBInterface.jl for storage.
- DataFrames.jl for the DataFrame benchmark.
- Plain HTML, CSS, JavaScript, and Chart.js on the frontend.

## Run Locally On The VPS

```bash
cd /home/micu/julia
source .env
JULIA_DEPOT_PATH=/home/micu/julia/.julia_depot \
  runtime/julia-1.12.6/bin/julia --project=/home/micu/julia src/main.jl
```

Then open `http://127.0.0.1:$APP_PORT/health` from the VPS.

## Environment Variables

The app reads `/home/micu/julia/.env` through systemd.

- `APP_HOST=127.0.0.1`
- `APP_PORT=<chosen local port>`
- `JULIA_NUM_THREADS=2`

`.env` is intentionally ignored by Git.

## Service And Proxy

- Systemd service: `julia-benchmark-lab.service`
- Nginx config path: `/etc/nginx/sites-available/julia.micutu.com`
- Enabled site path: `/etc/nginx/sites-enabled/julia.micutu.com`
- Public URL: `https://julia.micutu.com`

## Benchmark Safety Limits

- Matrix multiplication: `n` from 10 to 300.
- Monte Carlo pi: `samples` from 1,000 to 200,000.
- Heat diffusion: `grid` from 10 to 80, `steps` from 1 to 200.
- Random walk: `steps` from 10 to 5,000.
- DataFrame processing: `rows` from 1,000 to 100,000.
- Nginx request body size is limited to 16 KB.
- The Julia app rejects request bodies over 4 KB.

## API

- `GET /health`
- `GET /api/runs`
- `POST /api/benchmark/matrix`
- `POST /api/benchmark/monte-carlo-pi`
- `POST /api/benchmark/heat-diffusion`
- `POST /api/benchmark/random-walk`
- `POST /api/benchmark/dataframe`

## Deployment Notes

The app binds only to `127.0.0.1`; Nginx is the public entry point. Existing services are not killed during deployment. If the preferred port is occupied, `scripts/find_free_port.sh` selects the next free port.

Git commits and pushes are manual and were not done by the agent.

## Troubleshooting

```bash
systemctl status julia-benchmark-lab.service --no-pager
journalctl -u julia-benchmark-lab.service -n 100 --no-pager
sudo nginx -t
curl -fsS http://127.0.0.1:$APP_PORT/health
curl -fsS https://julia.micutu.com/health
sqlite3 /home/micu/julia/data/runs.sqlite3 'select * from benchmark_runs order by created_at desc limit 5;'
```

# Julia Scientific Benchmark Lab

![CI](https://github.com/Alexandru2984/julia/actions/workflows/ci.yml/badge.svg)

Julia Scientific Benchmark Lab is a production-oriented Julia web dashboard for small scientific-computing demos, numerical simulations, and benchmark runs.

## Features

- Dark responsive dashboard with benchmark cards, status, quick stats, and recent history.
- JSON API for health checks, recent runs, and benchmark execution.
- Benchmarks for dense matrix multiplication, Monte Carlo pi, 2D heat diffusion, random walk, and DataFrame processing.
- PostgreSQL-backed recent run history (pooled connections), with SQLite fallback for local development.
- Strict input validation and hard limits to protect the VPS.
- Nginx reverse proxy with HTTPS via Certbot.

## Stack

- Julia 1.12.6 installed under `/home/micu/julia/runtime`.
- HTTP.jl for the web server.
- JSON3.jl for JSON.
- LibPQ.jl, SQLite.jl, and DBInterface.jl for storage.
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
- `DATABASE_URL=postgresql://...`
- `RUN_RETENTION=5000`
- `MAX_CONCURRENT_BENCHMARKS=2`
- `MAX_QUEUED_JOBS=50`
- `DB_POOL_SIZE=4` (Postgres connection pool size; 1-16)

Benchmarks run on worker threads, so `JULIA_NUM_THREADS` should exceed the
number of concurrent benchmarks you want. The app always reserves one thread
for the HTTP event loop: effective benchmark concurrency is
`min(MAX_CONCURRENT_BENCHMARKS, JULIA_NUM_THREADS - 1)`. With the default
2 threads, one benchmark runs at a time; set `JULIA_NUM_THREADS=3` to allow two
while keeping `/health` and job polling responsive. `GET /health` reports the
effective and configured limits plus the thread count.

`.env` is intentionally ignored by Git.
Keep it owner-readable only:

```bash
chmod 600 /home/micu/julia/.env
```

## Tests

Unit tests cover input validation, benchmark output shape, and the
env-driven limit clamps (no database required):

```bash
cd /home/micu/julia
JULIA_DEPOT_PATH=/home/micu/julia/.julia_depot \
  runtime/julia-1.12.6/bin/julia --project=. test/runtests.jl
```

Or via the package test target: `Pkg.test("JuliaScientificBenchmarkLab")`.

## Service And Proxy

- Systemd service: `julia-benchmark-lab.service`
- Nginx config path: `/etc/nginx/sites-available/julia.micutu.com`
- Enabled site path: `/etc/nginx/sites-enabled/julia.micutu.com`
- Public URL: `https://julia.micutu.com`

## Benchmark Safety Limits

- Matrix multiplication: `n` from 10 to 600.
- Monte Carlo pi: `samples` from 1,000 to 2,000,000.
- Heat diffusion: `grid` from 10 to 160, `steps` from 1 to 500.
- Random walk: `steps` from 10 to 100,000.
- DataFrame processing: `rows` from 1,000 to 750,000.
- Nginx rate limits benchmark API calls, and rejects requests that do not
  arrive through Cloudflare (origin guard).
- The Julia process allows only a small number of concurrent benchmark runs,
  always reserving one thread for the HTTP event loop so heavy benchmarks
  cannot starve health checks and job polling.
- Benchmark requests are queued as jobs and polled by the frontend.
- Nginx request body size is limited to 16 KB.
- The Julia app rejects request bodies over 4 KB.
- Run history retention defaults to 5,000 rows.

## API

- `GET /health`
- `GET /api/runs`
- `GET /api/jobs`
- `GET /api/jobs/:id`
- `POST /api/benchmark/matrix`
- `POST /api/benchmark/monte-carlo-pi`
- `POST /api/benchmark/heat-diffusion`
- `POST /api/benchmark/random-walk`
- `POST /api/benchmark/dataframe`

Benchmark `POST` endpoints create an asynchronous job and return `202` with a UUID `job_id`, a `job_token`, and a `poll_url`. `GET /api/jobs` returns summary-only data. Full job details are available through `GET /api/jobs/:id` only when the request includes `X-Job-Token: <job_token>`.

## Deployment Notes

The app binds only to `127.0.0.1`; Nginx is the public entry point. Existing services are not killed during deployment. If the preferred port is occupied, `scripts/find_free_port.sh` selects the next free port.

Production hardening includes Nginx CSP/HSTS/security headers, request rate limits, a local-only PostgreSQL database user, and systemd resource limits.

Git commits and pushes are normally manual. The security hardening update was committed and pushed only after explicit owner approval.

## Troubleshooting

```bash
systemctl status julia-benchmark-lab.service --no-pager
journalctl -u julia-benchmark-lab.service -n 100 --no-pager
sudo nginx -t
curl -fsS http://127.0.0.1:$APP_PORT/health
curl -fsS https://julia.micutu.com/health
sqlite3 /home/micu/julia/data/runs.sqlite3 'select * from benchmark_runs order by created_at desc limit 5;'
sudo -u postgres psql -d julia_benchmark_lab -c 'select benchmark_type, duration_ms, created_at from benchmark_runs order by created_at desc limit 5;'
```

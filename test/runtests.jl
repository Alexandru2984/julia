using Test
using HTTP
using JSON3
using JuliaScientificBenchmarkLab

const JSBL = JuliaScientificBenchmarkLab

# Run `f` against a throwaway SQLite database in a temp dir. DATABASE_URL is
# forced unset so storage tests never touch a real Postgres (prod) instance,
# and JULIA_BENCH_DATA_DIR redirects the SQLite file away from ./data.
function with_fresh_db(f)
    mktempdir() do dir
        withenv("JULIA_BENCH_DATA_DIR" => dir, "DATABASE_URL" => nothing) do
            JSBL.init_storage!()
            f()
        end
    end
end

@testset "JuliaScientificBenchmarkLab" begin
    @testset "validation: accepts valid input" begin
        @test JSBL.validate_matrix(Dict("n" => 100)).n == 100
        @test JSBL.validate_monte_carlo_pi(Dict("samples" => 5_000)).samples == 5_000
        hd = JSBL.validate_heat_diffusion(Dict("grid" => 40, "steps" => 100))
        @test hd.grid == 40
        @test hd.steps == 100
        @test JSBL.validate_random_walk(Dict("steps" => 1_000)).steps == 1_000
        @test JSBL.validate_dataframe(Dict("rows" => 10_000)).rows == 10_000
    end

    @testset "validation: inclusive boundaries" begin
        @test JSBL.validate_matrix(Dict("n" => 10)).n == 10
        @test JSBL.validate_matrix(Dict("n" => 600)).n == 600
        @test JSBL.validate_dataframe(Dict("rows" => 1_000)).rows == 1_000
        @test JSBL.validate_dataframe(Dict("rows" => 750_000)).rows == 750_000
    end

    @testset "validation: rejects bad input" begin
        @test_throws ArgumentError JSBL.validate_matrix(Dict{String,Any}())          # missing
        @test_throws ArgumentError JSBL.validate_matrix(Dict("n" => 100.5))          # non-integer
        @test_throws ArgumentError JSBL.validate_matrix(Dict("n" => "100"))          # wrong type
        @test_throws ArgumentError JSBL.validate_matrix(Dict("n" => 9))              # below min
        @test_throws ArgumentError JSBL.validate_matrix(Dict("n" => 601))            # above max
        @test_throws ArgumentError JSBL.validate_heat_diffusion(Dict("grid" => 40))  # missing steps
        @test_throws ArgumentError JSBL.validate_random_walk(Dict("steps" => 100_001))
    end

    @testset "benchmarks: matrix" begin
        m = JSBL.run_matrix(50)
        @test m["benchmark"] == "matrix"
        @test m["result"]["matrix_shape"] == "50x50"
        @test isfinite(m["result"]["checksum"])
        @test m["duration_ms"] >= 0
    end

    @testset "benchmarks: monte carlo pi" begin
        mc = JSBL.run_monte_carlo_pi(50_000)
        @test mc["benchmark"] == "monte-carlo-pi"
        @test abs(mc["result"]["pi_estimate"] - pi) < 0.1   # ~13σ, never flaky
        @test length(mc["chart"]["labels"]) == length(mc["chart"]["data"])
    end

    @testset "benchmarks: heat diffusion" begin
        hd = JSBL.run_heat_diffusion(20, 50)
        @test 0.0 <= hd["result"]["average_temperature"] <= 1.0
        @test hd["result"]["max_temperature"] <= 1.0
        @test length(hd["chart"]["heatmap"]) == 20
        @test length(hd["chart"]["heatmap"][1]) == 20
    end

    @testset "benchmarks: random walk" begin
        rw = JSBL.run_random_walk(5_000)
        @test rw["result"]["distance_from_origin"] >= 0
        @test length(rw["chart"]["x"]) == length(rw["chart"]["y"])
    end

    @testset "benchmarks: dataframe" begin
        dfr = JSBL.run_dataframe(20_000)
        @test dfr["result"]["groups"] >= 1
        @test 1 <= dfr["result"]["top_group"] <= 20
    end

    @testset "helpers: identifiers and timestamps" begin
        @test length(JSBL.new_access_token()) == 48
        @test occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", JSBL.new_public_id())
        @test endswith(JSBL.utc_timestamp(), "Z")
    end

    @testset "storage: job access requires the matching token" begin
        with_fresh_db() do
            job = JSBL.create_job!("matrix", "{\"n\":50}", "50x50")
            @test JSBL.get_job(job["public_id"], job["access_token"]) !== nothing
            # Wrong token must not return the job (no token-less lookup).
            @test JSBL.get_job(job["public_id"], "not-the-token") === nothing
            @test JSBL.get_job(job["public_id"], "") === nothing
            # Unknown id, even with a real-looking token, returns nothing.
            @test JSBL.get_job("00000000-0000-0000-0000-000000000000", job["access_token"]) === nothing
        end
    end

    @testset "storage: job summaries never leak token, input, or result" begin
        with_fresh_db() do
            job = JSBL.create_job!("matrix", "{\"n\":50}", "50x50")
            JSBL.complete_job!(job["id"], 12.5, "{\"result\":{\"checksum\":1}}")
            for summary in JSBL.recent_jobs(20)
                @test !haskey(summary, "access_token")
                @test !haskey(summary, "input")
                @test !haskey(summary, "result")
                @test haskey(summary, "id")
                @test haskey(summary, "status")
            end
        end
    end

    @testset "storage: job lifecycle transitions" begin
        with_fresh_db() do
            job = JSBL.create_job!("matrix", "{\"n\":50}", "50x50")
            @test JSBL.get_job(job["public_id"], job["access_token"])["status"] == "queued"
            JSBL.mark_job_running!(job["id"])
            @test JSBL.get_job(job["public_id"], job["access_token"])["status"] == "running"
            JSBL.complete_job!(job["id"], 12.5, "{\"result\":{\"checksum\":1}}")
            done = JSBL.get_job(job["public_id"], job["access_token"])
            @test done["status"] == "done"
            @test done["duration_ms"] == 12.5
            @test done["finished_at"] !== nothing
        end
    end

    @testset "storage: create_job! enforces the queue limit" begin
        with_fresh_db() do
            withenv("MAX_QUEUED_JOBS" => "2") do
                JSBL.create_job!("matrix", "{}", "a")
                JSBL.create_job!("matrix", "{}", "b")
                @test JSBL.active_job_count() == 2
                @test_throws ArgumentError JSBL.create_job!("matrix", "{}", "c")
            end
        end
    end

    @testset "storage: restart marks incomplete jobs as failed" begin
        with_fresh_db() do
            job = JSBL.create_job!("matrix", "{}", "x")
            JSBL.mark_job_running!(job["id"])
            JSBL.init_storage!()  # simulate a service restart
            fetched = JSBL.get_job(job["public_id"], job["access_token"])
            @test fetched["status"] == "failed"
            @test fetched["error"] !== nothing
        end
    end

    @testset "storage: fail_job truncates oversized error messages" begin
        with_fresh_db() do
            job = JSBL.create_job!("matrix", "{}", "x")
            JSBL.fail_job!(job["id"], repeat("e", 5000))
            fetched = JSBL.get_job(job["public_id"], job["access_token"])
            @test fetched["status"] == "failed"
            @test length(fetched["error"]) <= 600
        end
    end

    @testset "storage: runs insert/read roundtrip" begin
        with_fresh_db() do
            @test JSBL.run_count() == 0
            JSBL.insert_run!("matrix", "50x50", 12.345, "{\"checksum\":1}")
            @test JSBL.run_count() == 1
            runs = JSBL.recent_runs(20)
            @test length(runs) == 1
            @test runs[1]["benchmark_type"] == "matrix"
            @test runs[1]["input_size"] == "50x50"
            @test runs[1]["duration_ms"] == 12.345
        end
    end

    @testset "helpers: benchmark concurrency leaves a thread for HTTP" begin
        # Always reserve one thread for the event loop (nthreads-1), but never
        # drop below 1, and never exceed the configured limit.
        @test JSBL.thread_capped(2, 2) == 1   # prod default: 2 threads -> 1 benchmark
        @test JSBL.thread_capped(2, 3) == 2   # 3 threads -> full configured concurrency
        @test JSBL.thread_capped(8, 4) == 3   # capped by threads, not config
        @test JSBL.thread_capped(2, 1) == 1   # single thread -> at least 1
        @test JSBL.thread_capped(1, 8) == 1   # never exceed configured
        @test JSBL.thread_capped(4, 12) == 4  # plenty of threads -> use configured
    end

    @testset "helpers: env-driven limits are clamped" begin
        withenv("MAX_QUEUED_JOBS" => "9999") do
            @test JSBL.max_queued_jobs() == 500
        end
        withenv("MAX_QUEUED_JOBS" => "0") do
            @test JSBL.max_queued_jobs() == 1
        end
        withenv("MAX_QUEUED_JOBS" => "garbage") do
            @test JSBL.max_queued_jobs() == 50
        end
        withenv("MAX_CONCURRENT_BENCHMARKS" => "100") do
            @test JSBL.max_concurrent_benchmarks() == 8
        end
        withenv("RUN_RETENTION" => "10") do
            @test JSBL.retention_limit() == 100
        end
    end

    @testset "http: GET /health returns status and runtime info" begin
        with_fresh_db() do
            resp = JSBL.app(HTTP.Request("GET", "/health"))
            @test resp.status == 200
            body = JSON3.read(String(resp.body))
            @test body.status == "ok"
            @test haskey(body, :threads)
            @test haskey(body, :max_concurrent_benchmarks)
        end
    end

    @testset "http: static assets are served with correct content types" begin
        resp = JSBL.app(HTTP.Request("GET", "/"))
        @test resp.status == 200
        @test occursin("text/html", HTTP.header(resp, "Content-Type"))
        for (path, ct) in [("/styles.css", "text/css"), ("/app.js", "application/javascript")]
            r = JSBL.app(HTTP.Request("GET", path))
            @test r.status == 200
            @test occursin(ct, HTTP.header(r, "Content-Type"))
        end
    end

    @testset "http: unknown route returns 404 JSON" begin
        resp = JSBL.app(HTTP.Request("GET", "/nope"))
        @test resp.status == 404
        @test occursin("application/json", HTTP.header(resp, "Content-Type"))
    end

    @testset "http: static routing blocks path traversal" begin
        # Only a fixed allow-list of paths is served statically; anything trying
        # to escape PUBLIC_DIR falls through to a 404 instead of reading the file.
        for evil in ["/../src/storage.jl", "/../../etc/passwd", "/..%2f..%2fetc%2fpasswd"]
            r = JSBL.app(HTTP.Request("GET", evil))
            @test r.status == 404
        end
    end

    @testset "http: invalid benchmark requests return 400" begin
        with_fresh_db() do
            missing_field = JSBL.app(HTTP.Request("POST", "/api/benchmark/matrix",
                ["Content-Type" => "application/json"], "{}"))
            @test missing_field.status == 400
            out_of_range = JSBL.app(HTTP.Request("POST", "/api/benchmark/matrix",
                ["Content-Type" => "application/json"], "{\"n\":99999}"))
            @test out_of_range.status == 400
            bad_json = JSBL.app(HTTP.Request("POST", "/api/benchmark/matrix",
                ["Content-Type" => "application/json"], "not json"))
            @test bad_json.status == 400
        end
    end

    @testset "http: oversized request body is rejected" begin
        with_fresh_db() do
            oversized = "{\"n\":" * repeat("0", 5000) * "1}"  # > MAX_BODY_BYTES (4096)
            r = JSBL.app(HTTP.Request("POST", "/api/benchmark/matrix",
                ["Content-Type" => "application/json"], oversized))
            @test r.status == 400
        end
    end

    @testset "http: job lookup requires the matching token" begin
        with_fresh_db() do
            no_token = JSBL.app(HTTP.Request("GET", "/api/jobs/some-id"))
            @test no_token.status == 404
            job = JSBL.create_job!("matrix", "{\"n\":10}", "10x10")
            ok = JSBL.app(HTTP.Request("GET", "/api/jobs/$(job["public_id"])",
                ["X-Job-Token" => job["access_token"]]))
            @test ok.status == 200
            wrong = JSBL.app(HTTP.Request("GET", "/api/jobs/$(job["public_id"])",
                ["X-Job-Token" => "wrong-token"]))
            @test wrong.status == 404
        end
    end

    @testset "http: valid benchmark request queues a job (202)" begin
        with_fresh_db() do
            resp = JSBL.app(HTTP.Request("POST", "/api/benchmark/matrix",
                ["Content-Type" => "application/json"], "{\"n\":10}"))
            @test resp.status == 202
            body = JSON3.read(String(resp.body))
            @test haskey(body, :job_id)
            @test haskey(body, :job_token)
            @test body.status == "queued"
            # The handler spawns the benchmark on a worker thread. Wait for it to
            # finish *inside* this withenv block so its async db() call resolves
            # the temp data dir, never the restored (production) environment.
            jid = String(body.job_id)
            tok = String(body.job_token)
            finished = false
            for _ in 1:200
                job = JSBL.get_job(jid, tok)
                if job !== nothing && job["status"] in ("done", "failed")
                    finished = true
                    @test job["status"] == "done"
                    break
                end
                sleep(0.05)
            end
            @test finished
        end
    end
end

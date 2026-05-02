using Dates
using HTTP
using JSON3
using Sockets

const PUBLIC_DIR = joinpath(dirname(@__DIR__), "public")
const MAX_BODY_BYTES = 4096
const ACTIVE_BENCHMARKS = Ref(0)
const BENCHMARK_SEMAPHORE = Ref{Any}(nothing)
const BENCHMARK_LOCK = ReentrantLock()

function max_concurrent_benchmarks()
    raw = get(ENV, "MAX_CONCURRENT_BENCHMARKS", "2")
    try
        return clamp(parse(Int, raw), 1, 8)
    catch
        return 2
    end
end

function benchmark_semaphore()
    lock(BENCHMARK_LOCK)
    try
        if BENCHMARK_SEMAPHORE[] === nothing
            BENCHMARK_SEMAPHORE[] = Base.Semaphore(max_concurrent_benchmarks())
        end
        return BENCHMARK_SEMAPHORE[]
    finally
        unlock(BENCHMARK_LOCK)
    end
end

function enter_benchmark()
    lock(BENCHMARK_LOCK)
    try
        ACTIVE_BENCHMARKS[] += 1
    finally
        unlock(BENCHMARK_LOCK)
    end
end

function leave_benchmark()
    lock(BENCHMARK_LOCK)
    try
        ACTIVE_BENCHMARKS[] = max(0, ACTIVE_BENCHMARKS[] - 1)
    finally
        unlock(BENCHMARK_LOCK)
    end
end

function params_to_dict(params)
    return Dict(String(name) => getfield(params, name) for name in propertynames(params))
end

function start_benchmark_job!(job_id::Int, handler, params, benchmark_type::String, input_size::String)
    @async begin
        semaphore = benchmark_semaphore()
        Base.acquire(semaphore)
        enter_benchmark()
        try
            mark_job_running!(job_id)
            result = handler(params)
            result["timestamp"] = utc_timestamp()
            insert_run!(
                benchmark_type,
                input_size,
                result["duration_ms"],
                JSON3.write(result["result"]),
            )
            complete_job!(job_id, result["duration_ms"], JSON3.write(result))
        catch err
            @error "Benchmark job failed" job_id = job_id benchmark_type = benchmark_type exception = (err, catch_backtrace())
            fail_job!(job_id, sprint(showerror, err))
        finally
            leave_benchmark()
            Base.release(semaphore)
        end
    end
end

function json_response(data; status::Int = 200)
    return HTTP.Response(
        status,
        ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"],
        JSON3.write(data),
    )
end

function text_response(message; status::Int = 200, content_type::String = "text/plain; charset=utf-8")
    return HTTP.Response(status, ["Content-Type" => content_type], message)
end

function static_response(path::AbstractString)
    clean_path = path == "/" ? "/index.html" : path
    full_path = clean_path == "/vendor/chart.umd.min.js" ?
        joinpath(PUBLIC_DIR, "vendor", "chart.umd.min.js") :
        joinpath(PUBLIC_DIR, basename(clean_path))
    isfile(full_path) || return text_response("Not found"; status = 404)
    content_type = endswith(full_path, ".html") ? "text/html; charset=utf-8" :
        endswith(full_path, ".css") ? "text/css; charset=utf-8" :
        endswith(full_path, ".js") ? "application/javascript; charset=utf-8" :
        "application/octet-stream"
    return HTTP.Response(200, ["Content-Type" => content_type], read(full_path))
end

function parse_body(req::HTTP.Request)
    length(req.body) <= MAX_BODY_BYTES || throw(ArgumentError("Request body is too large"))
    isempty(req.body) && return Dict{String, Any}()
    parsed = JSON3.read(String(req.body), Dict{String, Any})
    return parsed
end

function with_benchmark(handler, validator, benchmark_type::String, input_summary)
    return function (req::HTTP.Request)
        try
            payload = parse_body(req)
            params = validator(payload)
            input_size = input_summary(params)
            job_id = create_job!(
                benchmark_type,
                JSON3.write(params_to_dict(params)),
                input_size,
            )
            start_benchmark_job!(job_id, handler, params, benchmark_type, input_size)
            return json_response(Dict(
                "job_id" => job_id,
                "status" => "queued",
                "poll_url" => "/api/jobs/$job_id",
            ); status = 202)
        catch err
            if err isa ArgumentError
                return json_response(Dict("error" => sprint(showerror, err)); status = 400)
            end
            @error "Benchmark request failed" exception = (err, catch_backtrace())
            return json_response(Dict("error" => "Benchmark failed"); status = 500)
        end
    end
end

const HANDLERS = Dict{Tuple{String, String}, Function}(
    ("GET", "/health") => _ -> json_response(Dict(
        "status" => "ok",
        "service" => "Julia Scientific Benchmark Lab",
        "storage" => String(storage_backend()),
        "active_benchmarks" => ACTIVE_BENCHMARKS[],
        "active_jobs" => active_job_count(),
        "max_queued_jobs" => max_queued_jobs(),
        "max_concurrent_benchmarks" => max_concurrent_benchmarks(),
        "timestamp" => utc_timestamp(),
    )),
    ("GET", "/api/runs") => _ -> json_response(Dict("runs" => recent_runs(20))),
    ("GET", "/api/jobs") => _ -> json_response(Dict("jobs" => recent_jobs(20))),
    ("POST", "/api/benchmark/matrix") => with_benchmark(
        p -> run_matrix(p.n),
        validate_matrix,
        "matrix",
        p -> "$(p.n)x$(p.n)",
    ),
    ("POST", "/api/benchmark/monte-carlo-pi") => with_benchmark(
        p -> run_monte_carlo_pi(p.samples),
        validate_monte_carlo_pi,
        "monte-carlo-pi",
        p -> "$(p.samples) samples",
    ),
    ("POST", "/api/benchmark/heat-diffusion") => with_benchmark(
        p -> run_heat_diffusion(p.grid, p.steps),
        validate_heat_diffusion,
        "heat-diffusion",
        p -> "$(p.grid)x$(p.grid), $(p.steps) steps",
    ),
    ("POST", "/api/benchmark/random-walk") => with_benchmark(
        p -> run_random_walk(p.steps),
        validate_random_walk,
        "random-walk",
        p -> "$(p.steps) steps",
    ),
    ("POST", "/api/benchmark/dataframe") => with_benchmark(
        p -> run_dataframe(p.rows),
        validate_dataframe,
        "dataframe",
        p -> "$(p.rows) rows",
    ),
)

function job_response(path::AbstractString)
    id_text = replace(path, "/api/jobs/" => ""; count = 1)
    !isempty(id_text) && all(isdigit, id_text) || return json_response(Dict("error" => "Not found"); status = 404)
    job = get_job(parse(Int, id_text))
    job === nothing && return json_response(Dict("error" => "Not found"); status = 404)
    return json_response(Dict("job" => job))
end

function app(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    path = uri.path
    method = String(req.method)
    if method == "GET" && startswith(path, "/api/jobs/")
        return job_response(path)
    end
    if haskey(HANDLERS, (method, path))
        return HANDLERS[(method, path)](req)
    end
    if method == "GET" && (path == "/" || path == "/index.html" || path == "/styles.css" || path == "/app.js" || path == "/vendor/chart.umd.min.js")
        return static_response(path)
    end
    return json_response(Dict("error" => "Not found"); status = 404)
end

using Dates
using HTTP
using JSON3
using Sockets

const PUBLIC_DIR = joinpath(dirname(@__DIR__), "public")
const MAX_BODY_BYTES = 4096

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
    safe_name = basename(clean_path)
    full_path = joinpath(PUBLIC_DIR, safe_name)
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
            result = handler(params)
            insert_run!(
                benchmark_type,
                input_summary(params),
                result["duration_ms"],
                JSON3.write(result["result"]),
            )
            result["timestamp"] = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ")
            return json_response(result)
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
        "timestamp" => Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ"),
    )),
    ("GET", "/api/runs") => _ -> json_response(Dict("runs" => recent_runs(20))),
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

function app(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    path = uri.path
    method = String(req.method)
    if haskey(HANDLERS, (method, path))
        return HANDLERS[(method, path)](req)
    end
    if method == "GET" && (path == "/" || path == "/index.html" || path == "/styles.css" || path == "/app.js")
        return static_response(path)
    end
    return json_response(Dict("error" => "Not found"); status = 404)
end

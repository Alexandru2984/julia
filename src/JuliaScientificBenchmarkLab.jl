module JuliaScientificBenchmarkLab

include("storage.jl")
include("validation.jl")
include("benchmarks.jl")
include("routes.jl")

export main

function main()
    init_storage!()
    @info "Warming up benchmark functions"
    warmup_benchmarks!()

    host = get(ENV, "APP_HOST", "127.0.0.1")
    host == "127.0.0.1" || error("APP_HOST must be 127.0.0.1")
    port = parse(Int, get(ENV, "APP_PORT", "8095"))

    @info "Starting Julia Scientific Benchmark Lab" host = host port = port
    HTTP.serve(app, Sockets.localhost, port; verbose = false, readtimeout = 10)
end

end

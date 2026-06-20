using Test
using JuliaScientificBenchmarkLab

const JSBL = JuliaScientificBenchmarkLab

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
end

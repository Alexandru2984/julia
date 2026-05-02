using DataFrames
using LinearAlgebra
using Random
using Statistics

const EXPLANATIONS = Dict(
    "matrix" => "Multiplies two dense random matrices with Julia's optimized linear algebra stack.",
    "monte-carlo-pi" => "Estimates pi by sampling random points in the unit square and counting points inside the unit circle.",
    "heat-diffusion" => "Simulates a simple 2D heat equation stencil over a square grid with fixed hot boundaries.",
    "random-walk" => "Generates a two-dimensional random walk and reports the resulting displacement path.",
    "dataframe" => "Builds a DataFrame, groups rows, and computes aggregate statistics.",
)

rounded(x; digits = 6) = round(Float64(x); digits = digits)

function run_matrix(n::Int)
    A = rand(Float64, n, n)
    B = rand(Float64, n, n)
    elapsed = @elapsed C = A * B
    checksum = sum(@view C[1:min(n, 10), 1:min(n, 10)])
    return Dict(
        "benchmark" => "matrix",
        "input" => Dict("n" => n),
        "duration_ms" => rounded(elapsed * 1000; digits = 3),
        "result" => Dict(
            "checksum" => rounded(checksum),
            "matrix_shape" => "$(n)x$(n)",
            "operations_estimate" => 2 * n^3,
        ),
        "chart" => Dict("labels" => ["$(n)x$(n)"], "data" => [rounded(elapsed * 1000; digits = 3)]),
        "explanation" => EXPLANATIONS["matrix"],
    )
end

function run_monte_carlo_pi(samples::Int)
    checkpoints = unique(round.(Int, range(max(100, samples ÷ 20), samples; length = 20)))
    convergence = Vector{Float64}()
    labels = Vector{Int}()
    inside = 0
    checkpoint_index = 1
    elapsed = @elapsed begin
        for i in 1:samples
            x = rand()
            y = rand()
            inside += (x * x + y * y <= 1.0)
            if checkpoint_index <= length(checkpoints) && i == checkpoints[checkpoint_index]
                push!(labels, i)
                push!(convergence, rounded(4 * inside / i))
                checkpoint_index += 1
            end
        end
    end
    estimate = 4 * inside / samples
    return Dict(
        "benchmark" => "monte-carlo-pi",
        "input" => Dict("samples" => samples),
        "duration_ms" => rounded(elapsed * 1000; digits = 3),
        "result" => Dict("pi_estimate" => rounded(estimate), "absolute_error" => rounded(abs(pi - estimate))),
        "chart" => Dict("labels" => labels, "data" => convergence),
        "explanation" => EXPLANATIONS["monte-carlo-pi"],
    )
end

function run_heat_diffusion(grid::Int, steps::Int)
    field = zeros(Float64, grid, grid)
    field[:, 1] .= 1.0
    field[1, :] .= 0.75
    next_field = copy(field)
    elapsed = @elapsed begin
        for _ in 1:steps
            @inbounds for i in 2:grid-1, j in 2:grid-1
                next_field[i, j] = 0.25 * (field[i - 1, j] + field[i + 1, j] + field[i, j - 1] + field[i, j + 1])
            end
            field, next_field = next_field, field
        end
    end
    heatmap = [[rounded(field[i, j]; digits = 4) for j in 1:grid] for i in 1:grid]
    return Dict(
        "benchmark" => "heat-diffusion",
        "input" => Dict("grid" => grid, "steps" => steps),
        "duration_ms" => rounded(elapsed * 1000; digits = 3),
        "result" => Dict("average_temperature" => rounded(mean(field)), "max_temperature" => rounded(maximum(field))),
        "chart" => Dict("heatmap" => heatmap),
        "explanation" => EXPLANATIONS["heat-diffusion"],
    )
end

function run_random_walk(steps::Int)
    x = 0
    y = 0
    xs = Int[0]
    ys = Int[0]
    sample_every = max(1, steps ÷ 500)
    elapsed = @elapsed begin
        for i in 1:steps
            direction = rand(1:4)
            if direction == 1
                x += 1
            elseif direction == 2
                x -= 1
            elseif direction == 3
                y += 1
            else
                y -= 1
            end
            if i % sample_every == 0 || i == steps
                push!(xs, x)
                push!(ys, y)
            end
        end
    end
    distance = sqrt(x^2 + y^2)
    return Dict(
        "benchmark" => "random-walk",
        "input" => Dict("steps" => steps),
        "duration_ms" => rounded(elapsed * 1000; digits = 3),
        "result" => Dict("final_x" => x, "final_y" => y, "distance_from_origin" => rounded(distance)),
        "chart" => Dict("x" => xs, "y" => ys),
        "explanation" => EXPLANATIONS["random-walk"],
    )
end

function run_dataframe(rows::Int)
    elapsed = @elapsed begin
        df = DataFrame(
            group = rand(1:20, rows),
            value = rand(rows),
            weight = rand(rows) .+ 0.1,
        )
        grouped = combine(groupby(df, :group),
            :value => mean => :value_mean,
            :value => sum => :value_sum,
            :weight => mean => :weight_mean,
            nrow => :rows,
        )
    end
    top_group = grouped[argmax(grouped.value_sum), :]
    return Dict(
        "benchmark" => "dataframe",
        "input" => Dict("rows" => rows),
        "duration_ms" => rounded(elapsed * 1000; digits = 3),
        "result" => Dict(
            "groups" => nrow(grouped),
            "top_group" => Int(top_group.group),
            "top_group_sum" => rounded(top_group.value_sum),
        ),
        "chart" => Dict(
            "labels" => string.(grouped.group),
            "data" => [rounded(v; digits = 4) for v in grouped.value_mean],
        ),
        "explanation" => EXPLANATIONS["dataframe"],
    )
end

function warmup_benchmarks!()
    run_matrix(10)
    run_monte_carlo_pi(1_000)
    run_heat_diffusion(10, 1)
    run_random_walk(10)
    run_dataframe(1_000)
    return nothing
end

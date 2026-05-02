const LIMITS = Dict(
    "matrix" => Dict("n" => (10, 600)),
    "monte_carlo_pi" => Dict("samples" => (1_000, 2_000_000)),
    "heat_diffusion" => Dict("grid" => (10, 160), "steps" => (1, 500)),
    "random_walk" => Dict("steps" => (10, 100_000)),
    "dataframe" => Dict("rows" => (1_000, 750_000)),
)

function require_int(payload, key::String; min::Int, max::Int)
    haskey(payload, key) || throw(ArgumentError("Missing required field: $key"))
    value = payload[key]
    value isa Integer || throw(ArgumentError("$key must be an integer"))
    value >= min || throw(ArgumentError("$key must be at least $min"))
    value <= max || throw(ArgumentError("$key must be at most $max"))
    return Int(value)
end

function validate_matrix(payload)
    lo, hi = LIMITS["matrix"]["n"]
    return (; n = require_int(payload, "n"; min = lo, max = hi))
end

function validate_monte_carlo_pi(payload)
    lo, hi = LIMITS["monte_carlo_pi"]["samples"]
    return (; samples = require_int(payload, "samples"; min = lo, max = hi))
end

function validate_heat_diffusion(payload)
    grid_lo, grid_hi = LIMITS["heat_diffusion"]["grid"]
    step_lo, step_hi = LIMITS["heat_diffusion"]["steps"]
    return (;
        grid = require_int(payload, "grid"; min = grid_lo, max = grid_hi),
        steps = require_int(payload, "steps"; min = step_lo, max = step_hi),
    )
end

function validate_random_walk(payload)
    lo, hi = LIMITS["random_walk"]["steps"]
    return (; steps = require_int(payload, "steps"; min = lo, max = hi))
end

function validate_dataframe(payload)
    lo, hi = LIMITS["dataframe"]["rows"]
    return (; rows = require_int(payload, "rows"; min = lo, max = hi))
end

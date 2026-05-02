using Dates
using DBInterface
using SQLite

const DATA_DIR = joinpath(dirname(@__DIR__), "data")
const DB_PATH = joinpath(DATA_DIR, "runs.sqlite3")

function db()
    mkpath(DATA_DIR)
    return SQLite.DB(DB_PATH)
end

function init_storage!()
    database = db()
    try
        DBInterface.execute(database, """
            CREATE TABLE IF NOT EXISTS benchmark_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                benchmark_type TEXT NOT NULL,
                input_size TEXT NOT NULL,
                duration_ms REAL NOT NULL,
                result_summary TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
        """)
        DBInterface.execute(database, """
            CREATE INDEX IF NOT EXISTS idx_benchmark_runs_created_at
            ON benchmark_runs(created_at DESC)
        """)
    finally
        SQLite.close(database)
    end
end

function insert_run!(benchmark_type::String, input_size::String, duration_ms::Real, result_summary::String)
    created_at = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sssZ")
    database = db()
    try
        DBInterface.execute(
            database,
            "INSERT INTO benchmark_runs (benchmark_type, input_size, duration_ms, result_summary, created_at) VALUES (?, ?, ?, ?, ?)",
            (benchmark_type, input_size, Float64(duration_ms), result_summary, created_at),
        )
    finally
        SQLite.close(database)
    end
end

function recent_runs(limit::Int = 20)
    safe_limit = clamp(limit, 1, 100)
    database = db()
    rows = Vector{Dict{String, Any}}()
    try
        result = DBInterface.execute(
            database,
            "SELECT id, benchmark_type, input_size, duration_ms, result_summary, created_at FROM benchmark_runs ORDER BY created_at DESC LIMIT ?",
            (safe_limit,),
        )
        for row in result
            push!(rows, Dict(
                "id" => row.id,
                "benchmark_type" => row.benchmark_type,
                "input_size" => row.input_size,
                "duration_ms" => round(row.duration_ms; digits = 3),
                "result_summary" => row.result_summary,
                "created_at" => row.created_at,
            ))
        end
    finally
        SQLite.close(database)
    end
    return rows
end

using Dates
using DBInterface
using LibPQ
using SQLite

const DATA_DIR = joinpath(dirname(@__DIR__), "data")
const DB_PATH = joinpath(DATA_DIR, "runs.sqlite3")

utc_timestamp() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"

function storage_backend()
    return isempty(get(ENV, "DATABASE_URL", "")) ? :sqlite : :postgres
end

function db()
    if storage_backend() == :postgres
        conn = DBInterface.connect(LibPQ.Connection, ENV["DATABASE_URL"]; connect_timeout = 5)
        DBInterface.execute(conn, "SET client_min_messages TO warning")
        return conn
    else
        mkpath(DATA_DIR)
        return SQLite.DB(DB_PATH)
    end
end

close_db(database::SQLite.DB) = SQLite.close(database)
close_db(database::LibPQ.DBConnection) = DBInterface.close!(database)

function retention_limit()
    raw = get(ENV, "RUN_RETENTION", "5000")
    try
        return clamp(parse(Int, raw), 100, 100_000)
    catch
        return 5000
    end
end

function init_storage!()
    database = db()
    try
        if storage_backend() == :postgres
            DBInterface.execute(database, """
                CREATE TABLE IF NOT EXISTS benchmark_runs (
                    id BIGSERIAL PRIMARY KEY,
                    benchmark_type TEXT NOT NULL,
                    input_size TEXT NOT NULL,
                    duration_ms DOUBLE PRECISION NOT NULL,
                    result_summary TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
            """)
            DBInterface.execute(database, """
                CREATE INDEX IF NOT EXISTS idx_benchmark_runs_created_at
                ON benchmark_runs(created_at DESC)
            """)
        else
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
        end
    finally
        close_db(database)
    end
end

function insert_run!(benchmark_type::String, input_size::String, duration_ms::Real, result_summary::String)
    created_at = utc_timestamp()
    database = db()
    try
        if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "INSERT INTO benchmark_runs (benchmark_type, input_size, duration_ms, result_summary, created_at) VALUES (\$1, \$2, \$3, \$4, \$5)",
                (benchmark_type, input_size, Float64(duration_ms), result_summary, created_at),
            )
            prune_old_runs!(database)
        else
            DBInterface.execute(
                database,
                "INSERT INTO benchmark_runs (benchmark_type, input_size, duration_ms, result_summary, created_at) VALUES (?, ?, ?, ?, ?)",
                (benchmark_type, input_size, Float64(duration_ms), result_summary, created_at),
            )
            prune_old_runs!(database)
        end
    finally
        close_db(database)
    end
end

function prune_old_runs!(database)
    keep = retention_limit()
    if storage_backend() == :postgres
        DBInterface.execute(
            database,
            "DELETE FROM benchmark_runs WHERE id NOT IN (SELECT id FROM benchmark_runs ORDER BY created_at DESC LIMIT \$1)",
            (keep,),
        )
    else
        DBInterface.execute(
            database,
            "DELETE FROM benchmark_runs WHERE id NOT IN (SELECT id FROM benchmark_runs ORDER BY created_at DESC LIMIT ?)",
            (keep,),
        )
    end
end

function recent_runs(limit::Int = 20)
    safe_limit = clamp(limit, 1, 100)
    database = db()
    rows = Vector{Dict{String, Any}}()
    try
        result = if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "SELECT id, benchmark_type, input_size, duration_ms, result_summary, created_at FROM benchmark_runs ORDER BY created_at DESC LIMIT \$1",
                (safe_limit,),
            )
        else
            DBInterface.execute(
                database,
                "SELECT id, benchmark_type, input_size, duration_ms, result_summary, created_at FROM benchmark_runs ORDER BY created_at DESC LIMIT ?",
                (safe_limit,),
            )
        end
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
        close_db(database)
    end
    return rows
end

function run_count()
    database = db()
    try
        result = DBInterface.execute(database, "SELECT COUNT(*) AS count FROM benchmark_runs")
        for row in result
            return Int(row.count)
        end
    finally
        close_db(database)
    end
    return 0
end

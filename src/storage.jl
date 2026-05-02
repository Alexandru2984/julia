using Dates
using DBInterface
using JSON3
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

function max_queued_jobs()
    raw = get(ENV, "MAX_QUEUED_JOBS", "50")
    try
        return clamp(parse(Int, raw), 1, 500)
    catch
        return 50
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
            DBInterface.execute(database, """
                CREATE TABLE IF NOT EXISTS benchmark_jobs (
                    id BIGSERIAL PRIMARY KEY,
                    benchmark_type TEXT NOT NULL,
                    status TEXT NOT NULL,
                    input_json TEXT NOT NULL,
                    input_size TEXT NOT NULL,
                    duration_ms DOUBLE PRECISION,
                    result_json TEXT,
                    error_message TEXT,
                    created_at TEXT NOT NULL,
                    started_at TEXT,
                    finished_at TEXT
                )
            """)
            DBInterface.execute(database, """
                CREATE INDEX IF NOT EXISTS idx_benchmark_jobs_status_created_at
                ON benchmark_jobs(status, created_at DESC)
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
            DBInterface.execute(database, """
                CREATE TABLE IF NOT EXISTS benchmark_jobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    benchmark_type TEXT NOT NULL,
                    status TEXT NOT NULL,
                    input_json TEXT NOT NULL,
                    input_size TEXT NOT NULL,
                    duration_ms REAL,
                    result_json TEXT,
                    error_message TEXT,
                    created_at TEXT NOT NULL,
                    started_at TEXT,
                    finished_at TEXT
                )
            """)
            DBInterface.execute(database, """
                CREATE INDEX IF NOT EXISTS idx_benchmark_jobs_status_created_at
                ON benchmark_jobs(status, created_at DESC)
            """)
        end
        reset_incomplete_jobs!(database)
    finally
        close_db(database)
    end
end

function reset_incomplete_jobs!(database)
    message = "Service restarted before the job completed"
    finished_at = utc_timestamp()
    if storage_backend() == :postgres
        DBInterface.execute(
            database,
            "UPDATE benchmark_jobs SET status = 'failed', error_message = \$1, finished_at = \$2 WHERE status IN ('queued', 'running')",
            (message, finished_at),
        )
    else
        DBInterface.execute(
            database,
            "UPDATE benchmark_jobs SET status = 'failed', error_message = ?, finished_at = ? WHERE status IN ('queued', 'running')",
            (message, finished_at),
        )
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

function active_job_count()
    database = db()
    try
        result = DBInterface.execute(database, "SELECT COUNT(*) AS count FROM benchmark_jobs WHERE status IN ('queued', 'running')")
        for row in result
            return Int(row.count)
        end
    finally
        close_db(database)
    end
    return 0
end

function create_job!(benchmark_type::String, input_json::String, input_size::String)
    active_job_count() < max_queued_jobs() || throw(ArgumentError("Too many benchmark jobs are already queued"))
    created_at = utc_timestamp()
    database = db()
    try
        if storage_backend() == :postgres
            result = DBInterface.execute(
                database,
                "INSERT INTO benchmark_jobs (benchmark_type, status, input_json, input_size, created_at) VALUES (\$1, 'queued', \$2, \$3, \$4) RETURNING id",
                (benchmark_type, input_json, input_size, created_at),
            )
            for row in result
                return Int(row.id)
            end
        else
            DBInterface.execute(
                database,
                "INSERT INTO benchmark_jobs (benchmark_type, status, input_json, input_size, created_at) VALUES (?, 'queued', ?, ?, ?)",
                (benchmark_type, input_json, input_size, created_at),
            )
            result = DBInterface.execute(database, "SELECT last_insert_rowid() AS id")
            for row in result
                return Int(row.id)
            end
        end
    finally
        close_db(database)
    end
    error("Could not create benchmark job")
end

function mark_job_running!(job_id::Int)
    started_at = utc_timestamp()
    database = db()
    try
        if storage_backend() == :postgres
            DBInterface.execute(database, "UPDATE benchmark_jobs SET status = 'running', started_at = \$1 WHERE id = \$2", (started_at, job_id))
        else
            DBInterface.execute(database, "UPDATE benchmark_jobs SET status = 'running', started_at = ? WHERE id = ?", (started_at, job_id))
        end
    finally
        close_db(database)
    end
end

function complete_job!(job_id::Int, duration_ms::Real, result_json::String)
    finished_at = utc_timestamp()
    database = db()
    try
        if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET status = 'done', duration_ms = \$1, result_json = \$2, finished_at = \$3 WHERE id = \$4",
                (Float64(duration_ms), result_json, finished_at, job_id),
            )
        else
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET status = 'done', duration_ms = ?, result_json = ?, finished_at = ? WHERE id = ?",
                (Float64(duration_ms), result_json, finished_at, job_id),
            )
        end
    finally
        close_db(database)
    end
end

function fail_job!(job_id::Int, message::String)
    finished_at = utc_timestamp()
    safe_message = first(message, min(lastindex(message), 600))
    database = db()
    try
        if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET status = 'failed', error_message = \$1, finished_at = \$2 WHERE id = \$3",
                (safe_message, finished_at, job_id),
            )
        else
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET status = 'failed', error_message = ?, finished_at = ? WHERE id = ?",
                (safe_message, finished_at, job_id),
            )
        end
    finally
        close_db(database)
    end
end

function parse_stored_json(value)
    if value === nothing || value === missing || isempty(String(value))
        return nothing
    end
    return JSON3.read(String(value), Dict{String, Any})
end

function job_to_dict(row)
    return Dict(
        "id" => Int(row.id),
        "benchmark_type" => row.benchmark_type,
        "status" => row.status,
        "input" => parse_stored_json(row.input_json),
        "input_size" => row.input_size,
        "duration_ms" => (row.duration_ms === missing || row.duration_ms === nothing) ? nothing : round(row.duration_ms; digits = 3),
        "result" => parse_stored_json(row.result_json),
        "error" => (row.error_message === missing ? nothing : row.error_message),
        "created_at" => row.created_at,
        "started_at" => (row.started_at === missing ? nothing : row.started_at),
        "finished_at" => (row.finished_at === missing ? nothing : row.finished_at),
    )
end

function get_job(job_id::Int)
    database = db()
    try
        result = if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "SELECT id, benchmark_type, status, input_json, input_size, duration_ms, result_json, error_message, created_at, started_at, finished_at FROM benchmark_jobs WHERE id = \$1",
                (job_id,),
            )
        else
            DBInterface.execute(
                database,
                "SELECT id, benchmark_type, status, input_json, input_size, duration_ms, result_json, error_message, created_at, started_at, finished_at FROM benchmark_jobs WHERE id = ?",
                (job_id,),
            )
        end
        for row in result
            return job_to_dict(row)
        end
    finally
        close_db(database)
    end
    return nothing
end

function recent_jobs(limit::Int = 20)
    safe_limit = clamp(limit, 1, 100)
    database = db()
    rows = Vector{Dict{String, Any}}()
    try
        result = if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "SELECT id, benchmark_type, status, input_json, input_size, duration_ms, result_json, error_message, created_at, started_at, finished_at FROM benchmark_jobs ORDER BY created_at DESC LIMIT \$1",
                (safe_limit,),
            )
        else
            DBInterface.execute(
                database,
                "SELECT id, benchmark_type, status, input_json, input_size, duration_ms, result_json, error_message, created_at, started_at, finished_at FROM benchmark_jobs ORDER BY created_at DESC LIMIT ?",
                (safe_limit,),
            )
        end
        for row in result
            push!(rows, job_to_dict(row))
        end
    finally
        close_db(database)
    end
    return rows
end

using Dates
using DBInterface
using JSON3
using LibPQ
using Random
using SQLite
using UUIDs

# Functions (not consts) so the path is resolved at call time. A const that
# reads ENV would be baked in at precompile time, which both ignores runtime
# JULIA_BENCH_DATA_DIR overrides and makes the storage layer untestable in
# isolation. Production leaves JULIA_BENCH_DATA_DIR unset, so the default holds.
data_dir() = get(ENV, "JULIA_BENCH_DATA_DIR", joinpath(dirname(@__DIR__), "data"))
db_path() = joinpath(data_dir(), "runs.sqlite3")

utc_timestamp() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
new_public_id() = string(uuid4())
new_access_token() = randstring(48)

function storage_backend()
    return isempty(get(ENV, "DATABASE_URL", "")) ? :sqlite : :postgres
end

function open_connection()
    if storage_backend() == :postgres
        conn = DBInterface.connect(LibPQ.Connection, ENV["DATABASE_URL"]; connect_timeout = 5)
        DBInterface.execute(conn, "SET client_min_messages TO warning")
        return conn
    else
        mkpath(data_dir())
        database = SQLite.DB(db_path())
        # Benchmarks run on worker threads and write while read endpoints poll,
        # so concurrent connections contend for SQLite's single writer. WAL plus
        # a busy timeout lets writers wait for the lock instead of failing fast
        # with "database is locked". (Production uses Postgres; this hardens the
        # local-dev fallback.)
        DBInterface.execute(database, "PRAGMA journal_mode = WAL")
        DBInterface.execute(database, "PRAGMA busy_timeout = 5000")
        DBInterface.execute(database, "PRAGMA synchronous = NORMAL")
        return database
    end
end

close_db(database::SQLite.DB) = SQLite.close(database)
close_db(database::LibPQ.DBConnection) = DBInterface.close!(database)

function safe_close(conn)
    try
        close_db(conn)
    catch
    end
    return nothing
end

# --- Connection pooling (Postgres) -----------------------------------------
# A bounded, thread-safe pool of reusable connections. Benchmarks run on worker
# threads and the frontend polls a few times per second, so without pooling
# every request paid a fresh TCP+auth handshake (and create_job! opened two
# connections). The pool is generic over the connection type and its
# open/isalive/close operations so its mechanics are unit-testable without a
# live database.
#
# Only Postgres is pooled. SQLite is cheap to open and the tests rely on each
# call re-resolving JULIA_BENCH_DATA_DIR, so SQLite stays open-per-call.
struct ConnectionPool
    open::Function        # () -> conn
    validate::Function    # conn -> Bool, run on checkout to catch stale idle conns
    close::Function       # conn -> nothing
    max::Int
    slots::Base.Semaphore # bounds total outstanding (idle + checked-out) to max
    idle::Vector{Any}
    lock::ReentrantLock
end

ConnectionPool(open, validate, close, max::Int) =
    ConnectionPool(open, validate, close, max, Base.Semaphore(max), Any[], ReentrantLock())

function checkout!(pool::ConnectionPool)
    Base.acquire(pool.slots)
    conn = lock(pool.lock) do
        isempty(pool.idle) ? nothing : pop!(pool.idle)
    end
    if conn !== nothing
        # A pooled connection may have been dropped server-side while idle (DB
        # restart, idle timeout, NAT). PQstatus alone won't notice until the
        # socket is used, so validate with a real round trip and replace if dead.
        # Freshly opened connections (below) skip this — they are known good.
        pool.validate(conn) && return conn
        pool.close(conn)
    end
    try
        return pool.open()
    catch
        Base.release(pool.slots)  # creating a replacement failed; give the slot back
        rethrow()
    end
end

function checkin!(pool::ConnectionPool, conn)
    # The caller only checks in after a successful operation (with_connection
    # discards on error), so the connection is known good here; pool it directly.
    # Staleness that develops while idle is caught on the next checkout.
    lock(pool.lock) do
        push!(pool.idle, conn)
    end
    Base.release(pool.slots)
    return nothing
end

function discard!(pool::ConnectionPool, conn)
    pool.close(conn)
    Base.release(pool.slots)
    return nothing
end

function db_pool_size()
    raw = get(ENV, "DB_POOL_SIZE", "4")
    try
        return clamp(parse(Int, raw), 1, 16)
    catch
        return 4
    end
end

function pg_validate(conn)
    try
        isopen(conn.conn) || return false
        DBInterface.execute(conn, "SELECT 1")  # authoritative liveness check
        return true
    catch
        return false
    end
end

const PG_POOL = Ref{Any}(nothing)
const PG_POOL_LOCK = ReentrantLock()

function pg_pool()
    return lock(PG_POOL_LOCK) do
        if PG_POOL[] === nothing
            PG_POOL[] = ConnectionPool(open_connection, pg_validate, safe_close, db_pool_size())
        end
        return PG_POOL[]
    end
end

# Run `f(conn)` with a database connection. Postgres connections come from the
# pool (returned on success, discarded on error so a broken connection is never
# reused). SQLite is opened per call and always closed.
function with_connection(f)
    if storage_backend() == :postgres
        pool = pg_pool()
        conn = checkout!(pool)
        ok = false
        try
            result = f(conn)
            ok = true
            return result
        finally
            ok ? checkin!(pool, conn) : discard!(pool, conn)
        end
    else
        database = open_connection()
        try
            return f(database)
        finally
            close_db(database)
        end
    end
end

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
    with_connection() do database
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
                    public_id TEXT,
                    access_token TEXT,
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
            DBInterface.execute(database, "ALTER TABLE benchmark_jobs ADD COLUMN IF NOT EXISTS public_id TEXT")
            DBInterface.execute(database, "ALTER TABLE benchmark_jobs ADD COLUMN IF NOT EXISTS access_token TEXT")
            DBInterface.execute(database, "CREATE UNIQUE INDEX IF NOT EXISTS idx_benchmark_jobs_public_id ON benchmark_jobs(public_id)")
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
                    public_id TEXT,
                    access_token TEXT,
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
            add_sqlite_column_if_missing!(database, "benchmark_jobs", "public_id", "TEXT")
            add_sqlite_column_if_missing!(database, "benchmark_jobs", "access_token", "TEXT")
            DBInterface.execute(database, "CREATE UNIQUE INDEX IF NOT EXISTS idx_benchmark_jobs_public_id ON benchmark_jobs(public_id)")
        end
        backfill_job_access!(database)
        reset_incomplete_jobs!(database)
    end
end

function add_sqlite_column_if_missing!(database, table::String, column::String, type::String)
    columns = Set{String}()
    for row in DBInterface.execute(database, "PRAGMA table_info($table)")
        push!(columns, row.name)
    end
    if !(column in columns)
        DBInterface.execute(database, "ALTER TABLE $table ADD COLUMN $column $type")
    end
end

function backfill_job_access!(database)
    result = DBInterface.execute(database, "SELECT id FROM benchmark_jobs WHERE public_id IS NULL OR access_token IS NULL")
    ids = Int[]
    for row in result
        push!(ids, Int(row.id))
    end
    for id in ids
        public_id = new_public_id()
        access_token = new_access_token()
        if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET public_id = \$1, access_token = \$2 WHERE id = \$3",
                (public_id, access_token, id),
            )
        else
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET public_id = ?, access_token = ? WHERE id = ?",
                (public_id, access_token, id),
            )
        end
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
    with_connection() do database
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
    end
    return nothing
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

function prune_old_jobs!(database)
    keep = retention_limit()
    if storage_backend() == :postgres
        DBInterface.execute(
            database,
            "DELETE FROM benchmark_jobs WHERE id NOT IN (SELECT id FROM benchmark_jobs ORDER BY created_at DESC LIMIT \$1)",
            (keep,),
        )
    else
        DBInterface.execute(
            database,
            "DELETE FROM benchmark_jobs WHERE id NOT IN (SELECT id FROM benchmark_jobs ORDER BY created_at DESC LIMIT ?)",
            (keep,),
        )
    end
end

function recent_runs(limit::Int = 20)
    safe_limit = clamp(limit, 1, 100)
    return with_connection() do database
        rows = Vector{Dict{String, Any}}()
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
        rows
    end
end

# Count helper that runs on an already-checked-out connection, so create_job!
# can enforce the queue cap and insert without a second checkout.
function active_job_count_conn(database)
    result = DBInterface.execute(database, "SELECT COUNT(*) AS count FROM benchmark_jobs WHERE status IN ('queued', 'running')")
    for row in result
        return Int(row.count)
    end
    return 0
end

function run_count()
    return with_connection() do database
        result = DBInterface.execute(database, "SELECT COUNT(*) AS count FROM benchmark_runs")
        for row in result
            return Int(row.count)
        end
        return 0
    end
end

active_job_count() = with_connection(active_job_count_conn)

function create_job!(benchmark_type::String, input_json::String, input_size::String)
    created_at = utc_timestamp()
    public_id = new_public_id()
    access_token = new_access_token()
    return with_connection() do database
        # Enforce the queue cap and insert on the same connection (was two
        # separate connections).
        active_job_count_conn(database) < max_queued_jobs() ||
            throw(ArgumentError("Too many benchmark jobs are already queued"))
        if storage_backend() == :postgres
            result = DBInterface.execute(
                database,
                "INSERT INTO benchmark_jobs (public_id, access_token, benchmark_type, status, input_json, input_size, created_at) VALUES (\$1, \$2, \$3, 'queued', \$4, \$5, \$6) RETURNING id",
                (public_id, access_token, benchmark_type, input_json, input_size, created_at),
            )
            for row in result
                return Dict("id" => Int(row.id), "public_id" => public_id, "access_token" => access_token)
            end
        else
            DBInterface.execute(
                database,
                "INSERT INTO benchmark_jobs (public_id, access_token, benchmark_type, status, input_json, input_size, created_at) VALUES (?, ?, ?, 'queued', ?, ?, ?)",
                (public_id, access_token, benchmark_type, input_json, input_size, created_at),
            )
            result = DBInterface.execute(database, "SELECT last_insert_rowid() AS id")
            for row in result
                return Dict("id" => Int(row.id), "public_id" => public_id, "access_token" => access_token)
            end
        end
        error("Could not create benchmark job")
    end
end

function mark_job_running!(job_id::Int)
    started_at = utc_timestamp()
    with_connection() do database
        if storage_backend() == :postgres
            DBInterface.execute(database, "UPDATE benchmark_jobs SET status = 'running', started_at = \$1 WHERE id = \$2", (started_at, job_id))
        else
            DBInterface.execute(database, "UPDATE benchmark_jobs SET status = 'running', started_at = ? WHERE id = ?", (started_at, job_id))
        end
    end
    return nothing
end

function complete_job!(job_id::Int, duration_ms::Real, result_json::String)
    finished_at = utc_timestamp()
    with_connection() do database
        if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET status = 'done', duration_ms = \$1, result_json = \$2, finished_at = \$3 WHERE id = \$4",
                (Float64(duration_ms), result_json, finished_at, job_id),
            )
            prune_old_jobs!(database)
        else
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET status = 'done', duration_ms = ?, result_json = ?, finished_at = ? WHERE id = ?",
                (Float64(duration_ms), result_json, finished_at, job_id),
            )
            prune_old_jobs!(database)
        end
    end
    return nothing
end

function fail_job!(job_id::Int, message::String)
    finished_at = utc_timestamp()
    safe_message = first(message, min(lastindex(message), 600))
    with_connection() do database
        if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET status = 'failed', error_message = \$1, finished_at = \$2 WHERE id = \$3",
                (safe_message, finished_at, job_id),
            )
            prune_old_jobs!(database)
        else
            DBInterface.execute(
                database,
                "UPDATE benchmark_jobs SET status = 'failed', error_message = ?, finished_at = ? WHERE id = ?",
                (safe_message, finished_at, job_id),
            )
            prune_old_jobs!(database)
        end
    end
    return nothing
end

function parse_stored_json(value)
    if value === nothing || value === missing || isempty(String(value))
        return nothing
    end
    return JSON3.read(String(value), Dict{String, Any})
end

function job_to_dict(row)
    return Dict(
        "id" => row.public_id,
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

function job_summary_to_dict(row)
    public_id = String(row.public_id)
    return Dict(
        "id" => public_id,
        "label" => first(public_id, 8),
        "benchmark_type" => row.benchmark_type,
        "status" => row.status,
        "input_size" => row.input_size,
        "duration_ms" => (row.duration_ms === missing || row.duration_ms === nothing) ? nothing : round(row.duration_ms; digits = 3),
        "created_at" => row.created_at,
        "started_at" => (row.started_at === missing ? nothing : row.started_at),
        "finished_at" => (row.finished_at === missing ? nothing : row.finished_at),
    )
end

function get_job(public_id::String, access_token::String)
    return with_connection() do database
        result = if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "SELECT public_id, benchmark_type, status, input_json, input_size, duration_ms, result_json, error_message, created_at, started_at, finished_at FROM benchmark_jobs WHERE public_id = \$1 AND access_token = \$2",
                (public_id, access_token),
            )
        else
            DBInterface.execute(
                database,
                "SELECT public_id, benchmark_type, status, input_json, input_size, duration_ms, result_json, error_message, created_at, started_at, finished_at FROM benchmark_jobs WHERE public_id = ? AND access_token = ?",
                (public_id, access_token),
            )
        end
        for row in result
            return job_to_dict(row)
        end
        return nothing
    end
end

function recent_jobs(limit::Int = 20)
    safe_limit = clamp(limit, 1, 100)
    return with_connection() do database
        rows = Vector{Dict{String, Any}}()
        result = if storage_backend() == :postgres
            DBInterface.execute(
                database,
                "SELECT public_id, benchmark_type, status, input_size, duration_ms, created_at, started_at, finished_at FROM benchmark_jobs ORDER BY created_at DESC LIMIT \$1",
                (safe_limit,),
            )
        else
            DBInterface.execute(
                database,
                "SELECT public_id, benchmark_type, status, input_size, duration_ms, created_at, started_at, finished_at FROM benchmark_jobs ORDER BY created_at DESC LIMIT ?",
                (safe_limit,),
            )
        end
        for row in result
            push!(rows, job_summary_to_dict(row))
        end
        rows
    end
end

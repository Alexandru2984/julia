using DBInterface
using LibPQ
using SQLite

include(joinpath(@__DIR__, "..", "src", "storage.jl"))

function main()
    haskey(ENV, "DATABASE_URL") || error("DATABASE_URL is required")
    isfile(db_path()) || begin
        println("No SQLite database found at $(db_path()); nothing to migrate")
        return
    end

    init_storage!()

    pg = DBInterface.connect(LibPQ.Connection, ENV["DATABASE_URL"]; connect_timeout = 5)
    sqlite = SQLite.DB(db_path())
    migrated = 0
    try
        existing = first(DBInterface.execute(pg, "SELECT COUNT(*) AS count FROM benchmark_runs")).count
        if existing > 0
            println("PostgreSQL already has $existing rows; skipping migration")
            return
        end

        rows = DBInterface.execute(
            sqlite,
            "SELECT benchmark_type, input_size, duration_ms, result_summary, created_at FROM benchmark_runs ORDER BY id ASC",
        )
        for row in rows
            DBInterface.execute(
                pg,
                "INSERT INTO benchmark_runs (benchmark_type, input_size, duration_ms, result_summary, created_at) VALUES (\$1, \$2, \$3, \$4, \$5)",
                (row.benchmark_type, row.input_size, Float64(row.duration_ms), row.result_summary, row.created_at),
            )
            migrated += 1
        end
    finally
        DBInterface.close!(pg)
        SQLite.close(sqlite)
    end

    println("Migrated $migrated rows from SQLite to PostgreSQL")
end

main()

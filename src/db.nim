import tiny_sqlite
import options

let migrations: seq[string] = @[
    """
    CREATE TABLE sites (
        sid INTEGER PRIMARY KEY,
        url TEXT NOT NULL
    );

    CREATE TABLE reqs (
        rid INTEGER PRIMARY KEY,
        site INTEGER NOT NULL REFERENCES sites(sid),
        timestamp INTEGER NOT NULL,
        status INTEGER NOT NULL,
        latency INTEGER NOT NULL
    );
    """,
    """
    CREATE INDEX req_ts_idx ON reqs (timestamp);
    """
]

proc migrate*(db: DbConn) =
    let currentVersion = fromDbValue(get db.value("PRAGMA user_version"), int)
    for mid in (currentVersion + 1) .. migrations.len:
        db.transaction:
            echo "Migrating to schema " & $mid
            db.execScript migrations[mid - 1]
            # for some reason this pragma does not work using normal parameter binding
            db.exec("PRAGMA user_version = " & $mid)
    echo "DB ready"
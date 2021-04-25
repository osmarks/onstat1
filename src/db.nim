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
    """,
    # rolling total/successful ping and latency count
    # rc_data_since holds the older end of the interval the counters are from
    # this slightly horribly migrates the existing data using a hardcoded 1 week window
    """
ALTER TABLE sites ADD COLUMN rc_total INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sites ADD COLUMN rc_success INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sites ADD COLUMN rc_latency INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sites ADD COLUMN rc_data_since INTEGER;
UPDATE sites SET rc_total = (SELECT COUNT(*) FROM reqs WHERE site = sid AND timestamp >= (strftime('%s') - (86400*7)) * 1000000);
UPDATE sites SET rc_success = (SELECT SUM(status <= 0) FROM reqs WHERE site = sid AND timestamp >= (strftime('%s') - (86400*7)) * 1000000);
UPDATE sites SET rc_latency = (SELECT SUM(latency) FROM reqs WHERE site = sid AND timestamp >= (strftime('%s') - (86400*7)) * 1000000);
UPDATE sites SET rc_data_since = (strftime('%s') - (86400*7)) * 1000000;
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
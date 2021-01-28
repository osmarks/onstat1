import options
import asyncdispatch
import asynchttpserver
import tiny_sqlite
import macros
import times
import karax/[karaxdsl, vdom]
import httpclient
import sugar
import net
import sequtils
import strformat

import ./db

macro includeFile(x: string): string = newStrLitNode(readFile(x.strVal))

const css = includeFile("./src/style.css")
let database = openDatabase("./monitoring.sqlite3")
migrate(database)

var threadDB {.threadvar.}: Option[DbConn]
proc getDB(): DbConn =
    if isNone threadDB:
        let x = openDatabase("./monitoring.sqlite3")
        x.exec("PRAGMA journal_mode=WAL")
        threadDB = some x
    get threadDB

func timeToTimestamp*(t: Time): int64 = toUnix(t) * 1000000 + (nanosecond(t) div 1000)
func timestampToTime*(ts: int64): Time = initTime(ts div 1000000, (ts mod 1000000) * 1000)

proc toDbValue(t: Time): DbValue = DbValue(kind: sqliteInteger, intVal: timeToTimestamp(t))
proc fromDbValue(value: DbValue, T: typedesc[Time]): Time = timestampToTime(value.intVal)

type
    ResponseType = enum
        rtOk = 0
        rtHttpError = 1
        rtTimeout = 2
        rtFetchError = 3
    Response = object
        rtype: ResponseType
        latency: int64 # microseconds
    SiteStatus = object
        url: string
        lastPing: Time
        lastResponse: ResponseType
        lastLatency: float
        uptimePercent: float

proc uptimeSince(sid: int, time: Time): float =
    let okPings = fromDbValue(get getDB().value("SELECT COUNT(*) FROM reqs WHERE site = ? AND status = 0", sid), int)
    let totalPings = fromDbValue(get getDB().value("SELECT COUNT(*) FROM reqs WHERE site = ?", sid), int)
    okPings / totalPings

proc fetchLatest(row: ResultRow): Option[SiteStatus] =
    let weekAgo = getTime() + initTimeInterval(weeks= -1)
    let (site, url) = row.unpack((int, string))
    let row = getDB().one("SELECT timestamp, status, latency FROM reqs WHERE site = ? ORDER BY timestamp DESC LIMIT 1", site)
    if isNone row: return none(SiteStatus)
    let (ts, status, latency) = (get row).unpack((Time, int, int))
    some SiteStatus(url: url, lastPing: ts, lastResponse: ResponseType(status), lastLatency: float64(latency) / 1e3, uptimePercent: uptimeSince(site, weekAgo))

proc mainPage(): string =
    let sites = getDB().all("SELECT * FROM sites ORDER BY sid").map(fetchLatest).filter(x => isSome x).map(x => get x)
    let up = sites.filter(x => x.lastResponse == rtOk).len()
    let vnode = buildHtml(html()):
        head:
            meta(charset="utf8")
            title: text &"{up}/{sites.len} up - OnStat"
            style: text css
        body:
            h1(class="title"): text "OnStat"
            h2(class="title"): text &"{up}/{sites.len} up"
            for site in sites:
                tdiv(class="card " & $site.lastResponse):
                    h2:
                        case site.lastResponse
                        of rtOk: text "✓ "
                        of rtHttpError: text "⚠ "
                        of rtTimeout: text "✕ "
                        of rtFetchError: text "✕ "
                        text site.url
                    tdiv: text("Last pinged " & format(site.lastPing, "HH:mm:ss dd-MM-yyyy"))
                    tdiv:
                        case site.lastResponse
                        of rtOk: text &"Latency {site.lastLatency}ms"
                        of rtHttpError: text "HTTP error"
                        of rtTimeout: text "Timed out"
                        of rtFetchError: text "Fetch failed"
                    tdiv: text &"{site.uptimePercent * 100}% up in last week"
    $vnode

proc onRequest(req: Request) {.async.} =
    if req.reqMethod == HttpGet:
        case req.url.path
        of "/": await req.respond(Http200, mainPage(), headers=newHttpHeaders([("Content-Type", "text/html")]))
        else: await req.respond(Http404, "not found")
    else:
        await req.respond(Http404, "not found")

proc pollTarget(s: string): Future[Response] {.async.} =
    var client = newAsyncHttpClient()
    var x = Response(rtype: rtTimeout, latency: 0)
    proc doFetch() {.async.} =
        let ts = now().utc
        let res = await client.get(s)
        let latency = (now().utc - ts).inMicroseconds
        if res.code.is4xx or res.code.is5xx: x = Response(rtype: rtHttpError, latency: latency)
        else: x = Response(rtype: rtOk, latency: latency)
    try:
        discard await withTimeout(doFetch(), 10000)
    except:
        x = Response(rtype: rtFetchError, latency: 0)
    return x

proc pollTargets() {.async.} =
    for row in getDB().all("SELECT * FROM sites"):
        let (id, url) = row.unpack((int64, string))
        let res = await pollTarget(url)
        getDB().exec("INSERT INTO reqs (site, timestamp, status, latency) VALUES (?, ?, ?, ?)", id, getTime(), int(res.rtype), res.latency)

proc timerCallback(fd: AsyncFD): bool =
    asyncCheck pollTargets()
    false

echo "Starting up"
asyncCheck pollTargets()
addTimer(5000, false, timerCallback)
var server = newAsyncHttpServer()
waitFor server.serve(Port(7800), onRequest)
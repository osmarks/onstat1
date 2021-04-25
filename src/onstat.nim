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
import strutils
import cligen
import imageman
import math
import hashes
import tables

import ./db

macro includeFile(x: string): string = newStrLitNode(readFile(x.strVal))

const css = includeFile("./src/style.css")

func timeToTimestamp*(t: Time): int64 = toUnix(t) * 1000000 + (nanosecond(t) div 1000)
func timestampToTime*(ts: int64): Time = initTime(ts div 1000000, (ts mod 1000000) * 1000)

proc toDbValue(t: Time): DbValue = DbValue(kind: sqliteInteger, intVal: timeToTimestamp(t))
proc fromDbValue(value: DbValue, T: typedesc[Time]): Time = timestampToTime(value.intVal)

type
    ResponseType {.pure.} = enum
        HttpTeapot = -1
        Ok = 0
        HttpError = 1
        Timeout = 2
        FetchError = 3
    Response = object
        rtype: ResponseType
        latency: int64 # microseconds
    SiteStatus = object
        id: int
        url: string
        lastPing: Time
        lastResponse: ResponseType
        lastLatency: float
        uptimePercent: float
        averageLatency: float
    Ctx = object
        db: DbConn
        dbPath: string
        images: TableRef[int, (seq[byte], int)]
        interval: int

proc fetchLatest(ctx: Ctx, row: ResultRow): Option[SiteStatus] =
    let weekAgo = getTime() + initTimeInterval(weeks= -1)
    let (site, url, rollingTotalPings, rollingSuccessfulPings, rollingLatency, rollingDataSince) = row.unpack((int, string, int64, int64, int64, int64))
    # work around bizarre SQLite query planner issue - it appears that if it has a literal value to compare site against it generates very fast VM code
    # but if it has a prepared state parameter it somehow refuses to use the index
    let row = ctx.db.one("SELECT timestamp, status, latency FROM reqs WHERE site = -1 OR site = ? ORDER BY timestamp DESC LIMIT 1", site)
    if isNone row: return none(SiteStatus)
    let (ts, status, latency) = (get row).unpack((Time, int, int))
    some SiteStatus(url: url, lastPing: ts, lastResponse: ResponseType(status), lastLatency: float(latency) / 1e3, id: site,
        uptimePercent: float(rollingSuccessfulPings) / float(rollingTotalPings), averageLatency: float(rollingLatency) / float(rollingTotalPings) / 1e3)

proc mainPage(ctx: Ctx): string =
    let sites = ctx.db.all("SELECT * FROM sites ORDER BY sid").map(x => ctx.fetchLatest(x)).filter(x => x.isSome).map(x => x.get)
    let up = sites.filter(x => int(x.lastResponse) <= 0).len()
    let vnode = buildHtml(html()):
        head:
            meta(charset="utf8")
            meta(http-equiv="refresh", content="60")
            meta(name="viewport", content="width=device-width, initial-scale=1")
            title: text &"{up}/{sites.len} up - OnStat"
            style: text css
        body:
            h1(class="title"): text "OnStat"
            h2(class="title"): text &"{up}/{sites.len} up"
            for site in sites:
                tdiv(class="card " & $site.lastResponse):
                    tdiv(class="left"):
                        h2:
                            case site.lastResponse
                            of ResponseType.Ok: text "✓ "
                            of ResponseType.HttpError: text "⚠ "
                            of ResponseType.Timeout: text "✕ "
                            of ResponseType.FetchError: text "✕ "
                            of ResponseType.HttpTeapot: text "🫖 "
                            text site.url
                        tdiv: text("Last pinged " & format(site.lastPing, "HH:mm:ss dd-MM-yyyy"))
                        tdiv:
                            case site.lastResponse
                            of ResponseType.Ok: text &"Latency {site.lastLatency}ms"
                            of ResponseType.HttpError: text "HTTP error"
                            of ResponseType.HttpTeapot: text &"Teapot, latency {site.lastLatency:.5f}ms"
                            of ResponseType.Timeout: text "Timed out"
                            of ResponseType.FetchError: text "Fetch failed"
                        tdiv: text &"{site.uptimePercent * 100:.5f}% up, {site.averageLatency:.5f}ms latency in last week"
                    if site.id in ctx.images: img(src= &"/vis/{site.id}", class="right", title= &"{site.url} 12-week status visualization")
            hr()
            small:
                text "made by "
                a(href="https://osmarks.net"): text "gollark"
                text ", currently hosted by "
                a(href="https://ubq323.website"): text "ubq323"
                text "."
    $vnode

var imageReturnChannel: Channel[(int, seq[byte])]

proc readIntoContext(ctx: Ctx) =
    # this is a horrible workaround to avoid having to something something shared hash table
    var available = true
    while available:
        let (av, data) = imageReturnChannel.tryRecv()
        available = av
        if available:
            let (id, image) = data
            ctx.images[id] = (image, image.hash)

proc onRequest(ctx: Ctx): (proc(req: Request): Future[void] {.gcsafe.}) =
    result = proc(req: Request) {.async.} =
        readIntoContext(ctx)
        if req.reqMethod == HttpGet:
            var path = req.url.path
            if path == "/":
                await req.respond(Http200, mainPage(ctx), headers=newHttpHeaders([("Content-Type", "text/html")]))
            elif path.startsWith("/vis/"):
                path.removePrefix("/vis/")
                var id = 0
                try:
                    id = parseInt path
                except:
                    await req.respond(Http404, "not found")
                    return
                if id in ctx.images:
                    let (image, hash) = ctx.images[id]
                    let etag = &"\"{hash}\""
                    if etag == req.headers.getOrDefault("if-none-match"):
                        await req.respond(Http304, "")
                    else:
                        await req.respond(Http200, cast[string](image), headers=newHttpHeaders([
                            ("Content-Type", "image/png"), ("ETag", etag)]))
                else: await req.respond(Http404, "not found")
            else: await req.respond(Http404, "not found")
        else:
            await req.respond(Http405, "GET only")

proc pollTarget(ctx: Ctx, s: string): Future[Response] {.async.} =
    var client = newAsyncHttpClient()
    var x = Response(rtype: ResponseType.Timeout, latency: 0)
    proc doFetch() {.async.} =
        let ts = now().utc
        let res = await client.get(s)
        let latency = (now().utc - ts).inMicroseconds
        if res.code.int == 418: x = Response(rtype: ResponseType.HttpTeapot, latency: latency)
        elif res.code.is4xx or res.code.is5xx: x = Response(rtype: ResponseType.HttpError, latency: latency)
        else: x = Response(rtype: ResponseType.Ok, latency: latency)
    try:
        discard await withTimeout(doFetch(), 10000)
    except:
        x = Response(rtype: ResponseType.FetchError, latency: 0)
    client.close()
    return x

proc pollTargets(ctx: Ctx) {.async.} =
    for row in ctx.db.all("SELECT * FROM sites"):
        var (id, url, rollingTotalPings, rollingSuccessfulPings, rollingLatency, rollingDataSince) = row.unpack((int64, string, int64, int64, int64, Option[Time]))
        let res = await ctx.pollTarget(url)
        let threshold = getTime() + initTimeInterval(weeks= -1)

        # drop old data from rolling counters
        if rollingDataSince.isSome:
            for row in ctx.db.iterate("SELECT status, latency FROM reqs WHERE timestamp >= ? AND timestamp <= ? AND site = ?", rollingDataSince.get, threshold, id):
                let (statusRaw, latency) = row.unpack((int, int))
                rollingTotalPings -= 1
                rollingLatency -= latency
                if statusRaw <= 0:
                    rollingSuccessfulPings -= 1
        
        # add new data
        rollingTotalPings += 1
        rollingLatency += res.latency
        if int(res.rtype) <= 0:
            rollingSuccessfulPings += 1

        ctx.db.transaction:
            ctx.db.exec("UPDATE sites SET rc_total = ?, rc_success = ?, rc_latency = ?, rc_data_since = ? WHERE sid = ?", rollingTotalPings, rollingSuccessfulPings, rollingLatency, threshold, id)
            ctx.db.exec("INSERT INTO reqs (site, timestamp, status, latency) VALUES (?, ?, ?, ?)", id, getTime(), int(res.rtype), res.latency)

proc drawLatencyImage(db: DbConn, site: int, interval: int): seq[byte] =
    const width = 120 * 6
    const height = 168 * 2
    var image = initImage[ColorRGBU](width, height)
    var count = 0
    var lastTs = getTime()
    for row in db.iterate("SELECT timestamp, status, latency FROM reqs WHERE site = ? ORDER BY timestamp DESC LIMIT ?", site, width * height):
        let (ts, statusRaw, latency) = row.unpack((Time, int, int))
        let timeGap = lastTs - ts
        if timeGap > initDuration(milliseconds = interval + 10000):
            let pixels = timeGap.inMilliseconds div interval
            for _ in 1..pixels:
                image.data[count] = ColorRGBU([0x7Eu8, 0x1E, 0x9C])
                count += 1
                if count >= image.data.len: break
        else:
            let status = ResponseType(statusRaw)
            case status
            of ResponseType.HttpError:
                image.data[count] = ColorRGBU([255u8, 127, 0])
            of ResponseType.Timeout:
                image.data[count] = ColorRGBU([0u8, 0, 0])
            of ResponseType.FetchError:
                image.data[count] = ColorRGBU([255u8, 0, 0])
            else:
                let latencyMultiplier = max(min(pow(10.0, 1.1) / pow(float(latency), 0.25), 1.0), 0.2)
                image.data[count] = ColorRGBU([0u8, uint8(latencyMultiplier * 255.0), 0])

            count += 1
            if count >= image.data.len: break
        lastTs = ts
    writePNG(image, compression=6)

proc generateImages(args: (string, int)) =
    let (dbPath, interval) = args
    let db = openDatabase(dbPath)
    db.exec("PRAGMA journal_mode = WAL")
    for row in db.all("SELECT sid FROM sites"):
        let id = row[0].fromDbValue(int)
        imageReturnChannel.send((id, drawLatencyImage(db, id, interval)))
    close(db)

proc run(dbPath="./monitoring.sqlite3", port=7800, interval=30000, urls: seq[string]) =
    ## Run onstat. Note that the URLs you configure will be persisted in the monitoring database. To remove them, you must manually update this.
    let database = openDatabase(dbPath)
    database.exec("PRAGMA journal_mode = WAL")
    migrate(database)
    for url in urls:
        echo &"Adding {url}"
        database.exec("INSERT INTO sites (url) VALUES (?)", url)

    var ctx = Ctx(db: database, dbPath: dbPath, images: newTable[int, (seq[byte], int)](), interval: interval)

    echo "Starting up"
    asyncCheck pollTargets(ctx)
    imageReturnChannel.open()
    var thread: Thread[(string, int)]
    createThread(thread, generateImages, (dbPath, interval))
    echo "Ready"
    addTimer(interval, false, proc(fd: AsyncFD): bool =
        asyncCheck pollTargets(ctx)
        false)
    addTimer(interval * 60, false, proc(fd: AsyncFD): bool =
        createThread(thread, generateImages, (dbPath, interval))
        let fut = sleepAsync(10000)
        fut.addCallback(() => readIntoContext(ctx))
        asyncCheck fut
        false)
    var server = newAsyncHttpServer()
    waitFor server.serve(Port(port), onRequest(ctx))
dispatch(run, help={
    "dbPath": "path to SQLite3 database for historical data logging",
    "port": "port to serve HTTP on",
    "interval": "interval at which to poll other services (milliseconds)"
})
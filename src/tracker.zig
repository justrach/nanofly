//! The flights followed, kept up to date: each one's route found (its
//! airline's routes fetched once), then where it is asked of adsb.lol, and
//! of OpenSky where adsb.lol hears nothing. Answers come on the main thread
//! (nanoui.http); `redraw` is called after each.
const std = @import("std");
const nanoui = @import("nanoui");
const http = nanoui.http;
const data = @import("data.zig");
const sources = @import("sources.zig");
const flight = @import("flight.zig");

const Flight = flight.Flight;

/// The wall clock, unix seconds.
pub fn now() f64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

const user_agent: http.Header = .{ .name = "User-Agent", .value = "nanofly/0.1 (+https://github.com/justrach/nanoui)" };

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    d: *const data.Data,
    flights: std.ArrayList(Flight) = .empty,
    next_id: u32 = 1,
    /// Each airline's routes (standing data's CSV), by its ICAO code.
    routes: std.StringHashMapUnmanaged(Routes) = .empty,
    opensky: OpenSky = .{},
    /// Asks nothing (tests).
    offline: bool = false,
    redraw_ctx: ?*anyopaque = null,
    redraw_fn: ?*const fn (?*anyopaque) void = null,

    pub const Routes = union(enum) { asking, missing, csv: []u8 };

    pub const OpenSky = struct {
        id: []const u8 = "",
        secret: []const u8 = "",
        token: [4096]u8 = undefined,
        token_len: usize = 0,
        expires: f64 = 0,
        asking: bool = false,

        fn hasClient(o: *const OpenSky) bool {
            return o.id.len > 0 and o.secret.len > 0;
        }
    };

    pub fn deinit(t: *Tracker) void {
        var it = t.routes.iterator();
        while (it.next()) |e| {
            t.gpa.free(e.key_ptr.*);
            if (e.value_ptr.* == .csv) t.gpa.free(e.value_ptr.csv);
        }
        t.routes.deinit(t.gpa);
        t.flights.deinit(t.gpa);
    }

    fn redraw(t: *Tracker) void {
        if (t.redraw_fn) |f| f(t.redraw_ctx);
    }

    pub fn find(t: *Tracker, id: u32) ?*Flight {
        for (t.flights.items) |*f| if (f.id == id) return f;
        return null;
    }

    /// Follows the flight `q` (once: asked again, the one already followed).
    pub fn add(t: *Tracker, q: flight.Query) !u32 {
        for (t.flights.items) |f| if (std.mem.eql(u8, f.query.airline.slice(), q.airline.slice()) and std.mem.eql(u8, f.query.number.slice(), q.number.slice())) return f.id;
        const id = t.next_id;
        t.next_id += 1;
        try t.flights.append(t.gpa, .init(id, q));
        t.step(&t.flights.items[t.flights.items.len - 1]);
        return id;
    }

    pub fn remove(t: *Tracker, id: u32) void {
        for (t.flights.items, 0..) |f, k| if (f.id == id) {
            _ = t.flights.orderedRemove(k);
            return;
        };
    }

    /// Asks after every flight not being asked after already.
    pub fn poll(t: *Tracker) void {
        for (t.flights.items) |*f| t.step(f);
    }

    /// The airlines the query may mean, in the order tried.
    fn candidates(t: *Tracker, q: flight.Query, out: []u32) usize {
        const code = q.airline.slice();
        if (code.len == 3) {
            const k = t.d.airline_by_icao.get(code) orelse return 0;
            out[0] = k;
            return 1;
        }
        return t.d.airlinesFor(code, out);
    }

    /// The flight's next request: its route, else where it is.
    fn step(t: *Tracker, f: *Flight) void {
        if (f.asking or t.offline) return;
        if (f.from == null and !f.no_route) {
            var cands: [8]u32 = undefined;
            const n = t.candidates(f.query, &cands);
            while (f.tried < n) {
                const airline = &t.d.airlines[cands[f.tried]];
                var cs_buf: [8]u8 = undefined;
                const cs = std.fmt.bufPrint(&cs_buf, "{s}{s}", .{ airline.icao, f.query.number.slice() }) catch return;
                if (f.tried == 0) {
                    f.callsign.set(cs);
                    f.airline = cands[0];
                }
                const csv = switch (t.routes.get(airline.icao) orelse return t.askRoutes(airline.icao)) {
                    .asking => return,
                    .missing => {
                        f.tried += 1;
                        continue;
                    },
                    .csv => |csv| csv,
                };
                if (sources.routeOf(csv, cs)) |codes| if (f.setRoute(t.d, codes)) {
                    f.callsign.set(cs);
                    f.airline = cands[f.tried];
                    break;
                };
                f.tried += 1;
            }
            if (f.from == null) f.no_route = true;
        }
        if (f.callsign.len == 0) return;
        t.askAdsb(f);
    }

    // Requests and their answers.

    const Ask = struct {
        t: *Tracker,
        id: u32 = 0,
        airline: [3]u8 = undefined,
    };

    fn ask(t: *Tracker) ?*Ask {
        const a = t.gpa.create(Ask) catch return null;
        a.* = .{ .t = t };
        return a;
    }

    fn askRoutes(t: *Tracker, icao: []const u8) void {
        const key = t.gpa.dupe(u8, icao) catch return;
        t.routes.put(t.gpa, key, .asking) catch return t.gpa.free(key);
        const a = t.ask() orelse return;
        @memcpy(&a.airline, icao[0..3]);
        var buf: [160]u8 = undefined;
        http.fetch(t.gpa, .{ .url = sources.routesUrl(&buf, icao), .headers = &.{user_agent} }, a, routesAnswered);
    }

    fn routesAnswered(a: *Ask, r: http.Response) void {
        const t = a.t;
        defer t.gpa.destroy(a);
        if (t.routes.getPtr(&a.airline)) |v| {
            v.* = .missing;
            if (r.status == 200 and r.body.len > 0) if (t.gpa.dupe(u8, r.body)) |csv| {
                v.* = .{ .csv = csv };
            } else |_| {};
        }
        // Those waiting on it go on (to the next airline, if not there).
        for (t.flights.items) |*f| if (f.from == null and !f.no_route) t.step(f);
        t.redraw();
    }

    fn askAdsb(t: *Tracker, f: *Flight) void {
        const a = t.ask() orelse return;
        a.id = f.id;
        f.asking = true;
        var buf: [96]u8 = undefined;
        http.fetch(t.gpa, .{ .url = sources.adsbUrl(&buf, f.callsign.slice()), .headers = &.{user_agent}, .timeout = 15 }, a, adsbAnswered);
    }

    fn adsbAnswered(a: *Ask, r: http.Response) void {
        const t = a.t;
        defer t.gpa.destroy(a);
        const f = t.find(a.id) orelse return;
        f.asking = false;
        if (r.status == 200) if (sources.parseAdsb(t.gpa, r.body)) |l| {
            heard(t, f, l);
            return t.redraw();
        };
        // adsb.lol doesn't hear it: OpenSky, over its route.
        if (f.from != null) t.askOpenSky(f);
        t.redraw();
    }

    fn askOpenSky(t: *Tracker, f: *Flight) void {
        const o = &t.opensky;
        if (o.hasClient() and o.expires < now() + 60) return t.askToken();
        const a_pos = f.origin(t.d).?.pos;
        const b_pos = f.destination(t.d).?.pos;
        const a = t.ask() orelse return;
        a.id = f.id;
        f.asking = true;
        var url: [192]u8 = undefined;
        var auth: [4200]u8 = undefined;
        var headers: [2]http.Header = .{ user_agent, undefined };
        var n: usize = 1;
        if (o.token_len > 0) {
            headers[1] = .{ .name = "Authorization", .value = std.fmt.bufPrint(&auth, "Bearer {s}", .{o.token[0..o.token_len]}) catch "" };
            n = 2;
        }
        http.fetch(t.gpa, .{ .url = sources.openskyUrl(&url, a_pos, b_pos), .headers = headers[0..n], .timeout = 20 }, a, openskyAnswered);
    }

    fn openskyAnswered(a: *Ask, r: http.Response) void {
        const t = a.t;
        defer t.gpa.destroy(a);
        const f = t.find(a.id) orelse return;
        f.asking = false;
        // A token turned down: a new one next time.
        if (r.status == 401) t.opensky.expires = 0;
        if (r.status == 200) if (sources.parseOpenSky(t.gpa, r.body, f.callsign.slice())) |l| heard(t, f, l);
        t.redraw();
    }

    fn askToken(t: *Tracker) void {
        const o = &t.opensky;
        if (o.asking) return;
        const a = t.ask() orelse return;
        o.asking = true;
        var body: [512]u8 = undefined;
        http.fetch(t.gpa, .{
            .url = sources.opensky_token_url,
            .method = "POST",
            .headers = &.{ user_agent, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" } },
            .body = sources.tokenBody(&body, o.id, o.secret),
        }, a, tokenAnswered);
    }

    fn tokenAnswered(a: *Ask, r: http.Response) void {
        const t = a.t;
        defer t.gpa.destroy(a);
        const o = &t.opensky;
        o.asking = false;
        if (r.status == 200) if (sources.parseToken(t.gpa, r.body, &o.token)) |tok| {
            o.token_len = tok.token.len;
            o.expires = now() + tok.expires_s;
        } else {
            // No token: asked without one (fewer requests a day).
            o.id = "";
        } else o.id = "";
        // Those waiting go on.
        for (t.flights.items) |*f| if (f.live == null and f.from != null and !f.asking) t.askOpenSky(f);
    }
};

fn heard(t: *Tracker, f: *Flight, l: sources.Live) void {
    const at = now();
    const first = f.live == null;
    f.live = l;
    f.chooseLeg(t.d, l.pos, l.track);
    f.heard_at = at;
    if (l.on_ground or f.airborne_since != 0) return;
    f.airborne_since = at - l.age_s;
    // Already on its way when first heard: when it took off, from how far
    // it has flown (at most of its speed now) and a climb.
    const from = f.origin(t.d) orelse return;
    const flown = @import("geo.zig").distanceKm(from.pos, l.pos);
    if (first and flown > 30) {
        const kmh = @max(l.gs_kt * @import("geo.zig").km_per_nm * 0.9, 500);
        f.airborne_since = at - (flown / kmh * 3600 + 4 * 60);
        f.takeoff_estimated = true;
    }
}

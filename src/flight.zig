//! A flight followed: what was asked ("JL 121"), its callsign on the radio
//! ("JAL121"), its route, where it was last heard, and what that makes it:
//! not yet flying, in the air (and when it should land), landed.
const std = @import("std");
const geo = @import("geo.zig");
const data = @import("data.zig");
const sources = @import("sources.zig");

const Small = sources.Small;

/// A flight number as typed: an airline's code (IATA "JL" or ICAO "JAL")
/// and a number ("121", "6021", "1500A").
pub const Query = struct {
    airline: Small(3),
    number: Small(5),

    pub fn parse(s: []const u8) ?Query {
        var compact: [16]u8 = undefined;
        var n: usize = 0;
        for (s) |ch| {
            if (ch == ' ' or ch == '-') continue;
            if (n == compact.len) return null;
            compact[n] = std.ascii.toUpper(ch);
            n += 1;
        }
        const t = compact[0..n];
        // The airline: three letters (ICAO), or two characters (IATA,
        // one of them may be a digit: "U2", "9W") followed by a digit.
        var split: usize = 0;
        if (t.len >= 4 and std.ascii.isAlphabetic(t[0]) and std.ascii.isAlphabetic(t[1]) and std.ascii.isAlphabetic(t[2]) and std.ascii.isDigit(t[3])) {
            split = 3;
        } else if (t.len >= 3 and std.ascii.isAlphanumeric(t[0]) and std.ascii.isAlphanumeric(t[1]) and std.ascii.isDigit(t[2]) and !(std.ascii.isDigit(t[0]) and std.ascii.isDigit(t[1]))) {
            split = 2;
        } else return null;
        var num = t[split..];
        if (num.len == 0 or num.len > 5) return null;
        for (num, 0..) |ch, k| if (!(std.ascii.isDigit(ch) or (k == num.len - 1 and std.ascii.isAlphabetic(ch)))) return null;
        // Callsigns leave out a number's leading zeros ("JL0121" flies as JAL121).
        while (num.len > 1 and num[0] == '0') num = num[1..];
        return .{ .airline = .init(t[0..split]), .number = .init(num) };
    }
};

pub const Phase = enum {
    /// Its route is being looked up.
    finding,
    /// Not heard yet: on the ground, or not yet in the air.
    waiting,
    taxiing,
    airborne,
    landed,
    /// Heard in the air, not since, away from its destination.
    lost,
    /// No airline or route of that number.
    unknown,
};

pub const Flight = struct {
    /// Which flight this is, for answers that come back later.
    id: u32,
    query: Query,
    /// How it is shown: "JL 121".
    label: Small(10) = .{},
    /// On the radio: the operating airline's ICAO code and the number.
    callsign: Small(8) = .{},
    airline: ?u32 = null,
    /// The leg shown, of its route's stops.
    from: ?u32 = null,
    to: ?u32 = null,
    stops: [6]u32 = undefined,
    n_stops: u8 = 0,
    /// Airlines tried for its route (by `data.Data.airlinesFor`), and whether
    /// none had it.
    tried: u8 = 0,
    no_route: bool = false,
    live: ?sources.Live = null,
    /// When it was last heard (unix seconds), when it was first heard in
    /// the air.
    heard_at: f64 = 0,
    airborne_since: f64 = 0,
    /// It was in the air when first heard: `airborne_since` is worked out
    /// from how far it had flown, not seen.
    takeoff_estimated: bool = false,
    /// A request for it is out.
    asking: bool = false,

    pub fn init(id: u32, q: Query) Flight {
        var f: Flight = .{ .id = id, .query = q };
        var buf: [10]u8 = undefined;
        f.label.set(std.fmt.bufPrint(&buf, "{s} {s}", .{ q.airline.slice(), q.number.slice() }) catch "");
        return f;
    }

    pub fn origin(f: *const Flight, d: *const data.Data) ?*const data.Airport {
        return if (f.from) |k| &d.airports[k] else null;
    }

    pub fn destination(f: *const Flight, d: *const data.Data) ?*const data.Airport {
        return if (f.to) |k| &d.airports[k] else null;
    }

    /// Its route's airports from standing data's codes ("RJTT-RJOO", or
    /// with stops: "WSSS-VHHH-PANC-KLAX", "KPHL-KSEA-KPHL"), its first leg
    /// until it is heard on another.
    pub fn setRoute(f: *Flight, d: *const data.Data, codes: []const u8) bool {
        var n: u8 = 0;
        var it = std.mem.splitScalar(u8, codes, '-');
        while (it.next()) |code| {
            if (n == f.stops.len) break;
            f.stops[n] = d.by_icao.get(code) orelse return false;
            n += 1;
        }
        if (n < 2) return false;
        f.n_stops = n;
        f.from = f.stops[0];
        f.to = f.stops[1];
        if (f.live) |l| f.chooseLeg(d, l.pos, l.track);
        return true;
    }

    /// The leg of its route a plane at `p` heading `track` is flying: the
    /// one it is least out of its way on, going toward its end (a round
    /// trip's two legs lie on one line).
    pub fn chooseLeg(f: *Flight, d: *const data.Data, p: geo.LatLon, track: f64) void {
        if (f.n_stops < 3) return;
        var best: f64 = std.math.inf(f64);
        for (0..f.n_stops - 1) |k| {
            const a = d.airports[f.stops[k]].pos;
            const b = d.airports[f.stops[k + 1]].pos;
            var detour = geo.distanceKm(a, p) + geo.distanceKm(p, b) - geo.distanceKm(a, b);
            const off = @abs(@mod(geo.bearing(p, b) - track + 540, 360) - 180);
            if (off > 90) detour += 1000;
            if (detour < best) {
                best = detour;
                f.from = f.stops[k];
                f.to = f.stops[k + 1];
            }
        }
    }

    pub fn phase(f: *const Flight, d: *const data.Data, now: f64) Phase {
        if (f.no_route and f.live == null) return .unknown;
        if (f.from == null and !f.no_route) return .finding;
        const l = f.live orelse return .waiting;
        const silent = now - f.heard_at + l.age_s;
        const dest = f.destination(d);
        const near_dest = if (dest) |a| geo.distanceKm(l.pos, a.pos) < 40 else false;
        if (l.on_ground) return if (near_dest and f.airborne_since > 0) .landed else .taxiing;
        if (silent > 20 * 60) return if (near_dest or f.progress(d) > 0.93) .landed else .lost;
        return .airborne;
    }

    /// How far along its route it is (0 to 1).
    pub fn progress(f: *const Flight, d: *const data.Data) f64 {
        const a = f.origin(d) orelse return 0;
        const b = f.destination(d) orelse return 0;
        const l = f.live orelse return 0;
        return geo.progress(a.pos, b.pos, l.pos);
    }

    /// Kilometres left to fly.
    pub fn remainingKm(f: *const Flight, d: *const data.Data) ?f64 {
        const b = f.destination(d) orelse return null;
        const l = f.live orelse return null;
        return geo.distanceKm(l.pos, b.pos);
    }

    /// Seconds until it lands: what is left at its speed, slowing for the
    /// approach; its cruise if it is still climbing.
    pub fn etaSeconds(f: *const Flight, d: *const data.Data) ?f64 {
        const left = f.remainingKm(d) orelse return null;
        const l = f.live.?;
        const kmh = if (l.gs_kt > 200) l.gs_kt * geo.km_per_nm else 820;
        const approach: f64 = if (left > 120) 6 * 60 else left / 120 * 6 * 60;
        return left / kmh * 3600 + approach;
    }

    /// The whole flight's length, and about how long it takes gate to gate.
    pub fn routeKm(f: *const Flight, d: *const data.Data) ?f64 {
        const a = f.origin(d) orelse return null;
        const b = f.destination(d) orelse return null;
        return geo.distanceKm(a.pos, b.pos);
    }

    pub fn blockSeconds(f: *const Flight, d: *const data.Data) ?f64 {
        const km = f.routeKm(d) orelse return null;
        return km / 800 * 3600 + 30 * 60;
    }
};

/// "1h 20m", "42m", "2d 3h".
pub fn duration(buf: []u8, seconds: f64) []const u8 {
    const m: u64 = @intFromFloat(@max(0, @round(seconds / 60)));
    if (m < 60) return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "";
    if (m < 48 * 60) return std.fmt.bufPrint(buf, "{d}h {d}m", .{ m / 60, m % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}d {d}h", .{ m / (24 * 60), m / 60 % 24 }) catch "";
}

test "flight numbers as people type them" {
    const cases = [_]struct { in: []const u8, airline: []const u8, number: []const u8 }{
        .{ .in = "JL121", .airline = "JL", .number = "121" },
        .{ .in = "jl 0121", .airline = "JL", .number = "121" },
        .{ .in = "JAL6021", .airline = "JAL", .number = "6021" },
        .{ .in = "U2 8401", .airline = "U2", .number = "8401" },
        .{ .in = "9W-1", .airline = "9W", .number = "1" },
        .{ .in = "BA117A", .airline = "BA", .number = "117A" },
    };
    for (cases) |c| {
        const q = Query.parse(c.in) orelse return error.NotParsed;
        try std.testing.expectEqualStrings(c.airline, q.airline.slice());
        try std.testing.expectEqualStrings(c.number, q.number.slice());
    }
    for ([_][]const u8{ "", "JL", "121", "12345", "JL123456", "J!12" }) |bad| try std.testing.expect(Query.parse(bad) == null);
}

test "a route with stops: the leg the plane is on" {
    const gpa = std.testing.allocator;
    var d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var f: Flight = .init(1, Query.parse("AA2870").?);
    try std.testing.expect(f.setRoute(&d, "KPHL-KSEA-KPHL"));
    try std.testing.expectEqualStrings("SEA", f.destination(&d).?.iata);
    // Heard east of Seattle heading east: the way back.
    const back = geo.along(d.airport("KSEA").?.pos, d.airport("KPHL").?.pos, 0.3);
    f.chooseLeg(&d, back, geo.bearing(back, d.airport("KPHL").?.pos));
    try std.testing.expectEqualStrings("SEA", f.origin(&d).?.iata);
    try std.testing.expectEqualStrings("PHL", f.destination(&d).?.iata);
}

test "a flight's phase, progress and arrival as it flies" {
    const gpa = std.testing.allocator;
    var d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var f: Flight = .init(1, Query.parse("JL121").?);
    try std.testing.expectEqualStrings("JL 121", f.label.slice());
    try std.testing.expectEqual(Phase.finding, f.phase(&d, 0));
    try std.testing.expect(f.setRoute(&d, "RJTT-RJOO"));
    try std.testing.expectEqual(Phase.waiting, f.phase(&d, 0));
    // Halfway, at 450 knots.
    const mid = geo.along(f.origin(&d).?.pos, f.destination(&d).?.pos, 0.5);
    f.live = .{ .pos = mid, .gs_kt = 450, .alt_ft = 30000, .source = .adsb_lol };
    f.heard_at = 1000;
    f.airborne_since = 900;
    try std.testing.expectEqual(Phase.airborne, f.phase(&d, 1010));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), f.progress(&d), 0.01);
    // About 200 km at 833 km/h, and the approach: 20 minutes.
    const eta = f.etaSeconds(&d).?;
    try std.testing.expect(eta > 17 * 60 and eta < 23 * 60);
    // Down at Itami.
    f.live = .{ .pos = f.destination(&d).?.pos, .on_ground = true, .source = .adsb_lol };
    try std.testing.expectEqual(Phase.landed, f.phase(&d, 5000));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1h 20m", duration(&buf, 80 * 60));
    try std.testing.expectEqualStrings("42m", duration(&buf, 42 * 60 + 10));
}

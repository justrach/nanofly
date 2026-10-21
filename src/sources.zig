//! Where flights come from, and what their answers say:
//!
//! - adsb.lol (ODbL): live aircraft by callsign, no key.
//! - OpenSky Network: live aircraft over an area; with an API client (its
//!   ID and secret, OPENSKY_CLIENT_ID / OPENSKY_CLIENT_SECRET) ten times
//!   the requests a day. Its terms ask a license of live products.
//! - vradarserver's standing data (CC0): each airline's routes, by callsign.
//!
//! Only URLs and parsing here: tracker.zig asks.
const std = @import("std");
const geo = @import("geo.zig");

pub fn Small(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: u8 = 0,

        const Self = @This();

        pub fn init(s: []const u8) Self {
            var r: Self = .{};
            r.set(s);
            return r;
        }

        pub fn set(r: *Self, s: []const u8) void {
            const t = std.mem.trim(u8, s, " ");
            const k = @min(t.len, n);
            @memcpy(r.buf[0..k], t[0..k]);
            r.len = @intCast(k);
        }

        pub fn slice(r: *const Self) []const u8 {
            return r.buf[0..r.len];
        }
    };
}

pub const Source = enum { adsb_lol, opensky };

/// An aircraft where it was last heard.
pub const Live = struct {
    pos: geo.LatLon,
    alt_ft: f64 = 0,
    gs_kt: f64 = 0,
    /// Its track over the ground, degrees from north.
    track: f64 = 0,
    vs_fpm: f64 = 0,
    on_ground: bool = false,
    /// Seconds since then, when it was asked.
    age_s: f64 = 0,
    hex: Small(8) = .{},
    reg: Small(12) = .{},
    type: Small(8) = .{},
    source: Source,
};

pub fn adsbUrl(buf: []u8, callsign: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "https://api.adsb.lol/v2/callsign/{s}", .{callsign}) catch "";
}

pub fn routesUrl(buf: []u8, airline_icao: []const u8) []const u8 {
    if (airline_icao.len == 0) return "";
    return std.fmt.bufPrint(buf, "https://raw.githubusercontent.com/vradarserver/standing-data/main/routes/schema-01/{c}/{s}-all.csv", .{ airline_icao[0], airline_icao }) catch "";
}

pub const opensky_token_url = "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token";

/// OpenSky's aircraft over the box from `a` to `b` (and a margin).
pub fn openskyUrl(buf: []u8, a: geo.LatLon, b: geo.LatLon) []const u8 {
    const m = 1.0;
    return std.fmt.bufPrint(buf, "https://opensky-network.org/api/states/all?lamin={d:.3}&lomin={d:.3}&lamax={d:.3}&lomax={d:.3}", .{
        @max(-90, @min(a.lat, b.lat) - m), @max(-180, @min(a.lon, b.lon) - m), @min(90, @max(a.lat, b.lat) + m), @min(180, @max(a.lon, b.lon) + m),
    }) catch "";
}

/// The form OpenSky's token wants, its values escaped.
pub fn tokenBody(buf: []u8, id: []const u8, secret: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("grant_type=client_credentials&client_id=") catch return "";
    escape(&w, id) catch return "";
    w.writeAll("&client_secret=") catch return "";
    escape(&w, secret) catch return "";
    return w.buffered();
}

fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') try w.writeByte(ch) else try w.print("%{X:0>2}", .{ch});
    }
}

/// The airports (ICAO codes, "RJTT-RJOO") the callsign flies between, from
/// an airline's routes (standing data's CSV).
pub fn routeOf(csv: []const u8, callsign: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, csv, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var f = std.mem.splitScalar(u8, line, ',');
        const cs = f.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(cs, callsign)) continue;
        _ = f.next();
        _ = f.next();
        _ = f.next();
        const codes = f.next() orelse return null;
        return if (codes.len >= 9) codes else null;
    }
    return null;
}

fn num(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => null,
    };
}

fn str(v: ?std.json.Value) []const u8 {
    return switch (v orelse return "") {
        .string => |s| s,
        else => "",
    };
}

/// adsb.lol's answer: the aircraft heard most lately, if any.
pub fn parseAdsb(gpa: std.mem.Allocator, json: []const u8) ?Live {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const ac = parsed.value.object.get("ac") orelse return null;
    if (ac != .array) return null;
    var best: ?Live = null;
    for (ac.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const lat = num(o.get("lat")) orelse continue;
        const lon = num(o.get("lon")) orelse continue;
        var l: Live = .{ .pos = .{ .lat = lat, .lon = lon }, .source = .adsb_lol };
        // "ground" when on it.
        if (o.get("alt_baro")) |alt| switch (alt) {
            .string => l.on_ground = true,
            else => l.alt_ft = num(alt) orelse 0,
        };
        l.gs_kt = num(o.get("gs")) orelse 0;
        l.track = num(o.get("track")) orelse num(o.get("true_heading")) orelse 0;
        l.vs_fpm = num(o.get("baro_rate")) orelse num(o.get("geom_rate")) orelse 0;
        l.age_s = num(o.get("seen_pos")) orelse num(o.get("seen")) orelse 0;
        l.hex.set(str(o.get("hex")));
        l.reg.set(str(o.get("r")));
        l.type.set(str(o.get("t")));
        if (best == null or l.age_s < best.?.age_s) best = l;
    }
    return best;
}

/// OpenSky's answer: the aircraft flying as `callsign`, if there.
pub fn parseOpenSky(gpa: std.mem.Allocator, json: []const u8, callsign: []const u8) ?Live {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const now = num(parsed.value.object.get("time")) orelse 0;
    const states = parsed.value.object.get("states") orelse return null;
    if (states != .array) return null;
    for (states.array.items) |s| {
        if (s != .array or s.array.items.len < 12) continue;
        const v = s.array.items;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, str(v[1]), " "), callsign)) continue;
        const lon = num(v[5]) orelse continue;
        const lat = num(v[6]) orelse continue;
        var l: Live = .{ .pos = .{ .lat = lat, .lon = lon }, .source = .opensky };
        l.alt_ft = (num(v[7]) orelse 0) * 3.28084;
        l.on_ground = v[8] == .bool and v[8].bool;
        l.gs_kt = (num(v[9]) orelse 0) * 1.943844;
        l.track = num(v[10]) orelse 0;
        l.vs_fpm = (num(v[11]) orelse 0) * 196.850394;
        const heard = num(v[4]) orelse now;
        l.age_s = @max(0, now - heard);
        l.hex.set(str(v[0]));
        return l;
    }
    return null;
}

/// OpenSky's token and how many seconds it lasts.
pub fn parseToken(gpa: std.mem.Allocator, json: []const u8, out: []u8) ?struct { token: []const u8, expires_s: f64 } {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const t = str(parsed.value.object.get("access_token"));
    if (t.len == 0 or t.len > out.len) return null;
    @memcpy(out[0..t.len], t);
    return .{ .token = out[0..t.len], .expires_s = num(parsed.value.object.get("expires_in")) orelse 1800 };
}

test "a route by its callsign; adsb.lol's and OpenSky's answers" {
    const csv = "Callsign,Code,Number,AirlineCode,AirportCodes\r\nJAL120,JAL,120,JAL,RJOO-RJTT\r\nJAL121,JAL,121,JAL,RJTT-RJOO\r\n";
    try std.testing.expectEqualStrings("RJTT-RJOO", routeOf(csv, "JAL121").?);
    try std.testing.expect(routeOf(csv, "JAL9") == null);

    const gpa = std.testing.allocator;
    const adsb =
        \\{"ac":[{"hex":"86e4c1","flight":"JAL121  ","r":"JA8980","t":"B772","alt_baro":34000,"gs":452.1,"track":251.3,"baro_rate":-64,"lat":35.1,"lon":137.2,"seen_pos":0.4,"seen":0.1},
        \\       {"hex":"86e4c1","flight":"JAL121","alt_baro":"ground","lat":35.0,"lon":137.0,"seen_pos":30}],"now":1}
    ;
    const l = parseAdsb(gpa, adsb).?;
    try std.testing.expectEqualStrings("JA8980", l.reg.slice());
    try std.testing.expectEqualStrings("B772", l.type.slice());
    try std.testing.expectApproxEqAbs(@as(f64, 34000), l.alt_ft, 0.1);
    try std.testing.expect(!l.on_ground);
    try std.testing.expect(parseAdsb(gpa, "{\"ac\":[]}") == null);

    const sky =
        \\{"time":1792582445,"states":[["841ebc","JJP27   ","Japan",1792582352,1792582440,140.39,35.76,9144.0,false,231.5,205.3,-2.5,null,null,null,false,0]]}
    ;
    const o = parseOpenSky(gpa, sky, "JJP27").?;
    try std.testing.expectApproxEqAbs(@as(f64, 30000), o.alt_ft, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 450), o.gs_kt, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 5), o.age_s, 0.01);
    try std.testing.expect(parseOpenSky(gpa, sky, "JAL1") == null);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("grant_type=client_credentials&client_id=a%2Bb&client_secret=c%20d", tokenBody(&buf, "a+b", "c d"));
}

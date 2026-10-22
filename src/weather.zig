//! The weather: rain and snow on the map from RainViewer's radar (its
//! latest frame, as tiles of Web Mercator's square), and the weather now
//! at airports from Open-Meteo. Answers come on the main thread
//! (nanoui.http); `redraw` is called after each.
//!
//! - RainViewer (free for personal and educational use, no key): radar
//!   frames every 10 minutes, tiles to zoom 7.
//! - Open-Meteo (CC BY 4.0, free for non-commercial use, no key): the
//!   weather now at a place.
const std = @import("std");
const nanoui = @import("nanoui");
const http = nanoui.http;
const geo = @import("geo.zig");
const sources = @import("sources.zig");

const Small = sources.Small;

pub const manifest_url = "https://api.rainviewer.com/public/weather-maps.json";
/// RainViewer's free tiles go no closer.
pub const max_zoom = 7;
/// A tile's side, in pixels.
pub const tile_px: f32 = 256;
/// A new radar frame comes every 10 minutes.
const radar_every_s = 5 * 60;
/// The weather at an airport is asked again after this long.
const airport_every_s = 15 * 60;
/// Tiles asked at once, and kept.
const max_asking = 8;
const max_tiles = 160;

/// The radar's latest frame: where its tiles are, and when it was made.
pub const Radar = struct {
    host: Small(64) = .{},
    path: Small(48) = .{},
    time: f64 = 0,
};

/// RainViewer's list of frames: the latest past one.
pub fn parseManifest(gpa: std.mem.Allocator, json: []const u8) ?Radar {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    const host = root.get("host") orelse return null;
    const radar = root.get("radar") orelse return null;
    if (host != .string or radar != .object) return null;
    const past = radar.object.get("past") orelse return null;
    if (past != .array or past.array.items.len == 0) return null;
    const last = past.array.items[past.array.items.len - 1];
    if (last != .object) return null;
    const path = last.object.get("path") orelse return null;
    if (path != .string) return null;
    var r: Radar = .{ .host = .init(host.string), .path = .init(path.string) };
    if (r.host.len != host.string.len or r.path.len != path.string.len) return null;
    if (last.object.get("time")) |t| r.time = switch (t) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
    return r;
}

/// A radar tile: 256 pixels, Universal Blue (the free scheme), smoothed,
/// snow shown.
pub fn tileUrl(buf: []u8, r: *const Radar, z: u8, x: u32, y: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}/256/{d}/{d}/{d}/2/1_1.png", .{ r.host.slice(), r.path.slice(), z, x, y }) catch "";
}

/// The weather now at a place.
pub const Now = struct {
    temp_c: f32,
    /// WMO's weather code.
    code: u8,
    day: bool = true,
    wind_kmh: f32 = 0,
};

pub fn currentUrl(buf: []u8, p: geo.LatLon) []const u8 {
    return std.fmt.bufPrint(buf, "https://api.open-meteo.com/v1/forecast?latitude={d:.3}&longitude={d:.3}&current=temperature_2m,weather_code,is_day,wind_speed_10m", .{ p.lat, p.lon }) catch "";
}

fn num(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => null,
    };
}

pub fn parseCurrent(gpa: std.mem.Allocator, json: []const u8) ?Now {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const cur = parsed.value.object.get("current") orelse return null;
    if (cur != .object) return null;
    const o = cur.object;
    return .{
        .temp_c = @floatCast(num(o.get("temperature_2m")) orelse return null),
        .code = @intFromFloat(std.math.clamp(num(o.get("weather_code")) orelse 0, 0, 99)),
        .day = (num(o.get("is_day")) orelse 1) != 0,
        .wind_kmh = @floatCast(num(o.get("wind_speed_10m")) orelse 0),
    };
}

/// A WMO weather code as an SF Symbol and a word or two.
pub fn describe(code: u8, day: bool) struct { symbol: []const u8, text: []const u8 } {
    return switch (code) {
        0 => .{ .symbol = if (day) "sun.max.fill" else "moon.stars.fill", .text = "Clear" },
        1 => .{ .symbol = if (day) "sun.max.fill" else "moon.fill", .text = "Mostly clear" },
        2 => .{ .symbol = if (day) "cloud.sun.fill" else "cloud.moon.fill", .text = "Partly cloudy" },
        3 => .{ .symbol = "cloud.fill", .text = "Cloudy" },
        45, 48 => .{ .symbol = "cloud.fog.fill", .text = "Fog" },
        51...57 => .{ .symbol = "cloud.drizzle.fill", .text = "Drizzle" },
        61, 63, 66 => .{ .symbol = "cloud.rain.fill", .text = "Rain" },
        65, 67 => .{ .symbol = "cloud.heavyrain.fill", .text = "Heavy rain" },
        71...77 => .{ .symbol = "cloud.snow.fill", .text = "Snow" },
        80, 81 => .{ .symbol = if (day) "cloud.sun.rain.fill" else "cloud.moon.rain.fill", .text = "Showers" },
        82 => .{ .symbol = "cloud.heavyrain.fill", .text = "Heavy showers" },
        85, 86 => .{ .symbol = "cloud.snow.fill", .text = "Snow showers" },
        95...99 => .{ .symbol = "cloud.bolt.rain.fill", .text = "Thunderstorms" },
        else => .{ .symbol = "cloud.fill", .text = "Cloudy" },
    };
}

/// Weather that would slow a flight down: storms, heavy rain or snow, fog.
pub fn rough(code: u8) bool {
    return switch (code) {
        45, 48, 65, 67, 75, 82, 86, 95...99 => true,
        else => false,
    };
}

pub const Weather = struct {
    gpa: std.mem.Allocator,
    /// Asks nothing (tests).
    offline: bool = false,
    redraw_ctx: ?*anyopaque = null,
    redraw_fn: ?*const fn (?*anyopaque) void = null,
    radar: ?Radar = null,
    /// Which frame the tiles kept are of (each new frame, one more).
    generation: u32 = 0,
    radar_asked: f64 = 0,
    asking_radar: bool = false,
    tiles: std.AutoHashMapUnmanaged(u64, Tile) = .empty,
    asking: u32 = 0,
    /// Frames drawn, to let go of the tiles not drawn lately.
    frame: u32 = 0,
    airports: std.AutoHashMapUnmanaged(u32, Airport) = .empty,

    pub const Tile = struct {
        generation: u32,
        /// The picture (PNG), kept until its next frame's comes, and which
        /// frame it is of.
        png: ?[]u8 = null,
        png_generation: u32 = 0,
        asking: bool = false,
        used: u32 = 0,
    };

    pub const Airport = struct {
        now: ?Now = null,
        asked: f64 = 0,
        asking: bool = false,
    };

    pub fn deinit(w: *Weather) void {
        var it = w.tiles.valueIterator();
        while (it.next()) |t| if (t.png) |p| w.gpa.free(p);
        w.tiles.deinit(w.gpa);
        w.airports.deinit(w.gpa);
    }

    fn redraw(w: *Weather) void {
        if (w.redraw_fn) |f| f(w.redraw_ctx);
    }

    /// Asks for the radar's latest frame when the one known is old.
    pub fn refreshRadar(w: *Weather, now: f64) void {
        if (w.offline or w.asking_radar or now - w.radar_asked < radar_every_s) return;
        w.asking_radar = true;
        w.radar_asked = now;
        http.fetch(w.gpa, .{ .url = manifest_url, .headers = &.{sources.user_agent}, .timeout = 15 }, w, radarAnswered);
    }

    fn radarAnswered(w: *Weather, r: http.Response) void {
        w.asking_radar = false;
        if (r.status != 200) return;
        const got = parseManifest(w.gpa, r.body) orelse return;
        if (w.radar) |old| if (old.time == got.time) return;
        w.radar = got;
        w.generation += 1;
        w.redraw();
    }

    fn key(z: u8, x: u32, y: u32) u64 {
        return @as(u64, z) << 48 | @as(u64, x) << 24 | y;
    }

    pub const Picture = struct { png: []const u8, generation: u32 };

    /// Tile (`z`, `x`, `y`) of the radar's frame as a PNG, if here (the
    /// last frame's until this one's comes); asked for if not.
    pub fn tile(w: *Weather, z: u8, x: u32, y: u32) ?Picture {
        const r = w.radar orelse return null;
        const gop = w.tiles.getOrPut(w.gpa, key(z, x, y)) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{ .generation = 0 };
        const t = gop.value_ptr;
        t.used = w.frame;
        if (t.generation != w.generation and !t.asking and w.asking < max_asking and !w.offline) {
            const ask = w.gpa.create(TileAsk) catch return picture(t);
            ask.* = .{ .w = w, .key = key(z, x, y), .generation = w.generation };
            t.asking = true;
            w.asking += 1;
            var buf: [192]u8 = undefined;
            http.fetch(w.gpa, .{ .url = tileUrl(&buf, &r, z, x, y), .headers = &.{sources.user_agent}, .timeout = 20 }, ask, tileAnswered);
        }
        return picture(t);
    }

    fn picture(t: *const Tile) ?Picture {
        return .{ .png = t.png orelse return null, .generation = t.png_generation };
    }

    const TileAsk = struct { w: *Weather, key: u64, generation: u32 };

    fn tileAnswered(a: *TileAsk, r: http.Response) void {
        const w = a.w;
        defer w.gpa.destroy(a);
        w.asking -|= 1;
        const t = w.tiles.getPtr(a.key) orelse return;
        t.asking = false;
        // Answered or not, this frame's was asked: not again until the next.
        t.generation = a.generation;
        if (r.status == 200 and r.body.len > 8 and std.mem.eql(u8, r.body[1..4], "PNG")) {
            if (w.gpa.dupe(u8, r.body)) |png| {
                if (t.png) |old| w.gpa.free(old);
                t.png = png;
                t.png_generation = a.generation;
            } else |_| {}
        }
        w.redraw();
    }

    /// After a frame's tiles are drawn: lets go of those not drawn lately.
    pub fn endFrame(w: *Weather) void {
        w.frame +%= 1;
        if (w.tiles.count() <= max_tiles) return;
        var it = w.tiles.iterator();
        var drop: [64]u64 = undefined;
        var n: usize = 0;
        while (it.next()) |e| {
            if (n == drop.len) break;
            if (!e.value_ptr.asking and w.frame -% e.value_ptr.used > 2) {
                drop[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (drop[0..n]) |k| if (w.tiles.fetchRemove(k)) |e| if (e.value.png) |p| w.gpa.free(p);
    }

    /// The weather now at airport `k` (at `pos`), if known; asked for when
    /// not, or old.
    pub fn at(w: *Weather, k: u32, pos: geo.LatLon, now: f64) ?Now {
        const gop = w.airports.getOrPut(w.gpa, k) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const a = gop.value_ptr;
        if (!a.asking and !w.offline and now - a.asked > airport_every_s) {
            const ask = w.gpa.create(AirportAsk) catch return a.now;
            ask.* = .{ .w = w, .k = k };
            a.asking = true;
            a.asked = now;
            var buf: [192]u8 = undefined;
            http.fetch(w.gpa, .{ .url = currentUrl(&buf, pos), .headers = &.{sources.user_agent}, .timeout = 15 }, ask, airportAnswered);
        }
        return a.now;
    }

    const AirportAsk = struct { w: *Weather, k: u32 };

    fn airportAnswered(a: *AirportAsk, r: http.Response) void {
        const w = a.w;
        defer w.gpa.destroy(a);
        const ap = w.airports.getPtr(a.k) orelse return;
        ap.asking = false;
        if (r.status == 200) if (parseCurrent(w.gpa, r.body)) |n| {
            ap.now = n;
        };
        w.redraw();
    }
};

/// The tiles of zoom `z` a view of the square from (x0, y0) to (x1, y1)
/// takes: their columns (unwrapped, any integer) and rows.
pub fn tilesOver(z: u8, x0: f64, y0: f64, x1: f64, y1: f64) struct { c0: i64, c1: i64, r0: u32, r1: u32 } {
    const n: f64 = @floatFromInt(@as(u32, 1) << @intCast(z));
    const last: f64 = n - 1;
    return .{
        .c0 = @intFromFloat(@floor(x0 * n)),
        .c1 = @intFromFloat(@floor(x1 * n)),
        .r0 = @intFromFloat(std.math.clamp(@floor(y0 * n), 0, last)),
        .r1 = @intFromFloat(std.math.clamp(@floor(y1 * n), 0, last)),
    };
}

/// The zoom of the tiles for a world `scale` points wide: each tile about
/// 200 points, so its pixels are a little enlarged at most.
pub fn zoomFor(scale: f64) u8 {
    const z = @round(std.math.log2(@max(scale, 1) / 200));
    return @intFromFloat(std.math.clamp(z, 0, max_zoom));
}

test "RainViewer's frames and tiles; Open-Meteo's weather now" {
    const gpa = std.testing.allocator;
    const manifest =
        \\{"version":"2.0","generated":1792629326,"host":"https://tilecache.rainviewer.com",
        \\ "radar":{"past":[{"time":1792628400,"path":"/v2/radar/aaaa"},{"time":1792629000,"path":"/v2/radar/9a286889cef7"}],"nowcast":[]},
        \\ "satellite":{"infrared":[]}}
    ;
    const r = parseManifest(gpa, manifest).?;
    try std.testing.expectEqual(@as(f64, 1792629000), r.time);
    var buf: [192]u8 = undefined;
    try std.testing.expectEqualStrings("https://tilecache.rainviewer.com/v2/radar/9a286889cef7/256/3/6/3/2/1_1.png", tileUrl(&buf, &r, 3, 6, 3));
    try std.testing.expect(parseManifest(gpa, "{\"host\":\"x\",\"radar\":{\"past\":[]}}") == null);

    const cur =
        \\{"latitude":50.04,"current":{"time":"2026-10-22T00:30","temperature_2m":8.5,"weather_code":61,"is_day":0,"wind_speed_10m":11.9}}
    ;
    const n = parseCurrent(gpa, cur).?;
    try std.testing.expectApproxEqAbs(@as(f32, 8.5), n.temp_c, 1e-4);
    try std.testing.expectEqual(@as(u8, 61), n.code);
    try std.testing.expect(!n.day);
    try std.testing.expectEqualStrings("Rain", describe(n.code, n.day).text);
    try std.testing.expectEqualStrings("moon.stars.fill", describe(0, false).symbol);
    try std.testing.expect(rough(95) and !rough(2));

    // The whole world at 400 points: zoom 1, all four tiles.
    try std.testing.expectEqual(@as(u8, 1), zoomFor(400));
    try std.testing.expectEqual(@as(u8, max_zoom), zoomFor(1e6));
    const t = tilesOver(1, 0, 0, 0.99, 0.99);
    try std.testing.expectEqual(@as(i64, 0), t.c0);
    try std.testing.expectEqual(@as(i64, 1), t.c1);
    try std.testing.expectEqual(@as(u32, 1), t.r1);
}

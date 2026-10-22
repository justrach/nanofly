//! The planes around: adsb.lol's aircraft near where the map looks, drawn
//! faintly about the one followed, as a radar's screen shows them. Asked
//! when the map comes close, again with the clock, and when it moves far.
const std = @import("std");
const nanoui = @import("nanoui");
const http = nanoui.http;
const geo = @import("geo.zig");
const sources = @import("sources.zig");

pub const Plane = sources.Plane;

/// Not asked again sooner than this, however the map moves: adsb.lol
/// allows few requests a minute.
const min_every_s = 12;
/// Turned away (too many requests): waits this long.
const backoff_s = 60;

pub const Traffic = struct {
    gpa: std.mem.Allocator,
    offline: bool = false,
    redraw_ctx: ?*anyopaque = null,
    redraw_fn: ?*const fn (?*anyopaque) void = null,
    planes: [300]Plane = undefined,
    n: usize = 0,
    /// Where and how far around it was last asked, and when.
    center: geo.LatLon = .{ .lat = 0, .lon = 0 },
    radius_nm: f64 = 0,
    asked: f64 = 0,
    asking: bool = false,

    pub fn items(t: *const Traffic) []const Plane {
        return t.planes[0..t.n];
    }

    /// Asks for the planes within `nm` of `p` when the last answer is old
    /// (`every` seconds) or was of somewhere else.
    pub fn want(t: *Traffic, p: geo.LatLon, nm: f64, now: f64, every: f64) void {
        if (t.offline or t.asking or now - t.asked < min_every_s) return;
        // adsb.lol answers within 250 nautical miles at most.
        const reach = std.math.clamp(nm, 5, 250);
        const moved = geo.distanceKm(p, t.center) / geo.km_per_nm > t.radius_nm * 0.5 or reach > t.radius_nm * 1.5;
        if (!moved and now - t.asked < every) return;
        t.asking = true;
        t.asked = now;
        t.center = p;
        t.radius_nm = reach;
        var buf: [256]u8 = undefined;
        http.fetch(t.gpa, .{ .url = sources.pointUrl(&buf, p, t.radius_nm), .headers = &.{sources.user_agent}, .timeout = 15 }, t, answered);
    }

    fn answered(t: *Traffic, r: http.Response) void {
        t.asking = false;
        if (r.status == 429) t.asked += backoff_s;
        if (r.status == 200) t.n = sources.parsePlanes(t.gpa, r.body, &t.planes);
        if (t.redraw_fn) |f| f(t.redraw_ctx);
    }

    /// The plane flying as `callsign`, if around.
    pub fn find(t: *const Traffic, callsign: []const u8) ?*const Plane {
        for (t.items()) |*p| if (std.ascii.eqlIgnoreCase(p.callsign.slice(), callsign)) return p;
        return null;
    }
};

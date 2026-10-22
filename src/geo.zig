//! The earth's geometry the app needs: distances and great circles (the
//! way a plane flies), and Web Mercator, the square the map is drawn on
//! (0 to 1, x east, y south), which keeps angles: a heading is the same
//! angle on the map.
const std = @import("std");
const math = std.math;

pub const LatLon = struct { lat: f64, lon: f64 };

pub const earth_km = 6371.0;
pub const km_per_mile = 1.609344;
pub const km_per_nm = 1.852;

fn rad(d: f64) f64 {
    return d * math.pi / 180;
}

fn deg(r: f64) f64 {
    return r * 180 / math.pi;
}

/// The distance along the earth's surface, in kilometres.
pub fn distanceKm(a: LatLon, b: LatLon) f64 {
    const dlat = rad(b.lat - a.lat);
    const dlon = rad(b.lon - a.lon);
    const h = @sin(dlat / 2) * @sin(dlat / 2) + @cos(rad(a.lat)) * @cos(rad(b.lat)) * @sin(dlon / 2) * @sin(dlon / 2);
    return 2 * earth_km * math.atan2(@sqrt(h), @sqrt(@max(0, 1 - h)));
}

fn vec(p: LatLon) [3]f64 {
    const la = rad(p.lat);
    const lo = rad(p.lon);
    return .{ @cos(la) * @cos(lo), @cos(la) * @sin(lo), @sin(la) };
}

/// The point `f` (0 to 1) of the way from `a` to `b` on the great circle.
pub fn along(a: LatLon, b: LatLon, f: f64) LatLon {
    const va = vec(a);
    const vb = vec(b);
    const d = distanceKm(a, b) / earth_km;
    if (d < 1e-9) return a;
    const s = @sin(d);
    const wa = @sin((1 - f) * d) / s;
    const wb = @sin(f * d) / s;
    const x = wa * va[0] + wb * vb[0];
    const y = wa * va[1] + wb * vb[1];
    const z = wa * va[2] + wb * vb[2];
    return .{ .lat = deg(math.atan2(z, @sqrt(x * x + y * y))), .lon = deg(math.atan2(y, x)) };
}

/// The direction from `a` toward `b`, degrees clockwise from north.
pub fn bearing(a: LatLon, b: LatLon) f64 {
    const dlon = rad(b.lon - a.lon);
    const y = @sin(dlon) * @cos(rad(b.lat));
    const x = @cos(rad(a.lat)) * @sin(rad(b.lat)) - @sin(rad(a.lat)) * @cos(rad(b.lat)) * @cos(dlon);
    return @mod(deg(math.atan2(y, x)) + 360, 360);
}

/// How far along the way from `a` to `b` a plane at `p` is (0 to 1).
pub fn progress(a: LatLon, b: LatLon, p: LatLon) f64 {
    const done = distanceKm(a, p);
    const left = distanceKm(p, b);
    if (done + left <= 0) return 0;
    return math.clamp(done / (done + left), 0, 1);
}

/// Web Mercator, to the square (latitudes beyond 85° held there).
pub fn mercator(p: LatLon) [2]f64 {
    const lat = math.clamp(p.lat, -85, 85);
    const y = @log(@tan(math.pi / 4.0 + rad(lat) / 2));
    return .{ (p.lon + 180) / 360, 0.5 - y / (2 * math.pi) };
}

/// The place at (x, y) on the square.
pub fn unmercator(x: f64, y: f64) LatLon {
    const lat = deg(math.atan(math.sinh((0.5 - y) * 2 * math.pi)));
    return .{ .lat = lat, .lon = @mod(x, 1) * 360 - 180 };
}

/// Where the sun is overhead at `unix` seconds, to a fraction of a degree
/// (the Astronomical Almanac's low-precision formulas).
pub fn subsolar(unix: f64) LatLon {
    const d = (unix - 946728000) / 86400;
    const g = rad(357.529 + 0.98560028 * d);
    const l = rad(280.459 + 0.98564736 * d + 1.915 * @sin(g) + 0.020 * @sin(2 * g));
    const e = rad(23.439 - 0.00000036 * d);
    const ra = deg(math.atan2(@cos(e) * @sin(l), @cos(l)));
    const dec = deg(math.asin(@sin(e) * @sin(l)));
    const gmst = @mod(18.697374558 + 24.06570982441908 * d, 24) * 15;
    return .{ .lat = dec, .lon = @mod(ra - gmst + 540, 360) - 180 };
}

/// The latitude at longitude `lon` where the sun, overhead at `sun`, is
/// `alt` degrees high (0: where it sets; -6, -12: dusk's ends). The night
/// lies from there toward the pole away from the sun.
pub fn dusk(sun: LatLon, lon: f64, alt: f64) f64 {
    const d = rad(sun.lat);
    const a = @sin(d);
    const b = @cos(d) * @cos(rad(lon - sun.lon));
    const r = @sqrt(a * a + b * b);
    const s = @sin(rad(alt));
    const pole: f64 = if (sun.lat > 0) -90 else 90;
    // Never that low here: no night; always lower: night pole to pole.
    if (s <= -r) return pole;
    if (s >= r) return -pole;
    // Altitude along the meridian is r * sin(lat + phase).
    const phase = math.atan2(b, a);
    const x = math.asin(s / r);
    var best: f64 = -pole;
    for ([2]f64{ x - phase, math.pi - x - phase }) |c| {
        const lat = deg(math.atan2(@sin(c), @cos(c)));
        if (@abs(lat) <= 90 and @abs(lat - pole) < @abs(best - pole)) best = lat;
    }
    return best;
}

/// The great circle from `a` to `b` on the square, in `out.len` points,
/// its x carried on past the square's sides rather than jumping across
/// (a flight over the Pacific), so it draws as one line.
pub fn arc(a: LatLon, b: LatLon, out: [][2]f64) void {
    const n = out.len;
    for (out, 0..) |*o, k| {
        const f = if (n > 1) @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1)) else 0;
        o.* = mercator(along(a, b, f));
        if (k > 0) {
            const prev = out[k - 1][0];
            while (o[0] - prev > 0.5) o[0] -= 1;
            while (prev - o[0] > 0.5) o[0] += 1;
        }
    }
}

test "distances: Haneda to Itami, London to New York" {
    const hnd: LatLon = .{ .lat = 35.5523, .lon = 139.78 };
    const itm: LatLon = .{ .lat = 34.7855, .lon = 135.438 };
    try std.testing.expectApproxEqAbs(@as(f64, 403), distanceKm(hnd, itm), 3);
    const lhr: LatLon = .{ .lat = 51.47, .lon = -0.4543 };
    const jfk: LatLon = .{ .lat = 40.6413, .lon = -73.7781 };
    try std.testing.expectApproxEqAbs(@as(f64, 5540), distanceKm(lhr, jfk), 15);
}

test "the great circle's middle, a bearing, progress along it" {
    const a: LatLon = .{ .lat = 0, .lon = 0 };
    const b: LatLon = .{ .lat = 0, .lon = 90 };
    const m = along(a, b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 45), m.lon, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 90), bearing(a, b), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), progress(a, b, m), 1e-6);
    // London to New York starts out heading north of west.
    const lhr: LatLon = .{ .lat = 51.47, .lon = -0.4543 };
    const jfk: LatLon = .{ .lat = 40.6413, .lon = -73.7781 };
    const h = bearing(lhr, jfk);
    try std.testing.expect(h > 280 and h < 300);
}

test "the square and back; the sun overhead, and where it sets" {
    const p = unmercator(mercator(.{ .lat = 35.5, .lon = 139.8 })[0], mercator(.{ .lat = 35.5, .lon = 139.8 })[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 35.5), p.lat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 139.8), p.lon, 1e-9);
    // The June solstice, 2026-06-21 12:00 UTC: over the Tropic of Cancer,
    // near Greenwich.
    const s = subsolar(1782043200);
    try std.testing.expectApproxEqAbs(@as(f64, 23.44), s.lat, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 0), s.lon, 1);
    // Opposite the sun, night reaches the Arctic Circle (the midnight sun
    // north of it); under the sun, it's dark only past the Antarctic Circle.
    try std.testing.expectApproxEqAbs(@as(f64, 66.56), dusk(s, 180, 0), 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, -66.56), dusk(s, s.lon, 0), 0.5);
    // Dusk's end lies further into the night.
    try std.testing.expect(dusk(s, 90, -12) < dusk(s, 90, 0));
}

test "an arc over the Pacific carries on past the map's edge" {
    const nrt: LatLon = .{ .lat = 35.76, .lon = 140.39 };
    const sfo: LatLon = .{ .lat = 37.62, .lon = -122.38 };
    var pts: [32][2]f64 = undefined;
    arc(nrt, sfo, &pts);
    for (pts[1..], pts[0 .. pts.len - 1]) |p, q| try std.testing.expect(@abs(p[0] - q[0]) < 0.1);
    // Eastward across the date line: x grows past 1.
    try std.testing.expect(pts[pts.len - 1][0] > 1);
}

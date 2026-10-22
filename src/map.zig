//! The map: the land on a dark sea, drawn from its triangles (the coarse
//! outline zoomed out, the fine one closer) and edged along its coasts;
//! the night's side of the earth, shaded; the weather's radar over it; a
//! flight's great circle (solid and glowing where it has flown, dashed
//! ahead), its airports and the plane, turned to its track, and the
//! planes around, faint. Everything is on Web Mercator's square, and the
//! camera says where on it the view looks and how close.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const geo = @import("geo.zig");
const land_mod = @import("land.zig");
const weather = @import("weather.zig");
const sources = @import("sources.zig");

const Point = ui.Point;
const Land = land_mod.Land;

pub const colors = struct {
    pub const sea: ui.Color = .hex(0x090b10);
    pub const land: ui.Color = .hex(0x1b2029);
    pub const coast: ui.Color = .hex(0x2c3340);
    pub const night: ui.Color = .{ .r = 0, .g = 0, .b = 0.02, .a = 0.14 };
    pub const route_ahead: ui.Color = .hex(0x7b8494);
    pub const route_flown: ui.Color = .hex(0x4c9bff);
    pub const plane: ui.Color = .hex(0xffffff);
    pub const traffic: ui.Color = .{ .r = 0.62, .g = 0.66, .b = 0.74, .a = 0.55 };
    pub const airport: ui.Color = .hex(0xffffff);
};

pub const Camera = struct {
    /// The view's middle, on the square.
    x: f64 = 0.5,
    y: f64 = 0.42,
    /// How many points wide the whole world is.
    scale: f64 = 400,

    pub const max_scale: f64 = 1 << 19;

    pub fn toScreen(cam: Camera, size: ui.Size, wx: f64, wy: f64) Point {
        return .{
            .x = @floatCast((wx - cam.x) * cam.scale + size.w / 2),
            .y = @floatCast((wy - cam.y) * cam.scale + size.h / 2),
        };
    }

    /// The point of the square under `p` of the view.
    pub fn toWorld(cam: Camera, size: ui.Size, p: Point) [2]f64 {
        return .{ cam.x + (p.x - size.w / 2) / cam.scale, cam.y + (p.y - size.h / 2) / cam.scale };
    }

    /// The camera that shows `bounds` (x0, y0, x1, y1 on the square) inside
    /// `area` of a view `size`, as close as it fits.
    pub fn fit(bounds: [4]f64, area: ui.Rect, size: ui.Size) Camera {
        const bw = @max(bounds[2] - bounds[0], 1e-6);
        const bh = @max(bounds[3] - bounds[1], 1e-6);
        const scale = std.math.clamp(@min(area.w / bw, area.h / bh), 100, max_scale / 64);
        // The bounds' middle at the area's middle.
        const mx = (bounds[0] + bounds[2]) / 2;
        const my = (bounds[1] + bounds[3]) / 2;
        const ax = area.x + area.w / 2 - size.w / 2;
        const ay = area.y + area.h / 2 - size.h / 2;
        return .{ .x = mx - ax / scale, .y = my - ay / scale, .scale = scale };
    }

    /// Zoomed by `factor` about the point `at` of the view.
    pub fn zoom(cam: Camera, factor: f64, at: Point, size: ui.Size) Camera {
        const s = std.math.clamp(cam.scale * factor, @max(size.w, 200) * 0.8, max_scale);
        const dx = (at.x - size.w / 2);
        const dy = (at.y - size.h / 2);
        const wx = cam.x + dx / cam.scale;
        const wy = cam.y + dy / cam.scale;
        return .{ .x = wx - dx / s, .y = std.math.clamp(wy - dy / s, 0, 1), .scale = s };
    }

    /// Moved by (dx, dy) points, as a finger drags the map.
    pub fn moved(cam: Camera, dx: f32, dy: f32) Camera {
        return .{ .x = cam.x - dx / cam.scale, .y = std.math.clamp(cam.y - dy / cam.scale, 0, 1), .scale = cam.scale };
    }

    /// `k` (0 to 1) of the way to `goal`: across, and in proportion closer,
    /// so a glide from the world to a city keeps its pace.
    pub fn toward(cam: Camera, goal: Camera, k: f64) Camera {
        var from = cam;
        // The world wraps: the way round that is shorter.
        while (goal.x - from.x > 0.5) from.x += 1;
        while (from.x - goal.x > 0.5) from.x -= 1;
        return .{
            .x = from.x + (goal.x - from.x) * k,
            .y = from.y + (goal.y - from.y) * k,
            .scale = from.scale * std.math.pow(f64, goal.scale / from.scale, k),
        };
    }

    /// Close enough to `goal` that the rest wouldn't show.
    pub fn near(cam: Camera, goal: Camera) bool {
        const dx = @abs(@mod(goal.x - cam.x + 0.5, 1) - 0.5) * cam.scale;
        const dy = @abs(goal.y - cam.y) * cam.scale;
        return dx < 0.25 and dy < 0.25 and @abs(@log(goal.scale / cam.scale)) < 0.0008;
    }

    /// The squares' copies side by side that the view reaches: a world
    /// seen across the date line.
    fn copies(cam: Camera, size: ui.Size) [2]i32 {
        const half = size.w / 2 / cam.scale;
        return .{ @intFromFloat(@floor(cam.x - half)), @intFromFloat(@floor(cam.x + half)) };
    }

    /// The part of the square the view shows: x0, y0, x1, y1.
    pub fn view(cam: Camera, size: ui.Size) [4]f64 {
        const hw = size.w / 2 / cam.scale;
        const hh = size.h / 2 / cam.scale;
        return .{ cam.x - hw, cam.y - hh, cam.x + hw, cam.y + hh };
    }
};

pub fn drawLand(cv: *ui.Canvas, cam: Camera, size: ui.Size, coarse: *const Land, fine: *const Land) void {
    const l = if (cam.scale > 4000) fine else coarse;
    const v = cam.view(size);
    const alloc = cv.c.alloc();
    const k = cam.copies(size);
    // Thin coasts zoomed out, where the outline is dense.
    const coast_w: f32 = if (cam.scale < 1200) 0.6 else 1;
    var copy = k[0];
    while (copy <= k[1]) : (copy += 1) {
        const off: f64 = @floatFromInt(copy);
        for (l.rings) |ring| {
            const b = ring.bounds;
            if (b[2] + off < v[0] or b[0] + off > v[2] or b[3] < v[1] or b[1] > v[3]) continue;
            const pts = alloc.alloc(Point, ring.points.len) catch return;
            for (ring.points, pts) |p, *s| s.* = cam.toScreen(size, p[0] + off, p[1]);
            for (ring.tris) |t| cv.triangle(pts[t.v[0]], pts[t.v[1]], pts[t.v[2]], colors.land, t.smooth);
            coast(cv, ring.points, pts, .{ .width = coast_w, .color = colors.coast });
        }
    }
}

/// A ring's coast: its edges, but not those where the land was cut (along
/// the date line, or the map's bottom under Antarctica).
fn coast(cv: *ui.Canvas, world: []const [2]f32, pts: []const Point, s: ui.Stroke) void {
    var start: usize = 0;
    for (0..world.len) |i| {
        const j = (i + 1) % world.len;
        const a = world[i];
        const b = world[j];
        const cut = (@abs(a[0] - b[0]) < 1e-5 and (a[0] < 1e-4 or a[0] > 1 - 1e-4)) or (a[1] > 0.97 and b[1] > 0.97);
        if (cut or j == 0) {
            const end = if (cut) i else world.len - 1;
            if (end > start) cv.polyline(pts[start .. end + 1], s);
            if (!cut and j == 0) cv.line(pts[i], pts[0], s);
            start = i + 1;
        }
    }
}

/// The night's side of the earth at `unix` seconds, darker through dusk
/// (where the sun is under 0°, 6° and 12°).
pub fn drawNight(cv: *ui.Canvas, cam: Camera, size: ui.Size, unix: f64) void {
    const sun = geo.subsolar(unix);
    // The night's pole, beyond the square's edge so nothing shows past it.
    const pole_y: f64 = if (sun.lat > 0) 3 else -2;
    const steps = 120;
    const k = cam.copies(size);
    for ([_]f64{ 0, -6, -12 }) |alt| {
        var copy = k[0];
        while (copy <= k[1]) : (copy += 1) {
            const off: f64 = @floatFromInt(copy);
            var pts: [steps + 3]Point = undefined;
            for (0..steps + 1) |i| {
                const lon = -180 + 360 * @as(f64, @floatFromInt(i)) / steps;
                const lat = geo.dusk(sun, lon, alt);
                const y: f64 = if (@abs(lat) > 85) (if (lat > 0) @as(f64, -2) else 3) else geo.mercator(.{ .lat = lat, .lon = lon })[1];
                pts[i] = cam.toScreen(size, (lon + 180) / 360 + off, y);
            }
            pts[steps + 1] = cam.toScreen(size, 1 + off, pole_y);
            pts[steps + 2] = cam.toScreen(size, off, pole_y);
            cv.fill(&pts, colors.night);
        }
    }
}

/// The radar's tiles over the view, as pictures in boxes over the map
/// (under the routes, drawn after them on a canvas of their own).
pub fn drawRadar(c: *ui.Context, w: *weather.Weather, cam: Camera, size: ui.Size, opacity: f32) void {
    if (w.radar == null) return;
    const z = weather.zoomFor(cam.scale);
    const n: u32 = @as(u32, 1) << @intCast(z);
    const v = cam.view(size);
    const t = weather.tilesOver(z, v[0], v[1], v[2], v[3]);
    const side: f32 = @floatCast(cam.scale / @as(f64, @floatFromInt(n)));
    var col = t.c0;
    while (col <= t.c1) : (col += 1) {
        var row = t.r0;
        while (row <= t.r1) : (row += 1) {
            const x: u32 = @intCast(@mod(col, @as(i64, n)));
            const pic = w.tile(z, x, row) orelse continue;
            const at = cam.toScreen(size, @as(f64, @floatFromInt(col)) / @as(f64, @floatFromInt(n)), @as(f64, @floatFromInt(row)) / @as(f64, @floatFromInt(n)));
            const k = c.print("rv{d}:{d}/{d}/{d}", .{ pic.generation, z, x, row });
            ui.key(c, k);
            const box = ui.div(c).absolute().offset(@floor(at.x), @floor(at.y));
            // A hair larger, so tiles meet without a seam.
            const s = @ceil(side) + 1;
            _ = ui.image(c, .{ .key = k, .bytes = pic.png, .max_width = s, .max_height = s, .radius = 0, .opacity = opacity, .scale = weather.tile_px / s });
            box.end();
        }
    }
    w.endFrame();
}

/// A flight's way on the square (`geo.arc`), drawn: flown up to `done`
/// (0 to 1) solid and glowing, the rest dashed.
pub fn drawRoute(cv: *ui.Canvas, cam: Camera, size: ui.Size, arc: []const [2]f64, done: f64, plane: ?[2]f64, faint: bool) void {
    if (arc.len < 2) return;
    const alloc = cv.c.alloc();
    const k = cam.copies(size);
    var copy = k[0] - 1;
    while (copy <= k[1]) : (copy += 1) {
        const off: f64 = @floatFromInt(copy);
        const pts = alloc.alloc(Point, arc.len + 1) catch return;
        // Split where the plane is: up to it, then from it.
        const f = std.math.clamp(done, 0, 1) * @as(f64, @floatFromInt(arc.len - 1));
        const cut: usize = @min(@as(usize, @intFromFloat(@floor(f))), arc.len - 2);
        var n: usize = 0;
        for (arc[0 .. cut + 1]) |p| {
            pts[n] = cam.toScreen(size, p[0] + off, p[1]);
            n += 1;
        }
        const at: [2]f64 = plane orelse lerp(arc[cut], arc[cut + 1], f - @as(f64, @floatFromInt(cut)));
        pts[n] = cam.toScreen(size, at[0] + off, at[1]);
        const split = n;
        n += 1;
        for (arc[cut + 1 ..]) |p| {
            pts[n] = cam.toScreen(size, p[0] + off, p[1]);
            n += 1;
        }
        const a: f32 = if (faint) 0.55 else 1;
        if (done > 0) {
            cv.polyline(pts[0 .. split + 1], .{ .width = 9, .color = colors.route_flown.alpha(0.16 * a) });
            cv.polyline(pts[0 .. split + 1], .{ .width = 3.5, .color = colors.route_flown.alpha(a) });
        }
        cv.polyline(pts[split..n], .{ .width = 2, .color = colors.route_ahead.alpha(0.9 * a), .dash = .{ 5, 6 } });
    }
}

fn lerp(a: [2]f64, b: [2]f64, t: f64) [2]f64 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
}

/// Where on the square `p` is, the copy nearest `near` (a point of its
/// route): a plane over the Pacific lies on its arc's side of the date line.
pub fn place(p: geo.LatLon, near_to: [2]f64) [2]f64 {
    var m = geo.mercator(p);
    while (m[0] - near_to[0] > 0.5) m[0] -= 1;
    while (near_to[0] - m[0] > 0.5) m[0] += 1;
    return m;
}

pub fn drawAirport(cv: *ui.Canvas, at: Point) void {
    cv.circle(at, 7, colors.sea.alpha(0.9));
    cv.circle(at, 4.5, colors.airport);
}

/// A plane, nose up, 24 points long, as one outline (its right half; the
/// left mirrors it).
const plane_half = [_][2]f32{
    .{ 0, -12 }, .{ 1.5, -10 }, .{ 1.7, -3.5 }, .{ 11, 2 },   .{ 11, 4.4 },
    .{ 1.7, 1.6 }, .{ 1.3, 7.6 }, .{ 4.6, 10 },  .{ 4.6, 11.6 }, .{ 0, 10.6 },
};

/// The plane's outline, both halves.
fn planeOutline() [plane_half.len * 2 - 2][2]f32 {
    var out: [plane_half.len * 2 - 2][2]f32 = undefined;
    for (plane_half, 0..) |p, k| out[k] = p;
    // Back up the left side, leaving out the nose and tail on the middle.
    var n: usize = plane_half.len;
    var k: usize = plane_half.len - 2;
    while (k >= 1) : (k -= 1) {
        out[n] = .{ -plane_half[k][0], plane_half[k][1] };
        n += 1;
    }
    return out;
}

const outline = planeOutline();

/// The plane at `at`, its nose `track` degrees clockwise from north.
pub fn drawPlane(cv: *ui.Canvas, at: Point, track: f64, scale: f32, color: ui.Color, halo: bool) void {
    const a: f32 = @floatCast(track * std.math.pi / 180);
    const cs = @cos(a);
    const sn = @sin(a);
    var pts: [outline.len]Point = undefined;
    for (outline, &pts) |p, *q| {
        const x = p[0] * scale;
        const y = p[1] * scale;
        q.* = .{ .x = at.x + x * cs - y * sn, .y = at.y + x * sn + y * cs };
    }
    if (halo) {
        cv.circle(at, 20 * scale, colors.route_flown.alpha(0.16));
        cv.circle(at, 14 * scale, colors.sea.alpha(0.45));
    }
    cv.fill(&pts, color);
}

/// The planes around, faint and small; the one tapped brighter.
pub fn drawTraffic(cv: *ui.Canvas, cam: Camera, size: ui.Size, planes: []const sources.Plane, skip: []const u8, picked: []const u8) void {
    const v = cam.view(size);
    for (planes) |*p| {
        if (skip.len > 0 and std.ascii.eqlIgnoreCase(p.callsign.slice(), skip)) continue;
        const m = place(p.pos, .{ cam.x, cam.y });
        if (m[0] < v[0] - 0.01 or m[0] > v[2] + 0.01 or m[1] < v[1] - 0.01 or m[1] > v[3] + 0.01) continue;
        const at = cam.toScreen(size, m[0], m[1]);
        const is_picked = picked.len > 0 and std.ascii.eqlIgnoreCase(p.callsign.slice(), picked);
        drawPlane(cv, at, p.track, if (is_picked) 0.8 else 0.48, if (is_picked) colors.plane else colors.traffic, false);
    }
}

/// The plane of `planes` nearest `at` on the view, within `reach` points.
pub fn trafficAt(cam: Camera, size: ui.Size, planes: []const sources.Plane, at: Point, reach: f32) ?*const sources.Plane {
    var best: ?*const sources.Plane = null;
    var best_d = reach * reach;
    for (planes) |*p| {
        const m = place(p.pos, .{ cam.x, cam.y });
        const s = cam.toScreen(size, m[0], m[1]);
        const d = (s.x - at.x) * (s.x - at.x) + (s.y - at.y) * (s.y - at.y);
        if (d < best_d) {
            best_d = d;
            best = p;
        }
    }
    return best;
}

test "the camera fits a route, zooms about a point, and glides" {
    const size: ui.Size = .{ .w = 400, .h = 800 };
    const cam = Camera.fit(.{ 0.8, 0.39, 0.9, 0.41 }, .{ .x = 20, .y = 60, .w = 360, .h = 300 }, size);
    // The bounds' corners land inside the area.
    const a = cam.toScreen(size, 0.8, 0.39);
    const b = cam.toScreen(size, 0.9, 0.41);
    try std.testing.expect(a.x >= 19.9 and b.x <= 380.1 and a.y >= 59.9 and b.y <= 360.1);
    // Zooming about a point keeps it where it is.
    const at: Point = .{ .x = 100, .y = 200 };
    const before = cam.toWorld(size, at);
    const z = cam.zoom(2, at, size);
    try std.testing.expectApproxEqAbs(before[0], z.toWorld(size, at)[0], 1e-9);
    // A glide gets there, the short way round the world.
    var g: Camera = .{ .x = 0.95, .y = 0.4, .scale = 400 };
    const goal: Camera = .{ .x = 0.05, .y = 0.4, .scale = 6400 };
    try std.testing.expect(!g.near(goal));
    g = g.toward(goal, 0.1);
    try std.testing.expect(@abs(g.x) < 0.06);
    for (0..200) |_| g = g.toward(goal, 0.1);
    try std.testing.expect(g.near(goal));
}

test "a plane's outline is one simple shape" {
    try std.testing.expectEqual(@as(usize, 18), outline.len);
    var pts: [outline.len]Point = undefined;
    for (outline, &pts) |p, *q| q.* = .{ .x = p[0], .y = p[1] };
    const tris = try ui.triangulate(std.testing.allocator, &pts);
    defer std.testing.allocator.free(tris);
    try std.testing.expectEqual(outline.len - 2, tris.len);
}

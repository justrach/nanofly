//! The map: the land on a dark sea, drawn from its triangles (the coarse
//! outline zoomed out, the fine one closer), a flight's great circle (solid
//! where it has flown, dashed ahead), its airports and the plane, turned
//! to its track. Everything is on Web Mercator's square, and the camera
//! says where on it the view looks and how close.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const geo = @import("geo.zig");
const land_mod = @import("land.zig");

const Point = ui.Point;
const Land = land_mod.Land;

pub const colors = struct {
    pub const sea: ui.Color = .hex(0x0b0d11);
    pub const land: ui.Color = .hex(0x1f232a);
    pub const route_ahead: ui.Color = .hex(0x5c6574);
    pub const route_flown: ui.Color = .hex(0x3d8bff);
    pub const plane: ui.Color = .hex(0xffffff);
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

    /// The squares' copies side by side that the view reaches: a world
    /// seen across the date line.
    fn copies(cam: Camera, size: ui.Size) [2]i32 {
        const half = size.w / 2 / cam.scale;
        return .{ @intFromFloat(@floor(cam.x - half)), @intFromFloat(@floor(cam.x + half)) };
    }
};

pub fn drawLand(cv: *ui.Canvas, cam: Camera, size: ui.Size, coarse: *const Land, fine: *const Land) void {
    const l = if (cam.scale > 4000) fine else coarse;
    const vx0 = cam.x - size.w / 2 / cam.scale;
    const vx1 = cam.x + size.w / 2 / cam.scale;
    const vy0 = cam.y - size.h / 2 / cam.scale;
    const vy1 = cam.y + size.h / 2 / cam.scale;
    const alloc = cv.c.alloc();
    const k = cam.copies(size);
    var copy = k[0];
    while (copy <= k[1]) : (copy += 1) {
        const off: f64 = @floatFromInt(copy);
        for (l.rings) |ring| {
            const b = ring.bounds;
            if (b[2] + off < vx0 or b[0] + off > vx1 or b[3] < vy0 or b[1] > vy1) continue;
            const pts = alloc.alloc(Point, ring.points.len) catch return;
            for (ring.points, pts) |p, *s| s.* = cam.toScreen(size, p[0] + off, p[1]);
            for (ring.tris) |t| cv.triangle(pts[t.v[0]], pts[t.v[1]], pts[t.v[2]], colors.land, t.smooth);
        }
    }
}

/// A flight's way on the square (`geo.arc`), drawn: flown up to `done`
/// (0 to 1) solid, the rest dashed.
pub fn drawRoute(cv: *ui.Canvas, cam: Camera, size: ui.Size, arc: []const [2]f64, done: f64, plane: ?[2]f64) void {
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
        if (done > 0) cv.polyline(pts[0 .. split + 1], .{ .width = 3, .color = colors.route_flown });
        cv.polyline(pts[split..n], .{ .width = 2, .color = colors.route_ahead, .dash = .{ 6, 5 } });
    }
}

fn lerp(a: [2]f64, b: [2]f64, t: f64) [2]f64 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
}

/// Where on the square `p` is, the copy nearest `near` (a point of its
/// route): a plane over the Pacific lies on its arc's side of the date line.
pub fn place(p: geo.LatLon, near: [2]f64) [2]f64 {
    var m = geo.mercator(p);
    while (m[0] - near[0] > 0.5) m[0] -= 1;
    while (near[0] - m[0] > 0.5) m[0] += 1;
    return m;
}

pub fn drawAirport(cv: *ui.Canvas, at: Point) void {
    cv.circle(at, 6, colors.sea);
    cv.circle(at, 4, colors.airport);
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
pub fn drawPlane(cv: *ui.Canvas, at: Point, track: f64, scale: f32) void {
    const a: f32 = @floatCast(track * std.math.pi / 180);
    const cs = @cos(a);
    const sn = @sin(a);
    var pts: [outline.len]Point = undefined;
    for (outline, &pts) |p, *q| {
        const x = p[0] * scale;
        const y = p[1] * scale;
        q.* = .{ .x = at.x + x * cs - y * sn, .y = at.y + x * sn + y * cs };
    }
    cv.circle(at, 15 * scale, colors.sea.alpha(0.55));
    cv.fill(&pts, colors.plane);
}

test "the camera fits a route and zooms about a point" {
    const size: ui.Size = .{ .w = 400, .h = 800 };
    const cam = Camera.fit(.{ 0.8, 0.39, 0.9, 0.41 }, .{ .x = 20, .y = 60, .w = 360, .h = 300 }, size);
    // The bounds' corners land inside the area.
    const a = cam.toScreen(size, 0.8, 0.39);
    const b = cam.toScreen(size, 0.9, 0.41);
    try std.testing.expect(a.x >= 19.9 and b.x <= 380.1 and a.y >= 59.9 and b.y <= 360.1);
    // Zooming about a point keeps it where it is.
    const at: Point = .{ .x = 100, .y = 200 };
    const before_x = cam.x + (at.x - size.w / 2) / cam.scale;
    const z = cam.zoom(2, at, size);
    const after_x = z.x + (at.x - size.w / 2) / z.scale;
    try std.testing.expectApproxEqAbs(before_x, after_x, 1e-9);
}

test "a plane's outline is one simple shape" {
    try std.testing.expectEqual(@as(usize, 18), outline.len);
    var pts: [outline.len]Point = undefined;
    for (outline, &pts) |p, *q| q.* = .{ .x = p[0], .y = p[1] };
    const tris = try ui.triangulate(std.testing.allocator, &pts);
    defer std.testing.allocator.free(tris);
    try std.testing.expectEqual(outline.len - 2, tris.len);
}

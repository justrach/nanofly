//! The screen: the map filling it (dragged to look around, scrolled or
//! zoomed with its buttons), the airports named on it, and a sheet over
//! its lower part with the flights followed or the one shown
//! (view_sheet.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const geo = @import("geo.zig");
const map = @import("map.zig");
const flight = @import("flight.zig");
const tracker = @import("tracker.zig");
const App = @import("app.zig").App;
const sheet = @import("view_sheet.zig");

const arc_points = 96;

pub fn view(a: *App, c: *ui.Context) void {
    const size = c.size;
    const sheet_h = sheet.height(a, size, c.safe_area);
    const root = ui.div(c).sizeFull().bg(map.colors.sea);
    defer root.end();

    // Where the flights are, on the square.
    const now = tracker.now();
    var routes: std.ArrayList(Route) = .empty;
    for (a.tracker.flights.items) |*f| {
        if (a.selected != null and a.selected != f.id) continue;
        if (route(a, c, f)) |r| routes.append(c.alloc(), r) catch {};
    }

    // The camera: on what is shown, above the sheet, until moved by hand.
    const area: ui.Rect = .{ .x = 28, .y = c.safe_area.top + 72, .w = size.w - 56, .h = @max(80, size.h - sheet_h - c.safe_area.top - 110) };
    if (a.follow) a.cam = fitted(routes.items, area, size);

    const box = ui.div(c).absolute().offset(0, 0).size(size.w, size.h);
    pan(a, c, box.interaction(), size);
    const cv = ui.canvas(c, .{ .width = .fill, .height = .fill });
    box.end();
    map.drawLand(cv, a.cam, size, &a.coarse, &a.fine);
    for (routes.items) |r| {
        map.drawRoute(cv, a.cam, size, r.arc, r.done, r.plane);
        for ([_][2]f64{ r.arc[0], r.arc[r.arc.len - 1] }) |p| map.drawAirport(cv, a.cam.toScreen(size, p[0], p[1]));
    }
    for (routes.items) |r| if (r.plane) |p| {
        const f = a.tracker.find(r.id).?;
        map.drawPlane(cv, a.cam.toScreen(size, p[0], p[1]), f.live.?.track, if (a.selected != null) 1.2 else 0.9);
    };
    // The airports' codes beside them.
    for (routes.items) |r| {
        const f = a.tracker.find(r.id).?;
        label(c, a.cam.toScreen(size, r.arc[0][0], r.arc[0][1]), f.origin(&a.d).?.code());
        const e = r.arc[r.arc.len - 1];
        label(c, a.cam.toScreen(size, e[0], e[1]), f.destination(&a.d).?.code());
    }
    controls(a, c, size, routes.items, area);
    _ = now;
    sheet.sheet(a, c, size, sheet_h);
}

/// A flight's way on the map, and where along it the plane is.
const Route = struct {
    id: u32,
    arc: [][2]f64,
    done: f64,
    plane: ?[2]f64,
};

fn route(a: *App, c: *ui.Context, f: *const flight.Flight) ?Route {
    const from = f.origin(&a.d) orelse return null;
    const to = f.destination(&a.d) orelse return null;
    const arc = c.alloc().alloc([2]f64, arc_points) catch return null;
    geo.arc(from.pos, to.pos, arc);
    var r: Route = .{ .id = f.id, .arc = arc, .done = 0, .plane = null };
    if (f.live) |l| {
        r.done = f.progress(&a.d);
        const k: usize = @intFromFloat(@round(r.done * (arc_points - 1)));
        r.plane = map.place(l.pos, arc[k]);
    }
    if (f.phase(&a.d, tracker.now()) == .landed) r.done = 1;
    return r;
}

/// The camera showing every route (the plane on it, too); the whole
/// world's busy middle when there are none.
fn fitted(routes: []const Route, area: ui.Rect, size: ui.Size) map.Camera {
    if (routes.len == 0) return map.Camera.fit(.{ 0.05, 0.28, 0.95, 0.62 }, area, size);
    var b: [4]f64 = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (routes) |r| {
        for (r.arc) |p| b = .{ @min(b[0], p[0]), @min(b[1], p[1]), @max(b[2], p[0]), @max(b[3], p[1]) };
    }
    // A short hop still shows the land around it.
    const min_span: f64 = 0.012;
    if (b[2] - b[0] < min_span) {
        const m = (b[0] + b[2]) / 2;
        b[0] = m - min_span / 2;
        b[2] = m + min_span / 2;
    }
    if (b[3] - b[1] < min_span) {
        const m = (b[1] + b[3]) / 2;
        b[1] = m - min_span / 2;
        b[3] = m + min_span / 2;
    }
    return map.Camera.fit(b, area, size);
}

/// Dragging the map moves it; a scroll (a trackpad, a wheel) zooms it.
fn pan(a: *App, c: *ui.Context, it: ui.Interaction, size: ui.Size) void {
    const m = c.input.mouse;
    if (it.pressed) {
        if (a.drag) |last| {
            const dx = m.x - last.x;
            const dy = m.y - last.y;
            if (dx != 0 or dy != 0) {
                a.cam.x -= dx / a.cam.scale;
                a.cam.y = std.math.clamp(a.cam.y - dy / a.cam.scale, 0, 1);
                a.follow = false;
            }
        }
        a.drag = m;
    } else a.drag = null;
    if (it.hovered and c.input.scroll.y != 0) {
        a.cam = a.cam.zoom(@exp(@as(f64, c.input.scroll.y) * 0.01), m, size);
        a.follow = false;
    }
}

fn label(c: *ui.Context, at: ui.Point, code: []const u8) void {
    const box = ui.div(c).absolute().offset(at.x + 9, at.y - 22).px(6).py(2).rounded(6).bg(map.colors.sea.alpha(0.75));
    defer box.end();
    ui.text(c, code, .{ .size = 13, .weight = .bold, .color = .hex(0xffffff) });
}

/// Zoom in, out, and back onto what is shown: glass buttons at the right.
fn controls(a: *App, c: *ui.Context, size: ui.Size, routes: []const Route, area: ui.Rect) void {
    const col = ui.div(c).absolute().offset(size.w - 60, c.safe_area.top + 14).column().gap(10);
    defer col.end();
    const middle: ui.Point = .{ .x = size.w / 2, .y = area.y + area.h / 2 };
    if (button(c, "plus")) {
        a.cam = a.cam.zoom(2, middle, size);
        a.follow = false;
    }
    if (button(c, "minus")) {
        a.cam = a.cam.zoom(0.5, middle, size);
        a.follow = false;
    }
    if (button(c, "location.fill")) {
        a.follow = true;
        a.cam = fitted(routes, area, size);
    }
}

fn button(c: *ui.Context, symbol: []const u8) bool {
    const b = ui.div(c).size(46, 46).roundedFull().glass(.{}).center().control();
    defer b.end();
    ui.icon(c, symbol, .{ .size = 17, .weight = .semibold, .color = .hex(0xffffff) });
    return b.clicked();
}

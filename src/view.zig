//! The screen: the map filling it (dragged, flung, pinched or scrolled to
//! look around; a tap on a plane shows it), the night and the weather on
//! it, the airports named, glass over it (the flight's speed and height at
//! the top, the map's buttons at the right), and the sheet over its lower
//! part (view_sheet.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const geo = @import("geo.zig");
const map = @import("map.zig");
const flight = @import("flight.zig");
const tracker = @import("tracker.zig");
const style = @import("style.zig");
const App = @import("app.zig").App;
const sheet = @import("view_sheet.zig");

const colors = style.colors;
const arc_points = 96;

pub fn view(a: *App, c: *ui.Context) void {
    const size = c.size;
    const now = tracker.now();
    const root = ui.div(c).sizeFull().bg(map.colors.sea);
    defer root.end();
    const top = sheet.top(a, c, size);

    // Where the flights are, on the square.
    var routes: std.ArrayList(Route) = .empty;
    for (a.tracker.flights.items) |*f| {
        if (a.selected != null and a.selected != f.id) continue;
        if (route(a, c, f, now)) |r| routes.append(c.alloc(), r) catch {};
    }

    // The camera: on what is shown, between the glass at the top and the
    // sheet, gliding there; or where a hand (or a fling) left it.
    const area: ui.Rect = .{ .x = 40, .y = c.safe_area.top + 96, .w = size.w - 40 - 80, .h = @max(60, top - c.safe_area.top - 96 - 56) };
    var settled = a.drag == null and a.fling.x == 0 and a.fling.y == 0;
    if (a.follow) {
        const goal = fitted(routes.items, area, size);
        a.cam = if (a.cam.near(goal)) goal else a.cam.toward(goal, 1 - @exp(-@as(f64, c.dt) * 7));
        if (!a.cam.near(goal)) {
            c.animationFrame();
            settled = false;
        }
    }
    fling(a, c, size);

    {
        const box = ui.div(c).absolute().offset(0, 0).size(size.w, size.h);
        defer box.end();
        gestures(a, c, box.interaction(), size, top, routes.items);
        const under = layer(c, size);
        map.drawLand(under, a.cam, size, &a.coarse, &a.fine);
        map.drawNight(under, a.cam, size, now);
        if (a.show_weather) {
            a.weather.refreshRadar(now);
            map.drawRadar(c, &a.weather, a.cam, size, 0.7);
        }
        const over = layer(c, size);
        if (a.show_traffic and a.cam.scale > 1500) {
            // Asked where the map comes to rest, not on its way there.
            if (settled) wantTraffic(a, c, size, top, now);
            const own = if (a.shown()) |f| f.callsign.slice() else "";
            map.drawTraffic(over, a.cam, size, a.traffic.items(), own, a.picked.slice());
        }
        for (routes.items) |r| {
            map.drawRoute(over, a.cam, size, r.arc, r.done, r.plane, false);
            for ([_][2]f64{ r.arc[0], r.arc[r.arc.len - 1] }) |p| map.drawAirport(over, a.cam.toScreen(size, p[0], p[1]));
        }
        for (routes.items) |r| if (r.plane) |p| {
            const f = a.tracker.find(r.id).?;
            map.drawPlane(over, a.cam.toScreen(size, p[0], p[1]), f.live.?.track, if (a.selected != null) 1.25 else 0.95, map.colors.plane, a.selected != null);
        };
    }
    // The airports' codes beside them, when there's room: one flight, or close.
    if (a.selected != null or a.cam.scale > 3000) for (routes.items) |r| {
        const f = a.tracker.find(r.id).?;
        const e = r.arc[r.arc.len - 1];
        const from = a.cam.toScreen(size, r.arc[0][0], r.arc[0][1]);
        const to = a.cam.toScreen(size, e[0], e[1]);
        // Each over its airport, or under it when the other end is above.
        label(c, from, f.origin(&a.d).?.code(), size, from.y > to.y + 30);
        label(c, to, f.destination(&a.d).?.code(), size, to.y > from.y + 30);
    };
    picked(a, c, size);
    hud(a, c, size, now);
    controls(a, c, size);
    if (a.show_weather) legend(a, c, top, now);
    sheet.sheet(a, c, size, top, now);
    toast(a, c, size, now);
}

/// A canvas over the whole map, its own layer.
fn layer(c: *ui.Context, size: ui.Size) *ui.Canvas {
    const box = ui.div(c).absolute().offset(0, 0).size(size.w, size.h);
    defer box.end();
    return ui.canvas(c, .{ .width = .fill, .height = .fill });
}

/// A flight's way on the map, and where along it the plane is.
const Route = struct {
    id: u32,
    arc: [][2]f64,
    done: f64,
    plane: ?[2]f64,
};

fn route(a: *App, c: *ui.Context, f: *const flight.Flight, now: f64) ?Route {
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
    if (f.phase(&a.d, now) == .landed) r.done = 1;
    return r;
}

/// The camera showing every route (the plane on it, too); the whole
/// world's busy middle when there are none.
fn fitted(routes: []const Route, area: ui.Rect, size: ui.Size) map.Camera {
    if (routes.len == 0) return map.Camera.fit(.{ 0.05, 0.25, 0.95, 0.6 }, area, size);
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

/// A finger drags the map (and, let go moving, flings it); two pinch it;
/// a trackpad's scroll zooms it; a tap shows the plane under it.
fn gestures(a: *App, c: *ui.Context, it: ui.Interaction, size: ui.Size, top: f32, routes: []const Route) void {
    const in = c.input;
    const m = in.mouse;
    if ((in.zoom != 1 or in.pan.x != 0 or in.pan.y != 0) and m.y < top) {
        a.cam = a.cam.zoom(in.zoom, m, size).moved(in.pan.x, in.pan.y);
        a.follow = false;
        a.fling = .{};
    }
    if (it.hovered and m.y < top) c.wants_wheel = true;
    if (it.hovered and in.scroll.y != 0) {
        a.cam = a.cam.zoom(@exp(@as(f64, in.scroll.y) * 0.01), m, size);
        a.follow = false;
    }
    if (it.pressed) {
        if (a.drag) |last| {
            const dx = m.x - last.x;
            const dy = m.y - last.y;
            if (!a.dragged and @abs(m.x - a.drag_from.x) + @abs(m.y - a.drag_from.y) > 8) a.dragged = true;
            if (a.dragged and (dx != 0 or dy != 0)) {
                a.cam = a.cam.moved(dx, dy);
                a.follow = false;
                // The finger's speed, smoothed, for the fling.
                const dt = @max(c.time - a.drag_time, 1.0 / 240.0);
                const k: f32 = 0.7;
                a.fling = .{ .x = k * dx / @as(f32, @floatCast(dt)) + (1 - k) * a.fling.x, .y = k * dy / @as(f32, @floatCast(dt)) + (1 - k) * a.fling.y };
            }
        } else {
            a.drag_from = m;
            a.dragged = false;
            a.fling = .{};
        }
        a.drag = m;
        a.drag_time = c.time;
    } else if (a.drag != null) {
        a.drag = null;
        // Held still before letting go: no fling.
        if (!a.dragged or c.time - a.drag_time > 0.08) a.fling = .{};
        if (!a.dragged and it.clicked) tap(a, a.drag_from, size, routes);
        if (a.fling.x != 0 or a.fling.y != 0) c.animationFrame();
    }
}

/// The map moving on after a fling, slowing as a scroll view does.
fn fling(a: *App, c: *ui.Context, size: ui.Size) void {
    _ = size;
    if (a.drag != null or (a.fling.x == 0 and a.fling.y == 0)) return;
    const dt = c.dt;
    a.cam = a.cam.moved(a.fling.x * dt, a.fling.y * dt);
    const keep = @exp(-dt * 4.5);
    a.fling = .{ .x = a.fling.x * keep, .y = a.fling.y * keep };
    if (@abs(a.fling.x) + @abs(a.fling.y) < 15) a.fling = .{} else c.animationFrame();
}

/// A tap: a plane around (its card), a flight's plane (shown), else the
/// sheet out of the way, or back.
fn tap(a: *App, at: ui.Point, size: ui.Size, routes: []const Route) void {
    if (a.show_traffic and a.cam.scale > 1500) if (map.trafficAt(a.cam, size, a.traffic.items(), at, 26)) |p| {
        a.picked = if (std.mem.eql(u8, a.picked.slice(), p.callsign.slice())) .{} else p.callsign;
        return;
    };
    for (routes) |r| if (r.plane) |p| {
        const s = a.cam.toScreen(size, p[0], p[1]);
        if (@abs(s.x - at.x) < 30 and @abs(s.y - at.y) < 30) {
            if (a.selected != r.id) a.select(r.id);
            return;
        }
    };
    if (a.picked.len > 0) {
        a.picked = .{};
        return;
    }
    a.detent = if (a.detent == .peek) .half else .peek;
}

/// The planes around the middle of the map that shows (above the sheet),
/// asked for as far as it reaches.
fn wantTraffic(a: *App, c: *ui.Context, size: ui.Size, top: f32, now: f64) void {
    const y0 = c.safe_area.top;
    const at = a.cam.toWorld(size, .{ .x = size.w / 2, .y = (y0 + top) / 2 });
    const mid = geo.unmercator(at[0], at[1]);
    const km_per_pt = 40075 * @cos(mid.lat * std.math.pi / 180) / a.cam.scale;
    const h = top - y0;
    const reach = @sqrt(size.w * size.w + h * h) / 2 * km_per_pt / geo.km_per_nm;
    a.traffic.want(mid, reach, now, 30);
}

fn label(c: *ui.Context, at: ui.Point, code: []const u8, size: ui.Size, under: bool) void {
    if (at.x < -40 or at.y < -40 or at.x > size.w + 40 or at.y > size.h + 40) return;
    const w = @as(f32, @floatFromInt(code.len)) * 9.6 + 14;
    const box = ui.div(c).absolute().offset(at.x - w / 2, if (under) at.y + 12 else at.y - 37).px(7).py(3).rounded(8).bg(map.colors.sea.alpha(0.8)).border(colors.hairline);
    defer box.end();
    ui.text(c, code, .{ .size = 13, .weight = .bold, .color = .hex(0xffffff) });
}

/// A plane around, tapped: what it is, and to follow it.
fn picked(a: *App, c: *ui.Context, size: ui.Size) void {
    if (a.picked.len == 0) return;
    const p = a.traffic.find(a.picked.slice()) orelse return;
    const m = map.place(p.pos, .{ a.cam.x, a.cam.y });
    const at = a.cam.toScreen(size, m[0], m[1]);
    const w: f32 = 210;
    const x = std.math.clamp(at.x - w / 2, 12, size.w - w - 12);
    const y = if (at.y - 112 > c.safe_area.top + 60) at.y - 112 else at.y + 24;
    const f = ui.motion.frame(c, .{ .initial = .{ .scale = 0.9, .opacity = 0 }, .transition = style.settle });
    const card = ui.div(c).absolute().offset(x, y).w(w).column().gap(6).p(12).rounded(18).glass(.{}).motion(f);
    defer card.end();
    {
        const row = ui.div(c).wFull().row().itemsCenter().gap(8);
        defer row.end();
        ui.icon(c, "airplane", .{ .size = 13, .weight = .bold, .color = colors.text });
        ui.text(c, p.callsign.slice(), .{ .size = 16, .weight = .bold, .color = colors.text });
        if (p.type.len > 0) ui.text(c, p.type.slice(), .{ .size = 13, .color = colors.muted });
    }
    ui.text(c, c.print("{s} ft · {d:.0} mph", .{ style.grouped(c, p.alt_ft), p.gs_kt * 1.15078 }), .{ .size = 13, .color = colors.muted });
    const q = flight.Query.parse(p.callsign.slice());
    if (q != null) {
        const b = ui.div(c).wFull().h(34).center().rounded(12).bg(colors.blue).control();
        defer b.end();
        ui.text(c, "Follow this flight", .{ .size = 14, .weight = .semibold, .color = .hex(0xffffff) });
        if (b.clicked()) _ = a.followFlight(p.callsign.slice());
    }
}

/// The flight's speed and height, in glass at the top (as it flies).
fn hud(a: *App, c: *ui.Context, size: ui.Size, now: f64) void {
    const f = a.shown() orelse return;
    const l = f.live orelse return;
    if (f.phase(&a.d, now) != .airborne and f.phase(&a.d, now) != .taxiing) return;
    const w: f32 = 216;
    const bar = ui.div(c).absolute().offset((size.w - w) / 2 - 20, c.safe_area.top + 8).w(w).h(44).row().itemsCenter().justifyCenter().gap(14).roundedFull().glass(.{});
    defer bar.end();
    reading(c, "speedometer", c.print("{d:.0}", .{l.gs_kt * 1.15078}), "MPH");
    reading(c, "arrow.up.and.down", style.grouped(c, l.alt_ft), "FT");
}

fn reading(c: *ui.Context, symbol: []const u8, value: []const u8, unit: []const u8) void {
    const row = ui.div(c).row().itemsCenter().gap(5);
    defer row.end();
    ui.icon(c, symbol, .{ .size = 14, .weight = .semibold, .color = colors.text });
    ui.text(c, value, .{ .size = 17, .weight = .bold, .color = colors.text });
    ui.text(c, unit, .{ .size = 12, .weight = .semibold, .color = colors.muted });
}

/// The map's buttons, in one glass bar at the right: back onto what is
/// shown, the weather, the planes around.
fn controls(a: *App, c: *ui.Context, size: ui.Size) void {
    const bar = ui.div(c).absolute().offset(size.w - 62, c.safe_area.top + 6).w(48).column().roundedFull().glass(.{}).py(4);
    defer bar.end();
    if (style.barButton(c, if (a.follow) "location.fill" else "location", colors.text, false)) {
        a.follow = true;
        a.fling = .{};
    }
    if (style.barButton(c, "cloud.sun.rain.fill", colors.text, a.show_weather)) a.show_weather = !a.show_weather;
    if (style.barButton(c, "airplane", colors.text, a.show_traffic)) {
        a.show_traffic = !a.show_traffic;
        a.picked = .{};
    }
}

/// What the radar shows and how old it is, over the sheet's top left.
fn legend(a: *App, c: *ui.Context, top: f32, now: f64) void {
    const r = a.weather.radar orelse return;
    const box = ui.div(c).absolute().offset(16, top - 40).h(30).px(12).row().itemsCenter().gap(7).roundedFull().glass(.{});
    defer box.end();
    // The radar's own scale, light to heavy.
    for ([_]u24{ 0x88ddee, 0x0099cc, 0x0077aa, 0xffee00, 0xff4400 }) |hex| {
        const dot = ui.div(c).size(7, 7).roundedFull().bg(.hex(hex));
        dot.end();
    }
    ui.text(c, c.print("Radar · {s} ago", .{style.ago(c, @max(60, now - r.time))}), .{ .size = 12, .weight = .semibold, .color = colors.text });
}

/// A word in glass for a moment ("Copied").
fn toast(a: *App, c: *ui.Context, size: ui.Size, now: f64) void {
    const show = now < a.toast_until;
    if (show) c.frameIn(@floatCast(@max(0.05, a.toast_until - now)));
    const f = ui.motion.present(c, "toast", show, .{
        .initial = .{ .y = -12, .opacity = 0 },
        .exit = .{ .y = -12, .opacity = 0 },
        .transition = style.settle,
    }) orelse return;
    const w: f32 = 180;
    const box = ui.div(c).absolute().offset((size.w - w) / 2, c.safe_area.top + 60).w(w).h(40).center().roundedFull().glass(.{}).motion(f);
    defer box.end();
    ui.text(c, a.toast, .{ .size = 14, .weight = .semibold, .color = colors.text });
}

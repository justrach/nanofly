//! A flight's card, in the sheet: its head (the airline, the number and
//! day, where from and to), how it's doing in a band across, each end's
//! time by its airport's clock with the weather there, the way between
//! them flown so far, and what it is doing now and what flies it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const data = @import("data.zig");
const flight = @import("flight.zig");
const weather = @import("weather.zig");
const style = @import("style.zig");
const App = @import("app.zig").App;

const Flight = flight.Flight;
const colors = style.colors;
const time = style.time;
const ago = style.ago;

/// The card's head, where the sheet is held: the badge, "LH 450 · WED,
/// 21 OCT", "Frankfurt to Los Angeles", and the close button.
pub fn head(a: *App, c: *ui.Context, f: *Flight, now: f64) void {
    const from = f.origin(&a.d);
    const to = f.destination(&a.d);
    const row = ui.div(c).wFull().row().itemsCenter().gap(12).px(20);
    defer row.end();
    style.badge(c, f.query.airline.slice(), 44);
    {
        const col = ui.div(c).grow().column().gap(2);
        defer col.end();
        const day = time(c, now, if (from) |p| p.tz else "", "EEE, d MMM");
        ui.text(c, c.print("{s} · {s}", .{ f.label.slice(), std.ascii.upperString(@constCast(day), day) }), .{ .size = 13, .weight = .semibold, .color = colors.muted });
        const title = if (from != null and to != null) c.print("{s} to {s}", .{ from.?.city, to.?.city }) else f.label.slice();
        ui.text(c, title, .{ .size = 22, .weight = .bold, .color = colors.text });
    }
    if (style.glassButton(c, "xmark", 38, false)) a.select(null);
}

pub const Status = struct { title: []const u8, detail: []const u8 = "", short: []const u8, color: ui.Color };

pub fn status(a: *App, c: *ui.Context, f: *const Flight, now: f64) Status {
    return switch (f.phase(&a.d, now)) {
        .finding => .{ .title = "Looking it up…", .short = "Finding", .color = colors.muted },
        .unknown => .{ .title = "No route found for this number", .detail = "Check it, or try the operating airline's code.", .short = "Unknown", .color = colors.amber },
        .waiting => .{ .title = "Not in the air yet", .detail = "It shows here live as soon as it takes off.", .short = "Scheduled", .color = colors.muted },
        .taxiing => .{ .title = "On the ground", .detail = "Taxiing, or at the gate.", .short = "Taxiing", .color = colors.amber },
        .airborne => blk: {
            const left = ago(c, f.etaSeconds(&a.d) orelse 0);
            const l = f.live.?;
            break :blk .{
                .title = c.print("In the air · lands in {s}", .{left}),
                .detail = c.print("{s} ft · {d:.0} mph · heard {d:.0}s ago", .{ style.grouped(c, l.alt_ft), l.gs_kt * 1.15078, @max(0, now - f.heard_at + l.age_s) }),
                .short = c.print("{s} left", .{left}),
                .color = colors.green,
            };
        },
        .landed => .{ .title = "Landed", .detail = c.print("Down {s} ago.", .{ago(c, now - f.heard_at)}), .short = "Landed", .color = colors.blue },
        .lost => .{
            .title = "Out of range",
            .detail = c.print("Last heard {s} ago: over the sea, or out of the receivers' reach.", .{ago(c, now - f.heard_at)}),
            .short = "No signal",
            .color = colors.amber,
        },
    };
}

/// The card under its head.
pub fn body(a: *App, c: *ui.Context, f: *Flight, now: f64) void {
    const from = f.origin(&a.d);
    const to = f.destination(&a.d);
    band(c, status(a, c, f, now));
    if (from) |p| end(a, c, f, p, .departure, now);
    if (from != null and to != null) journey(a, c, f);
    if (to) |p| end(a, c, f, p, .arrival, now);
    if (f.live) |*l| {
        style.section(c, "Right now");
        tiles(c, &.{
            .{ .label = "Altitude", .symbol = "arrow.up.and.down", .value = c.print("{s} ft", .{style.grouped(c, l.alt_ft)}) },
            .{ .label = "Speed", .symbol = "speedometer", .value = c.print("{d:.0} mph", .{l.gs_kt * 1.15078}) },
            .{ .label = "Heading", .symbol = "location.north.line.fill", .value = c.print("{d:.0}° {s}", .{ l.track, compass(l.track) }) },
            .{ .label = "Climb", .symbol = "chart.line.uptrend.xyaxis", .value = climb(c, l.vs_fpm) },
        });
        style.section(c, "Aircraft");
        tiles(c, &.{
            .{ .label = "Type", .symbol = "airplane", .value = if (l.type.len > 0) c.print("{s}", .{l.type.slice()}) else "—" },
            .{ .label = "Registration", .symbol = "number", .value = if (l.reg.len > 0) c.print("{s}", .{l.reg.slice()}) else "—" },
            .{ .label = "Transponder", .symbol = "dot.radiowaves.left.and.right", .value = c.print("{s}", .{l.hex.slice()}) },
            .{ .label = "Heard by", .symbol = "antenna.radiowaves.left.and.right", .value = if (l.source == .adsb_lol) "adsb.lol" else "OpenSky" },
        });
    }
    if (from != null and to != null) {
        style.section(c, "Weather");
        const row = ui.div(c).wFull().row().gap(10).px(20);
        defer row.end();
        for ([_]*const data.Airport{ from.?, to.? }) |p| weatherTile(a, c, p, now);
    }
    {
        const foot = ui.div(c).wFull().column().gap(10).px(20).pt(6);
        defer foot.end();
        const rm = ui.div(c).wFull().h(48).center().rounded(16).bg(colors.tile).control();
        ui.text(c, "Stop following", .{ .size = 15, .weight = .semibold, .color = colors.red });
        if (rm.clicked()) a.unfollow(f.id);
        rm.end();
        ui.text(c, "Positions: adsb.lol (ODbL), OpenSky Network. Weather: RainViewer, Open-Meteo (CC BY 4.0).", .{ .size = 11, .color = colors.faint, .wrap = true });
    }
}

/// How it's doing, in a band across the sheet.
fn band(c: *ui.Context, st: Status) void {
    const b = ui.div(c).wFull().column().gap(3).px(20).py(14).bg(st.color.alpha(0.13));
    defer b.end();
    ui.text(c, st.title, .{ .size = 18, .weight = .semibold, .color = st.color });
    if (st.detail.len > 0) ui.text(c, st.detail, .{ .size = 14, .color = st.color.alpha(0.8), .wrap = true });
}

const End = enum { departure, arrival };

/// One end of the flight: the airport, its time (taken off, or landing,
/// on its own clock), and at the right its code and the weather there.
fn end(a: *App, c: *ui.Context, f: *const Flight, p: *const data.Airport, which: End, now: f64) void {
    const box = ui.div(c).wFull().column().gap(4).px(20).pt(6);
    defer box.end();
    {
        const row = ui.div(c).wFull().row().itemsCenter().gap(8);
        defer row.end();
        const dot = ui.div(c).size(20, 20).roundedFull().bg(colors.text).center();
        ui.icon(c, if (which == .departure) "arrow.up.right" else "arrow.down.right", .{ .size = 10, .weight = .bold, .color = colors.sheet });
        dot.end();
        var nb: [80]u8 = undefined;
        ui.text(c, c.print("{s} · {s}", .{ p.code(), data.shortName(&nb, p.name) }), .{ .size = 16, .weight = .semibold, .color = colors.text });
    }
    const phase = f.phase(&a.d, now);
    var at: []const u8 = "—";
    var sub: []const u8 = "";
    var color = colors.text;
    switch (which) {
        .departure => if (f.airborne_since > 0) {
            at = time(c, f.airborne_since, p.tz, if (f.takeoff_estimated) "~h:mm a" else "h:mm a");
            sub = c.print("Took off {s}{s} ago", .{ if (f.takeoff_estimated) "about " else "", ago(c, now - f.airborne_since) });
        } else {
            sub = "Not taken off yet";
        },
        .arrival => if (phase == .landed) {
            at = time(c, f.heard_at, p.tz, "h:mm a");
            sub = "Landed";
            color = colors.blue;
        } else if (phase == .airborne) {
            const eta = f.etaSeconds(&a.d) orelse 0;
            at = time(c, now + eta, p.tz, "h:mm a");
            sub = c.print("Arrives in {s}", .{ago(c, eta)});
            color = colors.green;
        } else {
            sub = "When it's in the air";
        },
    }
    const row = ui.div(c).wFull().row().itemsEnd().gap(12);
    defer row.end();
    {
        const col = ui.div(c).grow().column().gap(2);
        defer col.end();
        ui.text(c, at, .{ .size = 42, .weight = .bold, .color = color });
        ui.text(c, sub, .{ .size = 14, .weight = .medium, .color = if (color.r == colors.text.r) colors.muted else color.alpha(0.85) });
    }
    {
        const col = ui.div(c).column().itemsEnd().gap(6).pb(2);
        defer col.end();
        const chip = ui.div(c).row().itemsCenter().gap(4).px(10).py(5).rounded(10).bg(colors.chip);
        ui.icon(c, if (which == .departure) "arrow.up.right" else "arrow.down.right", .{ .size = 13, .weight = .bold, .color = .hex(0x111111) });
        ui.text(c, p.code(), .{ .size = 20, .weight = .bold, .color = .hex(0x111111) });
        chip.end();
        const line = ui.div(c).row().itemsCenter().gap(5);
        defer line.end();
        if (a.weather.at(airportIndex(a, p), p.pos, now)) |w| {
            const d = weather.describe(w.code, w.day);
            ui.icon(c, d.symbol, .{ .size = 12, .color = colors.muted });
            ui.text(c, c.print("{d:.0}° · {s}", .{ w.temp_c, time(c, now, p.tz, "h:mm a") }), .{ .size = 13, .color = colors.muted });
        } else ui.text(c, c.print("{s} local", .{time(c, now, p.tz, "h:mm a")}), .{ .size = 13, .color = colors.muted });
    }
}

fn airportIndex(a: *App, p: *const data.Airport) u32 {
    return @intCast((@intFromPtr(p) - @intFromPtr(a.d.airports.ptr)) / @sizeOf(data.Airport));
}

/// The way between the ends: how long and far, and a line of it, flown
/// up to the plane.
fn journey(a: *App, c: *ui.Context, f: *const Flight) void {
    const row = ui.div(c).wFull().row().itemsCenter().gap(10).px(20).py(6);
    defer row.end();
    const km = f.routeKm(&a.d) orelse 0;
    ui.icon(c, "clock", .{ .size = 12, .color = colors.faint });
    ui.text(c, c.print("{s} · {s} mi", .{ ago(c, f.blockSeconds(&a.d) orelse 0), style.grouped(c, km / 1.609344) }), .{ .size = 14, .color = colors.muted });
    progress(c, @floatCast(f.progress(&a.d)), f.live != null, 4);
}

/// A line flown up to `done` (0 to 1), the plane on it while it flies.
pub fn progress(c: *ui.Context, done: f32, flying: bool, thick: f32) void {
    _ = c.open(.{ .direction = .row, .grow = 1, .align_items = .center, .height = .{ .px = 18 } }, null);
    defer c.end();
    _ = c.leaf(.{ .grow = @max(done, 0.001), .height = .{ .px = thick }, .radius = thick / 2, .background = colors.blue }, .none, null);
    if (flying) ui.icon(c, "airplane", .{ .size = 15, .weight = .bold, .color = colors.text });
    _ = c.leaf(.{ .grow = @max(1 - done, 0.001), .height = .{ .px = thick / 2 }, .radius = thick / 4, .background = colors.hairline.alpha(0.2) }, .none, null);
}

const Tile = struct { label: []const u8, symbol: []const u8, value: []const u8 };

/// Tiles two by two.
fn tiles(c: *ui.Context, items: []const Tile) void {
    const w = (c.size.w - 16 - 40 - 10) / 2;
    const grid = ui.div(c).wFull().column().gap(10).px(20);
    defer grid.end();
    var k: usize = 0;
    while (k < items.len) : (k += 2) {
        const row = ui.div(c).wFull().row().gap(10);
        defer row.end();
        for (items[k..@min(k + 2, items.len)]) |t| {
            const box = ui.div(c).w(w).column().gap(6).p(14).rounded(18).bg(colors.tile);
            defer box.end();
            {
                const top = ui.div(c).row().itemsCenter().gap(6);
                defer top.end();
                ui.icon(c, t.symbol, .{ .size = 11, .weight = .semibold, .color = colors.muted });
                ui.text(c, t.label, .{ .size = 12, .weight = .medium, .color = colors.muted });
            }
            ui.text(c, t.value, .{ .size = 20, .weight = .semibold, .color = colors.text });
        }
    }
}

/// The weather now at one end: its symbol, the temperature, the wind.
fn weatherTile(a: *App, c: *ui.Context, p: *const data.Airport, now: f64) void {
    const w = (c.size.w - 16 - 40 - 10) / 2;
    const box = ui.div(c).w(w).column().gap(6).p(14).rounded(18).bg(colors.tile);
    defer box.end();
    ui.text(c, p.code(), .{ .size = 12, .weight = .semibold, .color = colors.muted });
    const now_w = a.weather.at(airportIndex(a, p), p.pos, now) orelse {
        ui.text(c, "…", .{ .size = 24, .weight = .bold, .color = colors.faint });
        return;
    };
    const d = weather.describe(now_w.code, now_w.day);
    {
        const row = ui.div(c).row().itemsCenter().gap(8);
        defer row.end();
        ui.icon(c, d.symbol, .{ .size = 22, .color = if (weather.rough(now_w.code)) colors.amber else colors.text });
        ui.text(c, c.print("{d:.0}°", .{now_w.temp_c}), .{ .size = 26, .weight = .bold, .color = colors.text });
    }
    ui.text(c, d.text, .{ .size = 13, .weight = .medium, .color = if (weather.rough(now_w.code)) colors.amber else colors.muted });
    ui.text(c, c.print("Wind {d:.0} km/h", .{now_w.wind_kmh}), .{ .size = 12, .color = colors.faint });
}

fn compass(deg: f64) []const u8 {
    const names = [_][]const u8{ "N", "NE", "E", "SE", "S", "SW", "W", "NW" };
    return names[@as(usize, @intFromFloat(@mod(@round(deg / 45), 8)))];
}

fn climb(c: *ui.Context, fpm: f64) []const u8 {
    if (@abs(fpm) < 200) return "Level";
    return c.print("{s} {s} ft/m", .{ if (fpm > 0) "↑" else "↓", style.grouped(c, @abs(fpm)) });
}

/// The flight in a line, to share: "LH 450 · Frankfurt → Los Angeles ·
/// lands 3:15 PM".
pub fn summary(a: *App, c: *ui.Context, f: *const Flight, now: f64) []const u8 {
    const from = f.origin(&a.d) orelse return f.label.slice();
    const to = f.destination(&a.d) orelse return f.label.slice();
    const when = if (f.phase(&a.d, now) == .airborne)
        c.print(" · lands {s} local", .{time(c, now + (f.etaSeconds(&a.d) orelse 0), to.tz, "h:mm a")})
    else
        "";
    return c.print("{s} · {s} → {s}{s}", .{ f.label.slice(), from.city, to.city, when });
}

//! The flights followed, in the sheet: its head ("My Flights" and the
//! search field that adds one), then a card for each (its codes large with
//! the way between them flown so far, its times and how it's doing), or,
//! with none yet, a few to try.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const flight = @import("flight.zig");
const style = @import("style.zig");
const card = @import("view_card.zig");
const App = @import("app.zig").App;

const Flight = flight.Flight;
const colors = style.colors;

/// Flights to try, with none followed: long ones, often in the air.
const suggestions = [_][]const u8{ "BA 117", "SQ 22", "QF 1" };

pub fn head(a: *App, c: *ui.Context, now: f64) void {
    const box = ui.div(c).wFull().column().gap(12).px(20);
    defer box.end();
    {
        const row = ui.div(c).wFull().row().itemsCenter();
        defer row.end();
        const col = ui.div(c).grow().column().gap(1);
        defer col.end();
        ui.text(c, "My Flights", .{ .size = 30, .weight = .bold, .color = colors.text });
        ui.text(c, count(a, c, now), .{ .size = 13, .weight = .medium, .color = colors.muted });
    }
    {
        const field = ui.div(c).wFull().h(48).row().itemsCenter().gap(10).px(14).rounded(16).bg(colors.tile).border(colors.hairline);
        defer field.end();
        ui.icon(c, "magnifyingglass", .{ .size = 15, .weight = .semibold, .color = colors.muted });
        if (a.focus_search) {
            c.focus = c.peekId(null);
            a.focus_search = false;
        }
        const r = ui.textField(c, &a.search, .{ .placeholder = "Add a flight, like JL 121", .width = .fill, .size = 17, .bare = true });
        // Typing: the sheet up, out of the keyboard's way.
        if (r.focused and a.detent != .full) a.detent = .full;
        if (r.submitted and a.followFlight(a.search.text())) {
            a.search.clear();
            c.focus = 0;
        }
        if (a.search.text().len > 0) {
            const x = ui.div(c).size(28, 28).center().control();
            ui.icon(c, "xmark.circle.fill", .{ .size = 16, .color = colors.faint });
            if (x.clicked()) a.search.clear();
            x.end();
        }
    }
    if (a.search_error.len > 0) ui.text(c, a.search_error, .{ .size = 13, .color = colors.amber, .wrap = true });
}

/// "3 flights · 1 in the air".
fn count(a: *App, c: *ui.Context, now: f64) []const u8 {
    const n = a.tracker.flights.items.len;
    if (n == 0) return "Follow any flight, live";
    var flying: usize = 0;
    for (a.tracker.flights.items) |*f| {
        if (f.phase(&a.d, now) == .airborne) flying += 1;
    }
    return c.print("{d} flight{s} · {d} in the air", .{ n, if (n == 1) "" else "s", flying });
}

pub fn body(a: *App, c: *ui.Context, now: f64) void {
    if (a.tracker.flights.items.len == 0) return empty(a, c);
    const list = ui.div(c).wFull().column().gap(10).px(16);
    defer list.end();
    for (a.tracker.flights.items, 0..) |*f, k| {
        ui.key(c, f.label.slice());
        flightCard(a, c, f, now, k);
    }
}

/// A flight's card in the list: "LH 450 · Today" and how it's doing, its
/// codes large with the way between, its cities and times under them.
fn flightCard(a: *App, c: *ui.Context, f: *Flight, now: f64, k: usize) void {
    const st = card.status(a, c, f, now);
    const from = f.origin(&a.d);
    const to = f.destination(&a.d);
    const m = ui.motion.frame(c, .{
        .initial = .{ .y = 14, .opacity = 0 },
        .press = .{ .scale = 0.97 },
        .delay = ui.motion.stagger(k, 0.04),
        .transition = style.settle,
    });
    const box = ui.div(c).wFull().column().gap(10).p(16).rounded(22).bg(colors.tile).border(colors.hairline).control().motion(m);
    defer box.end();
    if (box.clicked()) a.select(f.id);
    {
        const top = ui.div(c).wFull().row().itemsCenter().gap(8);
        defer top.end();
        style.badge(c, f.query.airline.slice(), 26);
        ui.text(c, f.label.slice(), .{ .size = 15, .weight = .semibold, .color = colors.text });
        const day = if (from) |p| style.time(c, now, p.tz, "EEE d MMM") else "";
        if (day.len > 0) ui.text(c, c.print("· {s}", .{day}), .{ .size = 13, .color = colors.muted });
        const spacer = ui.div(c).grow();
        spacer.end();
        const chip = ui.div(c).row().itemsCenter().gap(5).px(9).py(4).roundedFull().bg(st.color.alpha(0.16));
        defer chip.end();
        const dot = ui.div(c).size(6, 6).roundedFull().bg(st.color);
        dot.end();
        ui.text(c, st.short, .{ .size = 12, .weight = .semibold, .color = st.color });
    }
    if (from == null or to == null) {
        ui.text(c, if (f.no_route) "Route unknown" else "Looking up its route…", .{ .size = 15, .color = colors.muted });
        return;
    }
    {
        const mid = ui.div(c).wFull().row().itemsCenter().gap(12);
        defer mid.end();
        ui.text(c, from.?.code(), .{ .size = 32, .weight = .bold, .color = colors.text });
        card.progress(c, @floatCast(f.progress(&a.d)), f.phase(&a.d, now) == .airborne, 3);
        ui.text(c, to.?.code(), .{ .size = 32, .weight = .bold, .color = colors.text });
    }
    {
        const bottom = ui.div(c).wFull().row().itemsCenter();
        defer bottom.end();
        const left = ui.div(c).grow().column().gap(1);
        ui.text(c, from.?.city, .{ .size = 13, .color = colors.muted });
        ui.text(c, departed(c, f, from.?.tz), .{ .size = 15, .weight = .semibold, .color = colors.text });
        left.end();
        const right = ui.div(c).column().itemsEnd().gap(1);
        ui.text(c, to.?.city, .{ .size = 13, .color = colors.muted });
        ui.text(c, arrives(a, c, f, to.?.tz, now), .{ .size = 15, .weight = .semibold, .color = if (f.phase(&a.d, now) == .airborne) colors.green else colors.text });
        right.end();
    }
}

fn departed(c: *ui.Context, f: *const Flight, tz: []const u8) []const u8 {
    if (f.airborne_since == 0) return "—";
    return style.time(c, f.airborne_since, tz, if (f.takeoff_estimated) "~h:mm a" else "h:mm a");
}

fn arrives(a: *App, c: *ui.Context, f: *const Flight, tz: []const u8, now: f64) []const u8 {
    return switch (f.phase(&a.d, now)) {
        .airborne => style.time(c, now + (f.etaSeconds(&a.d) orelse 0), tz, "h:mm a"),
        .landed => style.time(c, f.heard_at, tz, "h:mm a"),
        else => "—",
    };
}

/// None followed yet: what the app does, and flights to try.
fn empty(a: *App, c: *ui.Context) void {
    const box = ui.div(c).wFull().column().itemsCenter().gap(10).px(24).pt(8);
    defer box.end();
    {
        const icon = ui.div(c).size(60, 60).roundedFull().glass(.{ .tint = colors.blue.alpha(0.25) }).center();
        defer icon.end();
        ui.icon(c, "airplane.departure", .{ .size = 24, .weight = .semibold, .color = colors.text });
    }
    ui.text(c, "Every flight, live", .{ .size = 22, .weight = .bold, .color = colors.text });
    ui.text(c, "Add a flight number to see it on the map: where it is now, when it lands, and the weather on the way.", .{ .size = 15, .color = colors.muted, .wrap = true });
    ui.text(c, "TRY ONE", .{ .size = 12, .weight = .semibold, .color = colors.faint });
    const chips = ui.div(c).wFull().row().justifyCenter().gap(8);
    defer chips.end();
    for (suggestions[0..3]) |s| {
        ui.key(c, s);
        const f = ui.motion.frame(c, .{ .press = .{ .scale = 0.92 }, .transition = style.settle });
        const chip = ui.div(c).px(12).py(8).roundedFull().bg(colors.tile).border(colors.hairline).control().motion(f);
        ui.text(c, s, .{ .size = 14, .weight = .semibold, .color = colors.text });
        if (chip.clicked()) _ = a.followFlight(s);
        chip.end();
    }
}

//! The sheet over the map's lower part: the flights followed and a field
//! to add one, or the one shown, as a card: where it is, when it took off
//! and should land (each by its airport's clock), how high and fast.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const data = @import("data.zig");
const flight = @import("flight.zig");
const tracker = @import("tracker.zig");
const clock = @import("clock.zig");
const App = @import("app.zig").App;

const Flight = flight.Flight;

pub const colors = struct {
    pub const sheet: ui.Color = .hex(0x15171c);
    pub const tile: ui.Color = .hex(0x1e2127);
    pub const text: ui.Color = .hex(0xf4f5f7);
    pub const muted: ui.Color = .hex(0x8b919c);
    pub const faint: ui.Color = .hex(0x5d636e);
    pub const chip: ui.Color = .hex(0xf5c518);
    pub const green: ui.Color = .hex(0x3ddc84);
    pub const amber: ui.Color = .hex(0xf5a524);
    pub const red: ui.Color = .hex(0xff5c5c);
    pub const blue: ui.Color = .hex(0x5aa2ff);
};

pub fn height(a: *App, size: ui.Size, safe: ui.Edges) f32 {
    const want: f32 = if (a.selected != null) 560 else 360;
    return @min(want + safe.bottom, size.h * if (a.selected != null) @as(f32, 0.56) else 0.48);
}

pub fn sheet(a: *App, c: *ui.Context, size: ui.Size, h: f32) void {
    const s = ui.div(c).absolute().offset(0, size.h - h).size(size.w, h + 40).bg(colors.sheet).rounded(28).column().pt(8).shadowMd();
    defer s.end();
    {
        const row = ui.div(c).wFull().row().center().pb(4);
        defer row.end();
        const grab = ui.div(c).size(38, 5).roundedFull().bg(colors.faint);
        grab.end();
    }
    const body = ui.div(c).wFull().grow().scrollY().column().px(20).pt(8).pb(c.safe_area.bottom + 56).gap(14);
    defer body.end();
    if (a.shown()) |f| card(a, c, f) else list(a, c);
}

// The list.

fn list(a: *App, c: *ui.Context) void {
    {
        const head = ui.div(c).column().gap(2);
        defer head.end();
        ui.text(c, "nanofly", .{ .size = 30, .weight = .bold, .color = colors.text });
        ui.text(c, "Every flight, live. Built in Zig with nanoui.", .{ .size = 14, .color = colors.muted });
    }
    const r = ui.textField(c, &a.search, .{ .placeholder = "Flight number, like JL 121", .width = .fill, .size = 16 });
    if (r.submitted and a.followFlight(a.search.text())) a.search.clear();
    if (a.search_error.len > 0) ui.text(c, a.search_error, .{ .size = 13, .color = colors.amber, .wrap = true });
    if (a.tracker.flights.items.len == 0) {
        ui.text(c, "Follow a flight to see it on the map: where it is, and when it lands.", .{ .size = 14, .color = colors.muted, .wrap = true });
        return;
    }
    const now = tracker.now();
    for (a.tracker.flights.items) |*f| {
        ui.key(c, f.label.slice());
        const row = ui.div(c).wFull().row().itemsCenter().gap(12).p(12).rounded(16).bg(colors.tile).control();
        badge(a, c, f, 40);
        {
            const col = ui.div(c).grow().column().gap(2);
            defer col.end();
            ui.text(c, f.label.slice(), .{ .size = 16, .weight = .semibold, .color = colors.text });
            ui.text(c, routeText(a, c, f), .{ .size = 13, .color = colors.muted });
        }
        const st = status(a, c, f, now);
        ui.text(c, st.short, .{ .size = 13, .weight = .semibold, .color = st.color });
        if (row.clicked()) a.select(f.id);
        row.end();
    }
}

fn routeText(a: *App, c: *ui.Context, f: *const Flight) []const u8 {
    const from = f.origin(&a.d) orelse return if (f.no_route) "Route unknown" else "Looking up…";
    const to = f.destination(&a.d).?;
    return c.print("{s} → {s}", .{ from.code(), to.code() });
}

/// A time on an airport's clock, kept for the frame.
fn time(c: *ui.Context, unix: f64, tz: []const u8, pattern: []const u8) []const u8 {
    var buf: [48]u8 = undefined;
    return c.alloc().dupe(u8, clock.format(&buf, unix, tz, pattern)) catch "";
}

fn ago(c: *ui.Context, seconds: f64) []const u8 {
    var buf: [24]u8 = undefined;
    return c.alloc().dupe(u8, flight.duration(&buf, seconds)) catch "";
}

// The card.

fn card(a: *App, c: *ui.Context, f: *Flight) void {
    const now = tracker.now();
    const from = f.origin(&a.d);
    const to = f.destination(&a.d);
    {
        const head = ui.div(c).wFull().row().itemsCenter().gap(12);
        defer head.end();
        badge(a, c, f, 46);
        {
            const col = ui.div(c).grow().column().gap(2);
            defer col.end();
            const day = time(c, now, if (from) |p| p.tz else "", "EEE, d MMM");
            ui.text(c, c.print("{s} · {s}", .{ f.label.slice(), std.ascii.upperString(@constCast(day), day) }), .{ .size = 13, .weight = .semibold, .color = colors.muted });
            const title = if (from != null and to != null) c.print("{s} to {s}", .{ from.?.city, to.?.city }) else f.label.slice();
            ui.text(c, title, .{ .size = 22, .weight = .bold, .color = colors.text });
        }
        if (round(c, "xmark")) a.select(null);
    }
    banner(a, c, f, now);
    if (from) |p| airportBlock(c, f, p, .departure, now, a);
    if (from != null and to != null) journey(a, c, f);
    if (to) |p| airportBlock(c, f, p, .arrival, now, a);
    if (f.live) |*l| stats(c, l);
    {
        const foot = ui.div(c).wFull().row().justifyBetween().itemsCenter().pt(4);
        defer foot.end();
        ui.text(c, "Positions: adsb.lol (ODbL), OpenSky Network", .{ .size = 11, .color = colors.faint });
        const rm = ui.div(c).px(10).py(6).rounded(10).bg(colors.tile).control();
        ui.text(c, "Unfollow", .{ .size = 12, .weight = .semibold, .color = colors.red });
        if (rm.clicked()) a.unfollow(f.id);
        rm.end();
    }
}

const Status = struct { title: []const u8, detail: []const u8 = "", short: []const u8, color: ui.Color };

fn status(a: *App, c: *ui.Context, f: *const Flight, now: f64) Status {
    return switch (f.phase(&a.d, now)) {
        .finding => .{ .title = "Looking it up…", .short = "…", .color = colors.muted },
        .unknown => .{ .title = "No route found for this number", .detail = "Check it, or try the operating airline's code.", .short = "Unknown", .color = colors.amber },
        .waiting => .{ .title = "Not in the air yet", .detail = "It shows here as soon as it takes off.", .short = "Not flying", .color = colors.muted },
        .taxiing => .{ .title = "On the ground", .detail = "Taxiing, or at the gate.", .short = "On ground", .color = colors.amber },
        .airborne => blk: {
            const eta = f.etaSeconds(&a.d) orelse 0;
            const left = ago(c, eta);
            const l = f.live.?;
            var tb: [24]u8 = undefined;
            break :blk .{
                .title = c.print("In the air · lands in {s}", .{left}),
                .detail = c.print("{s} ft · {d:.0} kt · heard {d:.0}s ago", .{ thousands(&tb, l.alt_ft), l.gs_kt, @max(0, now - f.heard_at + l.age_s) }),
                .short = c.print("{s} left", .{left}),
                .color = colors.green,
            };
        },
        .landed => .{ .title = "Landed", .short = "Landed", .color = colors.blue },
        .lost => .{
            .title = "Out of range",
            .detail = c.print("Last heard {s} ago: over the sea, or out of the receivers' reach.", .{ago(c, now - f.heard_at)}),
            .short = "No signal",
            .color = colors.amber,
        },
    };
}

fn banner(a: *App, c: *ui.Context, f: *const Flight, now: f64) void {
    const st = status(a, c, f, now);
    const b = ui.div(c).wFull().column().gap(3).p(14).rounded(16).bg(st.color.alpha(0.12));
    defer b.end();
    ui.text(c, st.title, .{ .size = 17, .weight = .semibold, .color = st.color });
    if (st.detail.len > 0) ui.text(c, st.detail, .{ .size = 13, .color = st.color.alpha(0.8), .wrap = true });
}

const End = enum { departure, arrival };

fn airportBlock(c: *ui.Context, f: *const Flight, p: *const data.Airport, end: End, now: f64, a: *App) void {
    const box = ui.div(c).wFull().row().itemsCenter().gap(12);
    defer box.end();
    {
        const col = ui.div(c).grow().column().gap(4);
        defer col.end();
        var nb: [80]u8 = undefined;
        const name = data.shortName(&nb, p.name);
        ui.text(c, c.print("{s} {s} · {s}", .{ if (end == .departure) "↗" else "↘", p.code(), name }), .{ .size = 15, .weight = .semibold, .color = colors.text });
        const phase = f.phase(&a.d, now);
        var at: []const u8 = "—";
        var sub: []const u8 = "";
        var color = colors.text;
        switch (end) {
            .departure => if (f.airborne_since > 0) {
                at = time(c, f.airborne_since, p.tz, if (f.takeoff_estimated) "~h:mm a" else "h:mm a");
                sub = c.print("Took off {s}{s} ago{s}", .{ if (f.takeoff_estimated) "about " else "", ago(c, now - f.airborne_since), if (f.takeoff_estimated) " · estimated" else "" });
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
                sub = c.print("Arrives in {s} · estimated", .{ago(c, eta)});
                color = colors.green;
            } else {
                sub = "When it's in the air";
            },
        }
        ui.text(c, at, .{ .size = 38, .weight = .bold, .color = color });
        ui.text(c, sub, .{ .size = 14, .color = colors.muted });
    }
    {
        const col = ui.div(c).column().itemsEnd().gap(6);
        defer col.end();
        const chip = ui.div(c).px(12).py(6).rounded(10).bg(colors.chip);
        ui.text(c, p.code(), .{ .size = 20, .weight = .bold, .color = .hex(0x111111) });
        chip.end();
        ui.text(c, c.print("now {s}", .{time(c, now, p.tz, "h:mm a")}), .{ .size = 12, .color = colors.muted });
    }
}

/// The line between the airports: how long and far, and how much is flown.
fn journey(a: *App, c: *ui.Context, f: *const Flight) void {
    const row = ui.div(c).wFull().column().gap(8).py(2);
    defer row.end();
    const km = f.routeKm(&a.d) orelse 0;
    ui.text(c, c.print("◷ about {s} · {d:.0} mi · {d:.0} km", .{ ago(c, f.blockSeconds(&a.d) orelse 0), km / 1.609344, km }), .{ .size = 13, .color = colors.muted });
    // Flown, then left: as ui.progress, in the card's colors.
    const done: f32 = @floatCast(f.progress(&a.d));
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 4 }, .radius = 2, .background = colors.tile }, null);
    _ = c.leaf(.{ .grow = done, .radius = 2, .height = .fill, .background = colors.green }, .none, null);
    _ = c.leaf(.{ .grow = 1 - done }, .none, null);
    c.end();
}

fn stats(c: *ui.Context, l: *const @import("sources.zig").Live) void {
    var tb: [24]u8 = undefined;
    const grid = ui.div(c).wFull().column().gap(10);
    defer grid.end();
    const rows = [2][2][2][]const u8{
        .{ .{ "Altitude", c.print("{s} ft", .{thousands(&tb, l.alt_ft)}) }, .{ "Speed", c.print("{d:.0} kt", .{l.gs_kt}) } },
        .{ .{ "Aircraft", if (l.type.len > 0) c.print("{s}", .{l.type.slice()}) else "—" }, .{ "Registration", c.print("{s}", .{if (l.reg.len > 0) l.reg.slice() else l.hex.slice()}) } },
    };
    for (rows) |pair| {
        const row = ui.div(c).wFull().row().gap(10);
        defer row.end();
        for (pair) |cell| {
            const t = ui.div(c).w((c.size.w - 50) / 2).column().gap(4).p(12).rounded(14).bg(colors.tile);
            defer t.end();
            ui.text(c, cell[0], .{ .size = 12, .color = colors.muted });
            ui.text(c, cell[1], .{ .size = 17, .weight = .semibold, .color = colors.text });
        }
    }
}

/// The airline's code in a circle of its own color.
fn badge(a: *App, c: *ui.Context, f: *const Flight, d: f32) void {
    const code = f.query.airline.slice();
    var h: u32 = 2166136261;
    for (code) |ch| h = (h ^ ch) *% 16777619;
    const palette = [_]u24{ 0xd7263d, 0x1b998b, 0x2e86de, 0xf46036, 0x8e44ad, 0x16a085, 0xc0392b, 0x2c3e50 };
    const b = ui.div(c).size(d, d).roundedFull().bg(.hex(palette[h % palette.len])).center();
    defer b.end();
    _ = a;
    ui.text(c, code, .{ .size = d * 0.36, .weight = .bold, .color = .hex(0xffffff) });
}

fn round(c: *ui.Context, symbol: []const u8) bool {
    const b = ui.div(c).size(40, 40).roundedFull().bg(colors.tile).center().control();
    defer b.end();
    ui.icon(c, symbol, .{ .size = 15, .weight = .semibold, .color = colors.text });
    return b.clicked();
}

/// 34000 as "34,000".
fn thousands(buf: []u8, v: f64) []const u8 {
    const n: u64 = @intFromFloat(@max(0, @round(v)));
    var tmp: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return "";
    var out: usize = 0;
    for (digits, 0..) |ch, k| {
        if (k > 0 and (digits.len - k) % 3 == 0) {
            buf[out] = ',';
            out += 1;
        }
        buf[out] = ch;
        out += 1;
    }
    return buf[0..out];
}

test "thousands" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("34,000", thousands(&buf, 34000));
    try std.testing.expectEqualStrings("950", thousands(&buf, 950));
    try std.testing.expectEqualStrings("1,234,567", thousands(&buf, 1234567));
}

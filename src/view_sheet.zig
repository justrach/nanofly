//! The sheet over the map's lower part, of glass: held by its head and
//! dragged (or flung) to rest at one of three heights, its head alone,
//! half the screen or all of it; its content (the list, or a flight's
//! card) coming in as it changes; and the bar of glass buttons along the
//! bottom.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const style = @import("style.zig");
const app = @import("app.zig");
const list = @import("view_list.zig");
const card = @import("view_card.zig");

const App = app.App;
const Detent = app.Detent;
const colors = style.colors;

/// The bar of buttons along the bottom, and the space kept for it.
const bar_h: f32 = 48;
/// The sheet floats this far in from the screen's sides and bottom.
const inset: f32 = 8;

/// Where the sheet's top rests at each height (peek, half, full).
pub fn tops(a: *App, c: *ui.Context, size: ui.Size) [3]f32 {
    const safe = c.safe_area;
    const full = safe.top + 10;
    const half = @round(size.h * if (a.selected != null) @as(f32, 0.44) else 0.5);
    const head_h: f32 = if (a.selected != null) 150 else 140;
    const peek = size.h - @max(safe.bottom, 16) - bar_h - head_h;
    return .{ @max(peek, half + 60), half, full };
}

/// The sheet's top this frame: following a finger, or springing to rest.
pub fn top(a: *App, c: *ui.Context, size: ui.Size) f32 {
    const t = tops(a, c, size);
    const y = c.input.mouse.y;
    const goal: f32 = if (a.grab) |g|
        std.math.clamp(g.top + ((if (y > -1e5) y else g.last) - g.finger), t[2] - 24, t[0] + 50)
    else
        t[@intFromEnum(a.detent)];
    return ui.motion.number(c, "sheet-top", goal, if (a.grab != null) .instant else style.settle);
}

/// The height a sheet let go at `at` comes to rest at: the nearest, or,
/// thrown, the next one the way it was going.
pub fn snap(t: [3]f32, at: f32, velocity: f32) Detent {
    if (velocity > 700) {
        // Down: the first height below.
        for ([_]Detent{ .full, .half, .peek }) |d| if (t[@intFromEnum(d)] > at + 1) return d;
        return .peek;
    }
    if (velocity < -700) {
        for ([_]Detent{ .peek, .half, .full }) |d| if (t[@intFromEnum(d)] < at - 1) return d;
        return .full;
    }
    var best: Detent = .half;
    var best_d: f32 = std.math.inf(f32);
    for ([_]Detent{ .peek, .half, .full }) |d| {
        const dist = @abs(t[@intFromEnum(d)] - at);
        if (dist < best_d) {
            best_d = dist;
            best = d;
        }
    }
    return best;
}

/// Following the finger that holds the sheet's head; let go, it rests.
fn hold(a: *App, c: *ui.Context, it: ui.Interaction, now_top: f32, size: ui.Size) void {
    const y = c.input.mouse.y;
    if (it.pressed and y > -1e5) {
        if (a.grab) |*g| {
            const dt: f32 = @floatCast(c.time - g.last_time);
            if (dt > 0 and y != g.last) {
                g.velocity = 0.7 * ((y - g.last) / dt) + 0.3 * g.velocity;
                g.last = y;
                g.last_time = c.time;
            }
        } else a.grab = .{ .finger = y, .top = now_top, .last = y, .last_time = c.time };
    } else if (a.grab) |g| {
        const held_still = c.time - g.last_time > 0.1;
        a.detent = snap(tops(a, c, size), g.top + (g.last - g.finger), if (held_still) 0 else g.velocity);
        // A tap on the head: no drag, up a height.
        if (@abs(g.last - g.finger) < 4 and it.clicked) a.detent = switch (a.detent) {
            .peek => .half,
            .half => .full,
            .full => .half,
        };
        a.grab = null;
        c.animationFrame();
    }
}

pub fn sheet(a: *App, c: *ui.Context, size: ui.Size, at: f32, now: f64) void {
    const f = a.shown();
    const s = ui.div(c).absolute().offset(inset, at).size(size.w - 2 * inset, @max(0, size.h - at - inset)).column().rounded(36).glass(.{ .tint = colors.sheet.alpha(0.55) }).clip();
    {
        defer s.end();
        {
            const head = ui.div(c).wFull().column().gap(10).pt(8).pb(12);
            defer head.end();
            hold(a, c, head.interaction(), at, size);
            {
                const row = ui.div(c).wFull().row().justifyCenter();
                defer row.end();
                const grab = ui.div(c).size(38, 5).roundedFull().bg(colors.faint.alpha(0.8));
                grab.end();
            }
            if (f) |fl| card.head(a, c, fl, now) else list.head(a, c, now);
        }
        const body = ui.div(c).wFull().grow().scrollY().column().pb(bar_h + @max(c.safe_area.bottom, 16) + 24);
        defer body.end();
        // What's shown comes in from a little below as it changes.
        ui.key(c, if (f) |fl| c.print("card:{d}", .{fl.id}) else "list");
        const m = ui.motion.frame(c, .{ .initial = .{ .y = 18, .opacity = 0 }, .transition = style.settle });
        const content = ui.div(c).wFull().column().gap(14).motion(m);
        defer content.end();
        if (f) |fl| card.body(a, c, fl, now) else list.body(a, c, now);
    }
    fade(c, size, at);
    toolbar(a, c, size, now);
}

/// The sheet's foot darkening under the bar, so what scrolls under it
/// fades out rather than showing through its glass.
fn fade(c: *ui.Context, size: ui.Size, at: f32) void {
    const h: f32 = bar_h + @max(c.safe_area.bottom, 16) + 34;
    const y0 = @max(at, size.h - inset - h);
    const steps = 12;
    const col = ui.div(c).absolute().offset(inset, y0).size(size.w - 2 * inset, size.h - inset - y0).column().rounded(36).clip();
    defer col.end();
    for (0..steps) |k| {
        const t = @as(f32, @floatFromInt(k + 1)) / steps;
        const strip = ui.div(c).wFull().grow().bg(colors.sheet.alpha(0.92 * t * t));
        strip.end();
    }
}

/// The bar along the bottom: with a flight shown, share it or stop
/// following it, and back to all of them; with the list, ask again and
/// add one.
fn toolbar(a: *App, c: *ui.Context, size: ui.Size, now: f64) void {
    const y = size.h - @max(c.safe_area.bottom, 16) - bar_h - 2;
    const bar = ui.div(c).absolute().offset(20, y).w(size.w - 40).h(bar_h).row().itemsCenter();
    defer bar.end();
    {
        const caps = ui.div(c).h(bar_h).row().itemsCenter().px(4).roundedFull().glass(.{ .tint = colors.sheet.alpha(0.35) });
        defer caps.end();
        if (a.shown()) |f| {
            if (style.barButton(c, "square.and.arrow.up", colors.text, false)) {
                c.clipboard.write(c.clipboard.ctx, card.summary(a, c, f, now));
                a.say("Copied to share", now);
            }
            if (style.barButton(c, "trash", colors.text, false)) {
                a.unfollow(f.id);
                a.say("Stopped following", now);
            }
        } else {
            if (style.barButton(c, "arrow.clockwise", colors.text, false)) {
                a.tracker.poll();
                a.say("Updating", now);
            }
            if (style.barButton(c, if (a.detent == .full) "chevron.down" else "chevron.up", colors.text, false))
                a.detent = if (a.detent == .full) .half else .full;
        }
    }
    const spacer = ui.div(c).grow();
    spacer.end();
    if (a.shown() != null) {
        const n = a.tracker.flights.items.len;
        if (n > 1 and style.pill(c, "list.bullet", c.print("{d} Flights", .{n}), colors.sheet.alpha(0.3))) a.select(null);
    } else if (style.pill(c, "plus", "Add Flight", colors.blue.alpha(0.75))) {
        a.detent = .full;
        a.focus_search = true;
    }
}

test "a sheet let go comes to the nearest height, or thrown, the next" {
    const t: [3]f32 = .{ 700, 450, 60 };
    try std.testing.expectEqual(Detent.half, snap(t, 480, 0));
    try std.testing.expectEqual(Detent.full, snap(t, 200, 0));
    // Thrown down from near the top: half, not all the way.
    try std.testing.expectEqual(Detent.half, snap(t, 100, 1500));
    // Thrown up from half: to the top.
    try std.testing.expectEqual(Detent.full, snap(t, 440, -1500));
    try std.testing.expectEqual(Detent.peek, snap(t, 690, 2000));
}

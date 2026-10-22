//! What the screens share: the colors over the glass, the airline's badge,
//! glass buttons that give a little under a finger, and words for times,
//! durations and numbers (each kept in the frame's memory: texts keep a
//! pointer to what they show).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const flight = @import("flight.zig");
const clock = @import("clock.zig");

pub const colors = struct {
    /// What the sheet's glass is tinted toward.
    pub const sheet: ui.Color = .hex(0x101318);
    pub const text: ui.Color = .hex(0xf4f5f7);
    pub const muted: ui.Color = .hex(0x9aa0ab);
    pub const faint: ui.Color = .hex(0x646a75);
    pub const tile: ui.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.06 };
    pub const hairline: ui.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.08 };
    pub const chip: ui.Color = .hex(0xf5c518);
    pub const green: ui.Color = .hex(0x34d17a);
    pub const amber: ui.Color = .hex(0xf5a524);
    pub const red: ui.Color = .hex(0xff5c5c);
    pub const blue: ui.Color = .hex(0x4c9bff);
};

/// A spring for things that move into place: quick, settled, no wobble.
pub const settle: ui.motion.Transition = .{ .spring = .{ .stiffness = 320, .damping = 34 } };

/// A time on an airport's clock, kept for the frame.
pub fn time(c: *ui.Context, unix: f64, tz: []const u8, pattern: []const u8) []const u8 {
    var buf: [48]u8 = undefined;
    return c.alloc().dupe(u8, clock.format(&buf, unix, tz, pattern)) catch "";
}

/// "1h 20m", kept for the frame.
pub fn ago(c: *ui.Context, seconds: f64) []const u8 {
    var buf: [24]u8 = undefined;
    return c.alloc().dupe(u8, flight.duration(&buf, seconds)) catch "";
}

/// 34000 as "34,000".
pub fn thousands(buf: []u8, v: f64) []const u8 {
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

/// "34,000", kept for the frame.
pub fn grouped(c: *ui.Context, v: f64) []const u8 {
    var buf: [24]u8 = undefined;
    return c.alloc().dupe(u8, thousands(&buf, v)) catch "";
}

/// The airline's code in a circle of its own color.
pub fn badge(c: *ui.Context, code: []const u8, d: f32) void {
    var h: u32 = 2166136261;
    for (code) |ch| h = (h ^ ch) *% 16777619;
    const palette = [_]u24{ 0xd7263d, 0x1b998b, 0x2e86de, 0xf46036, 0x8e44ad, 0x16a085, 0xc0392b, 0x34495e };
    const b = ui.div(c).size(d, d).roundedFull().bg(.hex(palette[h % palette.len])).center();
    defer b.end();
    ui.text(c, code, .{ .size = d * 0.36, .weight = .bold, .color = .hex(0xffffff) });
}

/// A round glass button with a symbol; `on` tints it.
pub fn glassButton(c: *ui.Context, symbol: []const u8, d: f32, on: bool) bool {
    const f = ui.motion.frame(c, .{ .press = .{ .scale = 0.9 }, .transition = settle });
    const b = ui.div(c).size(d, d).roundedFull().glass(.{ .tint = if (on) colors.blue.alpha(0.35) else .transparent }).center().control().motion(f);
    defer b.end();
    ui.icon(c, symbol, .{ .size = d * 0.36, .weight = .semibold, .color = colors.text });
    return b.clicked();
}

/// A button in a glass bar: just its symbol, the bar is the glass.
pub fn barButton(c: *ui.Context, symbol: []const u8, color: ui.Color, on: bool) bool {
    const f = ui.motion.frame(c, .{ .press = .{ .scale = 0.86 }, .transition = settle });
    const b = ui.div(c).size(48, 46).center().control().motion(f);
    defer b.end();
    ui.icon(c, symbol, .{ .size = 17, .weight = .semibold, .color = if (on) colors.blue else color });
    return b.clicked();
}

/// A pill of glass with a symbol and a word, tinted: the bar's main action.
pub fn pill(c: *ui.Context, symbol: []const u8, word: []const u8, tint: ui.Color) bool {
    const f = ui.motion.frame(c, .{ .press = .{ .scale = 0.94 }, .transition = settle });
    const b = ui.div(c).h(48).px(20).row().itemsCenter().gap(8).roundedFull().glass(.{ .tint = tint }).control().motion(f);
    defer b.end();
    ui.icon(c, symbol, .{ .size = 16, .weight = .bold, .color = .hex(0xffffff) });
    ui.text(c, word, .{ .size = 16, .weight = .semibold, .color = .hex(0xffffff) });
    return b.clicked();
}

/// A section's title over the sheet.
pub fn section(c: *ui.Context, title: []const u8) void {
    const row = ui.div(c).wFull().px(20).pt(10);
    defer row.end();
    ui.text(c, title, .{ .size = 20, .weight = .bold, .color = colors.text });
}

test "thousands" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("34,000", thousands(&buf, 34000));
    try std.testing.expectEqualStrings("950", thousands(&buf, 950));
    try std.testing.expectEqualStrings("1,234,567", thousands(&buf, 1234567));
}

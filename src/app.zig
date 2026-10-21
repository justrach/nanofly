//! nanofly's state: the data it carries, the flights it follows (kept in
//! a file between launches), the one shown, the map's camera, and the
//! clock that asks after them again every 15 seconds.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const data = @import("data.zig");
const land_mod = @import("land.zig");
const flight = @import("flight.zig");
const map = @import("map.zig");
const tracker_mod = @import("tracker.zig");

pub const poll_seconds = 15;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Where the flights followed are kept ("" for nowhere: tests).
    store_path: []const u8 = "",
    window: ?*nanoui.Window = null,
    d: data.Data,
    coarse: land_mod.Land,
    fine: land_mod.Land,
    tracker: tracker_mod.Tracker,
    /// The flight shown (its id); the list when null.
    selected: ?u32 = null,
    search: ui.TextBuffer = .{},
    search_error: []const u8 = "",
    cam: map.Camera = .{},
    /// The camera follows what is shown until the map is moved by hand.
    follow: bool = true,
    drag: ?ui.Point = null,
    ticking: bool = false,

    pub fn init(a: *App, gpa: std.mem.Allocator, io: std.Io) !void {
        a.* = .{
            .gpa = gpa,
            .io = io,
            .d = try data.Data.load(gpa),
            .coarse = try land_mod.Land.parse(gpa, @embedFile("land110.mesh")),
            .fine = try land_mod.Land.parse(gpa, @embedFile("land50.mesh")),
            .tracker = undefined,
        };
        a.tracker = .{ .gpa = gpa, .d = &a.d, .redraw_ctx = a, .redraw_fn = redrawC };
    }

    pub fn deinit(a: *App) void {
        a.tracker.deinit();
        a.d.deinit(a.gpa);
        a.coarse.deinit(a.gpa);
        a.fine.deinit(a.gpa);
    }

    fn redrawC(ctx: ?*anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx.?));
        if (a.window) |w| w.redraw();
    }

    pub fn shown(a: *App) ?*flight.Flight {
        return a.tracker.find(a.selected orelse return null);
    }

    /// Follows the flight typed in `s` and shows it; false (and why, in
    /// `search_error`) if it isn't a flight number.
    pub fn followFlight(a: *App, s: []const u8) bool {
        const q = flight.Query.parse(s) orelse {
            a.search_error = "That isn't a flight number: try JL 121 or BA 117.";
            return false;
        };
        a.search_error = "";
        const id = a.tracker.add(q) catch return false;
        a.select(id);
        a.save();
        return true;
    }

    pub fn select(a: *App, id: ?u32) void {
        a.selected = id;
        a.follow = true;
    }

    pub fn unfollow(a: *App, id: u32) void {
        a.tracker.remove(id);
        if (a.selected == id) a.select(null);
        a.save();
    }

    // The flights followed, one per line, in the app's own folder.

    pub fn load(a: *App) void {
        if (a.store_path.len == 0) return;
        const text = std.Io.Dir.cwd().readFileAlloc(a.io, a.store_path, a.gpa, .limited(64 << 10)) catch return;
        defer a.gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| if (flight.Query.parse(line)) |q| {
            _ = a.tracker.add(q) catch {};
        };
    }

    pub fn save(a: *App) void {
        if (a.store_path.len == 0) return;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a.gpa);
        for (a.tracker.flights.items) |f| {
            buf.appendSlice(a.gpa, f.label.slice()) catch return;
            buf.append(a.gpa, '\n') catch return;
        }
        if (std.fs.path.dirname(a.store_path)) |dir| std.Io.Dir.cwd().createDirPath(a.io, dir) catch {};
        std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = a.store_path, .data = buf.items }) catch {};
    }

    /// Asks after every flight now, and again every `poll_seconds`.
    pub fn startClock(a: *App) void {
        a.tracker.poll();
        if (a.ticking) return;
        a.ticking = true;
        nanoui.objc.dispatchAfter(poll_seconds * std.time.ns_per_s, a, tick);
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const a: *App = @ptrCast(@alignCast(ctx.?));
        a.tracker.poll();
        // "Took off 29m ago" moves on.
        redrawC(a);
        nanoui.objc.dispatchAfter(poll_seconds * std.time.ns_per_s, a, tick);
    }
};

/// Where the flights followed are kept: the app's Application Support.
pub fn storePath(arena: std.mem.Allocator, home: []const u8) []const u8 {
    if (home.len == 0) return "";
    return std.fmt.allocPrint(arena, "{s}/Library/Application Support/nanofly/flights.txt", .{home}) catch "";
}

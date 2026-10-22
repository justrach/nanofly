//! nanofly: flights, live, on a map. nanoui's first iOS app, in Zig.
//!
//!   nanofly [--flight=JL121]...   (one flight is shown; more are listed)
//!
//! OPENSKY_CLIENT_ID and OPENSKY_CLIENT_SECRET, when set, are an OpenSky
//! Network API client's (more requests a day). NANOFLY_API (or the build's
//! -Dapi) is a backend to ask instead of each source (backend/).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const storePath = @import("app.zig").storePath;
const view = @import("view.zig");
const sources = @import("sources.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try nanoui.App.create(init, .{ .name = "nanofly" });
    defer app.destroy();

    const state = try gpa.create(App);
    defer gpa.destroy(state);
    try state.init(gpa, init.io);
    defer state.deinit();
    const env = init.environ_map;
    state.tracker.opensky.id = env.get("OPENSKY_CLIENT_ID") orelse "";
    state.tracker.opensky.secret = env.get("OPENSKY_CLIENT_SECRET") orelse "";
    sources.api = std.mem.trimEnd(u8, env.get("NANOFLY_API") orelse @import("build_options").api, "/");

    // Flights asked for on the command line (a demo) are followed, not
    // kept: one is shown, more are listed.
    var asked: usize = 0;
    var last: u32 = 0;
    for (try init.minimal.args.toSlice(init.arena.allocator())) |arg| {
        if (!std.mem.startsWith(u8, arg, "--flight=")) continue;
        const q = @import("flight.zig").Query.parse(arg["--flight=".len..]) orelse continue;
        last = try state.tracker.add(q);
        asked += 1;
    }
    if (asked == 1) state.select(last);
    if (asked == 0) {
        state.store_path = storePath(init.arena.allocator(), env.get("HOME") orelse "");
        state.load();
    }

    state.window = try app.newWindow(.{
        .title = "nanofly",
        .width = 430,
        .height = 900,
        .min_width = 360,
        .min_height = 600,
        .theme = theme(),
        .full_bleed = true,
        .content = .{ .view = .init(state, view.view) },
    });
    state.startClock();
    try app.run();
}

fn theme() ui.Theme {
    var t = ui.Theme.dark_theme;
    t.background = .hex(0x0b0d11);
    t.surface = .hex(0x1e2127);
    t.accent = .hex(0x3d8bff);
    return t;
}

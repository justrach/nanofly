//! The screen, drawn offscreen with a flight in the air (no requests made):
//! the card says where it is going and when, the list shows it, and the
//! map draws the land, its route and the plane.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const geo = @import("geo.zig");
const App = @import("app.zig").App;
const view = @import("view.zig");
const tracker = @import("tracker.zig");

fn flying(a: *App) !u32 {
    a.tracker.offline = true;
    const id = try a.tracker.add(@import("flight.zig").Query.parse("JL121").?);
    const f = a.tracker.find(id).?;
    try std.testing.expect(f.setRoute(&a.d, "RJTT-RJOO"));
    f.callsign.set("JAL121");
    const mid = geo.along(f.origin(&a.d).?.pos, f.destination(&a.d).?.pos, 0.45);
    f.live = .{ .pos = mid, .alt_ft = 34000, .gs_kt = 452, .track = 255, .source = .adsb_lol };
    f.live.?.type.set("B772");
    f.live.?.reg.set("JA8980");
    const now = tracker.now();
    f.heard_at = now;
    f.airborne_since = now - 25 * 60;
    return id;
}

test "a flight in the air: its card, the list, the map" {
    const gpa = std.testing.allocator;
    const a = try gpa.create(App);
    defer gpa.destroy(a);
    try a.init(gpa, std.testing.io);
    defer a.deinit();
    const id = try flying(a);
    a.select(id);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(a, view.view), .{ .width = 430, .height = 900, .theme = ui.Theme.dark_theme });
    defer t.deinit();
    t.settle(0.5);
    try t.screenshot("/tmp/nanofly-card.png");
    try std.testing.expect(t.hasText("Tokyo to Osaka"));
    try std.testing.expect(t.hasText("34,000 ft"));
    try std.testing.expect(t.hasText("B772"));
    try std.testing.expect(t.containsText("In the air · lands in"));
    try std.testing.expect(t.containsText("Arrives in"));
    // The airports named on the map.
    try std.testing.expect(t.hasText("HND"));
    try std.testing.expect(t.hasText("ITM"));
    try t.screenshot("/tmp/nanofly-card.png");

    // Closed: the list, the flight in it.
    // The close button, at the header's right.
    const title = t.findText("Tokyo to Osaka").?;
    t.click(390, title.y);
    t.settle(0.5);
    try std.testing.expect(t.hasText("nanofly"));
    try std.testing.expect(t.hasText("JL 121"));
    try std.testing.expect(t.hasText("HND → ITM"));
    try t.screenshot("/tmp/nanofly-list.png");
}

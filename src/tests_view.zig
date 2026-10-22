//! The screen, drawn offscreen with a flight in the air (no requests made):
//! the card says where it is going and when, the list shows it, the map
//! draws the land, its route and the plane; the sheet is dragged between
//! its heights, and the map pinched and tapped.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const geo = @import("geo.zig");
const App = @import("app.zig").App;
const view = @import("view.zig");
const sheet = @import("view_sheet.zig");
const tracker = @import("tracker.zig");

fn flying(a: *App) !u32 {
    a.goOffline();
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

fn open(gpa: std.mem.Allocator) !*App {
    const a = try gpa.create(App);
    errdefer gpa.destroy(a);
    try a.init(gpa, std.testing.io);
    return a;
}

test "a flight in the air: its card, the list, the map" {
    const gpa = std.testing.allocator;
    const a = try open(gpa);
    defer gpa.destroy(a);
    defer a.deinit();
    const id = try flying(a);
    a.select(id);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(a, view.view), .{ .width = 430, .height = 900, .theme = ui.Theme.dark_theme });
    defer t.deinit();
    t.settle(2);
    try t.screenshot("/tmp/nanofly-card.png");
    try std.testing.expect(t.hasText("Tokyo to Osaka"));
    try std.testing.expect(t.containsText("In the air · lands in"));
    try std.testing.expect(t.containsText("Arrives in"));
    // Its speed and height in the glass at the top.
    try std.testing.expect(t.hasText("34,000"));
    try std.testing.expect(t.hasText("MPH"));
    // The airports named on the map.
    try std.testing.expect(t.hasText("HND"));
    try std.testing.expect(t.hasText("ITM"));
    // The sheet up: what flies it.
    a.detent = .full;
    t.settle(2);
    try std.testing.expect(t.hasText("B772"));
    try std.testing.expect(t.hasText("JA8980"));
    try t.screenshot("/tmp/nanofly-card-full.png");

    // Closed: the list, the flight in it.
    a.detent = .half;
    t.settle(2);
    const title = t.findText("Tokyo to Osaka").?;
    t.click(392, title.y + title.h / 2);
    t.settle(2);
    try std.testing.expect(a.selected == null);
    try std.testing.expect(t.hasText("My Flights"));
    try std.testing.expect(t.hasText("JL 121"));
    try std.testing.expect(t.hasText("HND"));
    try std.testing.expect(t.hasText("1 flight · 1 in the air"));
    try t.screenshot("/tmp/nanofly-list.png");

    // A tap on its card shows it again.
    const row = t.findText("JL 121").?;
    t.click(row.x, row.y + row.h / 2);
    t.settle(2);
    try std.testing.expectEqual(@as(?u32, id), a.selected);
}

test "the sheet follows a finger and rests at a height; the map pinches" {
    const gpa = std.testing.allocator;
    const a = try open(gpa);
    defer gpa.destroy(a);
    defer a.deinit();
    _ = try flying(a);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(a, view.view), .{ .width = 430, .height = 900, .theme = ui.Theme.dark_theme });
    defer t.deinit();
    t.settle(2);
    try std.testing.expectEqual(@import("app.zig").Detent.half, a.detent);
    // Held by its head (beside "My Flights") and pulled up most of the way.
    const head = t.findText("My Flights").?;
    const x: f32 = 330;
    var y = head.y + head.h / 2;
    t.moveTo(x, y);
    t.ctx.pointerDown();
    t.frame();
    for (0..20) |_| {
        y -= 15;
        t.ctx.input.mouse = .{ .x = x, .y = y };
        t.frame();
    }
    // Held still, then let go: no throw.
    t.advance(0.2);
    t.ctx.pointerUp();
    t.frame();
    t.settle(2);
    try std.testing.expectEqual(@import("app.zig").Detent.full, a.detent);
    try std.testing.expect(t.findText("My Flights").?.y < 120);

    // Pinched open over the map: closer, and no longer following.
    a.detent = .peek;
    t.settle(2);
    const fitted = a.cam.scale;
    a.follow = false;
    t.frame();
    const before = a.cam.scale;
    t.pinch(215, 300, 2, 0, 0);
    try std.testing.expectApproxEqRel(before * 2, a.cam.scale, 1e-6);
    // Back onto the flights with the location button.
    a.follow = true;
    t.settle(3);
    try std.testing.expectApproxEqRel(fitted, a.cam.scale, 0.01);
    try t.screenshot("/tmp/nanofly-peek.png");
}

test "with no flights: flights to try" {
    const gpa = std.testing.allocator;
    const a = try open(gpa);
    defer gpa.destroy(a);
    defer a.deinit();
    a.goOffline();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(a, view.view), .{ .width = 430, .height = 900, .theme = ui.Theme.dark_theme });
    defer t.deinit();
    t.settle(2);
    try std.testing.expect(t.hasText("Every flight, live"));
    try t.screenshot("/tmp/nanofly-empty.png");
    try t.clickText("QF 1");
    t.settle(2);
    try std.testing.expect(a.selected != null);
    try std.testing.expectEqual(@as(usize, 1), a.tracker.flights.items.len);
}

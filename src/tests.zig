//! nanofly's tests: `zig build test` (against a local nanoui: --fork=../..).
test {
    _ = @import("geo.zig");
    _ = @import("data.zig");
    _ = @import("land.zig");
    _ = @import("sources.zig");
    _ = @import("flight.zig");
    _ = @import("map.zig");
    _ = @import("clock.zig");
    _ = @import("view_sheet.zig");
    _ = @import("tests_view.zig");
}

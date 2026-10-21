//! Times as each airport's clock shows them: Foundation's formatter, with
//! the airport's time zone ("Asia/Tokyo") and its daylight saving time.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

/// `unix` (seconds) formatted by `pattern` ("h:mm a", "EEE, d MMM") in the
/// time zone `tz` (this device's when "" or unknown).
pub fn format(buf: []u8, unix: f64, tz: []const u8, pattern: []const u8) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const f = objc.new("NSDateFormatter");
    defer objc.release(f);
    const posix = objc.msg(objc.Object, objc.class("NSLocale"), "localeWithLocaleIdentifier:", .{objc.nsString("en_US_POSIX")});
    objc.msg(void, f, "setLocale:", .{posix});
    objc.msg(void, f, "setDateFormat:", .{objc.nsString(pattern)});
    if (tz.len > 0) if (objc.msg(?objc.Object, objc.class("NSTimeZone"), "timeZoneWithName:", .{objc.nsString(tz)})) |zone|
        objc.msg(void, f, "setTimeZone:", .{zone});
    const date = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSince1970:", .{unix});
    const s = objc.fromNSString(objc.msg(?objc.Object, f, "stringFromDate:", .{date}));
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

test "a moment on Tokyo's clock and on New York's" {
    var buf: [32]u8 = undefined;
    // 2026-10-21 10:00 UTC.
    const t: f64 = 1792576800;
    try std.testing.expectEqualStrings("7:00 PM", format(&buf, t, "Asia/Tokyo", "h:mm a"));
    try std.testing.expectEqualStrings("6:00 AM", format(&buf, t, "America/New_York", "h:mm a"));
    try std.testing.expectEqualStrings("WED, 21 OCT", std.ascii.upperString(&buf, format(&buf, t, "Asia/Tokyo", "EEE, d MMM")));
}

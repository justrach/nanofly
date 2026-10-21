//! Land outlines (data/land*.bin, tools/prep.py) to triangles, once, as the
//! app is built: the phone then draws them without working them out.
//!
//!   meshgen IN.bin OUT.mesh
//!
//! OUT, little-endian: "NFM1", u32 outlines, then each: u32 points, u32
//! triangles, f32 bounds (x0, y0, x1, y1), the points (f32 x, f32 y), the
//! triangles (u16 corners × 3, u16 smooth edges).
const std = @import("std");
const draw = @import("triangulate");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const in = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(64 << 20));
    defer gpa.free(in);
    if (in.len < 8 or !std.mem.eql(u8, in[0..4], "NFL1")) return error.NotLand;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const rings = std.mem.readInt(u32, in[4..8], .little);
    try out.appendSlice(gpa, "NFM1");
    try put(gpa, &out, u32, rings);
    var at: usize = 8;
    var points: std.ArrayList(draw.Point) = .empty;
    defer points.deinit(gpa);
    for (0..rings) |_| {
        const n = std.mem.readInt(u32, in[at..][0..4], .little);
        at += 4;
        points.clearRetainingCapacity();
        var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
        var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
        for (0..n) |_| {
            const x: f32 = @bitCast(std.mem.readInt(u32, in[at..][0..4], .little));
            const y: f32 = @bitCast(std.mem.readInt(u32, in[at + 4 ..][0..4], .little));
            at += 8;
            try points.append(gpa, .{ .x = x, .y = y });
            lo = .{ @min(lo[0], x), @min(lo[1], y) };
            hi = .{ @max(hi[0], x), @max(hi[1], y) };
        }
        const tris = try draw.triangulate(gpa, points.items);
        defer gpa.free(tris);
        try put(gpa, &out, u32, n);
        try put(gpa, &out, u32, @intCast(tris.len));
        for ([_]f32{ lo[0], lo[1], hi[0], hi[1] }) |v| try put(gpa, &out, u32, @bitCast(v));
        for (points.items) |p| {
            try put(gpa, &out, u32, @bitCast(p.x));
            try put(gpa, &out, u32, @bitCast(p.y));
        }
        for (tris) |t| {
            for (t.v) |v| try put(gpa, &out, u16, @intCast(v));
            try put(gpa, &out, u16, t.smooth);
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.items });
}

fn put(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

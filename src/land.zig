//! The land, as triangles on the map's square (tools/meshgen.zig made them
//! as the app was built): the world's outline at 1:110m for the whole
//! earth, at 1:50m for a closer look.
const std = @import("std");

pub const Ring = struct {
    /// Its bounds on the square: x0, y0, x1, y1.
    bounds: [4]f32,
    points: []const [2]f32,
    /// Corners (indices into `points`) and which edges are the coast.
    tris: []const Tri,
};

pub const Tri = struct { v: [3]u16, smooth: u3 };

pub const Land = struct {
    rings: []Ring,
    points: [][2]f32,
    tris: []Tri,

    /// The mesh `bytes` ("NFM1", tools/meshgen.zig), copied.
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Land {
        if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "NFM1")) return error.NotAMesh;
        var r: Reader = .{ .bytes = bytes, .at = 4 };
        const count = try r.int(u32);
        // Twice over: sized first, then filled.
        var total_points: usize = 0;
        var total_tris: usize = 0;
        var scan = r;
        for (0..count) |_| {
            const n = try scan.int(u32);
            const t = try scan.int(u32);
            total_points += n;
            total_tris += t;
            try scan.skip(16 + n * 8 + t * 8);
        }
        const rings = try gpa.alloc(Ring, count);
        errdefer gpa.free(rings);
        const points = try gpa.alloc([2]f32, total_points);
        errdefer gpa.free(points);
        const tris = try gpa.alloc(Tri, total_tris);
        errdefer gpa.free(tris);
        var p_at: usize = 0;
        var t_at: usize = 0;
        for (rings) |*ring| {
            const n = try r.int(u32);
            const t = try r.int(u32);
            var b: [4]f32 = undefined;
            for (&b) |*v| v.* = try r.float();
            const ps = points[p_at..][0..n];
            for (ps) |*p| p.* = .{ try r.float(), try r.float() };
            const ts = tris[t_at..][0..t];
            for (ts) |*tri| {
                tri.v = .{ try r.int(u16), try r.int(u16), try r.int(u16) };
                tri.smooth = @truncate(try r.int(u16));
            }
            ring.* = .{ .bounds = b, .points = ps, .tris = ts };
            p_at += n;
            t_at += t;
        }
        return .{ .rings = rings, .points = points, .tris = tris };
    }

    pub fn deinit(l: *Land, gpa: std.mem.Allocator) void {
        gpa.free(l.rings);
        gpa.free(l.points);
        gpa.free(l.tris);
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize,

    fn int(r: *Reader, comptime T: type) !T {
        if (r.at + @sizeOf(T) > r.bytes.len) return error.Truncated;
        defer r.at += @sizeOf(T);
        return std.mem.readInt(T, r.bytes[r.at..][0..@sizeOf(T)], .little);
    }

    fn float(r: *Reader) !f32 {
        return @bitCast(try r.int(u32));
    }

    fn skip(r: *Reader, n: usize) !void {
        if (r.at + n > r.bytes.len) return error.Truncated;
        r.at += n;
    }
};

test "the carried land: every outline triangulated, covering the square's middle latitudes" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ @embedFile("land110.mesh"), @embedFile("land50.mesh") }) |bytes| {
        var l = try Land.parse(gpa, bytes);
        defer l.deinit(gpa);
        try std.testing.expect(l.rings.len > 100);
        for (l.rings) |ring| {
            try std.testing.expectEqual(ring.points.len - 2, ring.tris.len);
            for (ring.tris) |t| for (t.v) |v| try std.testing.expect(v < ring.points.len);
        }
    }
}

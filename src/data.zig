//! The airports and airlines the app carries (data/*.tsv, tools/prep.py),
//! read once at launch, and found by their codes.
const std = @import("std");
const geo = @import("geo.zig");

pub const Airport = struct {
    iata: []const u8,
    icao: []const u8,
    name: []const u8,
    city: []const u8,
    country: []const u8,
    pos: geo.LatLon,
    /// Its time zone's name ("Asia/Tokyo"): "" when not known.
    tz: []const u8,

    /// The code people know it by: its IATA code, else its ICAO one.
    pub fn code(a: Airport) []const u8 {
        return if (a.iata.len > 0) a.iata else a.icao;
    }
};

pub const Airline = struct {
    icao: []const u8,
    iata: []const u8,
    name: []const u8,
};

pub const Data = struct {
    airports: []Airport,
    airlines: []Airline,
    by_icao: std.StringHashMapUnmanaged(u32) = .empty,
    by_iata: std.StringHashMapUnmanaged(u32) = .empty,
    airline_by_icao: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn load(gpa: std.mem.Allocator) !Data {
        return parse(gpa, @embedFile("airports.tsv"), @embedFile("airlines.tsv"));
    }

    pub fn parse(gpa: std.mem.Allocator, airports_tsv: []const u8, airlines_tsv: []const u8) !Data {
        var airports: std.ArrayList(Airport) = .empty;
        errdefer airports.deinit(gpa);
        var lines = std.mem.splitScalar(u8, airports_tsv, '\n');
        while (lines.next()) |line| {
            var f: [8][]const u8 = undefined;
            if (!fields(line, &f)) continue;
            const lat = std.fmt.parseFloat(f64, f[5]) catch continue;
            const lon = std.fmt.parseFloat(f64, f[6]) catch continue;
            try airports.append(gpa, .{ .iata = f[0], .icao = f[1], .name = f[2], .city = f[3], .country = f[4], .pos = .{ .lat = lat, .lon = lon }, .tz = f[7] });
        }
        var airlines: std.ArrayList(Airline) = .empty;
        errdefer airlines.deinit(gpa);
        lines = std.mem.splitScalar(u8, airlines_tsv, '\n');
        while (lines.next()) |line| {
            var f: [3][]const u8 = undefined;
            if (!fields(line, &f)) continue;
            try airlines.append(gpa, .{ .icao = f[0], .iata = f[1], .name = f[2] });
        }
        var d: Data = .{ .airports = try airports.toOwnedSlice(gpa), .airlines = try airlines.toOwnedSlice(gpa) };
        errdefer d.deinit(gpa);
        for (d.airports, 0..) |a, k| {
            try d.by_icao.put(gpa, a.icao, @intCast(k));
            if (a.iata.len > 0) {
                const got = try d.by_iata.getOrPut(gpa, a.iata);
                if (!got.found_existing) got.value_ptr.* = @intCast(k);
            }
        }
        for (d.airlines, 0..) |a, k| try d.airline_by_icao.put(gpa, a.icao, @intCast(k));
        return d;
    }

    pub fn deinit(d: *Data, gpa: std.mem.Allocator) void {
        d.by_icao.deinit(gpa);
        d.by_iata.deinit(gpa);
        d.airline_by_icao.deinit(gpa);
        gpa.free(d.airports);
        gpa.free(d.airlines);
    }

    pub fn airport(d: *const Data, icao: []const u8) ?*const Airport {
        const k = d.by_icao.get(icao) orelse return null;
        return &d.airports[k];
    }

    pub fn airline(d: *const Data, icao: []const u8) ?*const Airline {
        const k = d.airline_by_icao.get(icao) orelse return null;
        return &d.airlines[k];
    }

    /// The airlines flying as `iata` ("JL": Japan Airlines, J-Air…), into
    /// `out`; how many.
    pub fn airlinesFor(d: *const Data, iata: []const u8, out: []u32) usize {
        var n: usize = 0;
        for (d.airlines, 0..) |a, k| {
            if (n == out.len) break;
            if (std.ascii.eqlIgnoreCase(a.iata, iata)) {
                out[n] = @intCast(k);
                n += 1;
            }
        }
        return n;
    }
};

/// Splits a line of tabs into exactly `out.len` fields.
fn fields(line: []const u8, out: [][]const u8) bool {
    var it = std.mem.splitScalar(u8, line, '\t');
    for (out) |*o| o.* = it.next() orelse return false;
    return it.next() == null;
}

/// "Tokyo Haneda International Airport" as a card shows it: "Tokyo Haneda Intl."
pub fn shortName(buf: []u8, name: []const u8) []const u8 {
    var n = name;
    if (std.mem.endsWith(u8, n, " Airport")) n = n[0 .. n.len - " Airport".len];
    const intl = " International";
    if (std.mem.endsWith(u8, n, intl)) {
        const head = n[0 .. n.len - intl.len];
        return std.fmt.bufPrint(buf, "{s} Intl.", .{head}) catch n;
    }
    return n;
}

test "the carried tables: Haneda and Kansai by their codes, Japan Airlines as JL" {
    const gpa = std.testing.allocator;
    var d = try Data.load(gpa);
    defer d.deinit(gpa);
    const hnd = d.airport("RJTT").?;
    try std.testing.expectEqualStrings("HND", hnd.iata);
    try std.testing.expectEqualStrings("Asia/Tokyo", hnd.tz);
    try std.testing.expectEqualStrings("RJBB", d.airports[d.by_iata.get("KIX").?].icao);
    var out: [4]u32 = undefined;
    const n = d.airlinesFor("JL", &out);
    try std.testing.expect(n >= 1);
    var found = false;
    for (out[0..n]) |k| found = found or std.mem.eql(u8, d.airlines[k].icao, "JAL");
    try std.testing.expect(found);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Kansai Intl.", shortName(&buf, "Kansai International Airport"));
}

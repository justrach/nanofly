const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("nanoui", .{ .target = target, .optimize = optimize });
    const nanoui = dep.module("nanoui");

    // The land as triangles, worked out on this machine as the app is built
    // (tools/meshgen.zig, with nanoui's own triangulation).
    const meshgen = b.addExecutable(.{ .name = "meshgen", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/meshgen.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "triangulate", .module = b.createModule(.{ .root_source_file = dep.path("src/ui/triangulate.zig"), .target = b.graph.host, .optimize = .ReleaseFast }) }},
    }) });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    embedData(b, mod, meshgen);
    const exe = b.addExecutable(.{ .name = "nanofly", .root_module = mod });

    if (target.result.os.tag == .ios) {
        const ios = @import("nanoui").ios;
        const opts: ios.Options = .{ .name = "nanofly", .id = "dev.nanoui.nanofly" };
        const bundle = ios.app(b, exe, opts);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = bundle, .install_dir = .prefix, .install_subdir = "ios/nanofly.app" }).step);
        const run = ios.runInSimulator(b, bundle, opts, dep.path("."));
        run.addPassthruArgs();
        b.step("run", "Run nanofly in the booted Simulator").dependOn(&run.step);
    } else {
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step("run", "Run nanofly").dependOn(&run.step);
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    embedData(b, test_mod, meshgen);
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run nanofly's tests").dependOn(&b.addRunArtifact(tests).step);
}

/// The data the app carries (data/, tools/prep.py), as `@embedFile`s.
fn embedData(b: *std.Build, mod: *std.Build.Module, meshgen: *std.Build.Step.Compile) void {
    for ([_][]const u8{ "land110", "land50" }) |name| {
        const run = b.addRunArtifact(meshgen);
        run.addFileArg(b.path(b.fmt("data/{s}.bin", .{name})));
        const out = run.addOutputFileArg(b.fmt("{s}.mesh", .{name}));
        mod.addAnonymousImport(b.fmt("{s}.mesh", .{name}), .{ .root_source_file = out });
    }
    for ([_][]const u8{ "airports.tsv", "airlines.tsv" }) |name|
        mod.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("data/{s}", .{name})) });
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("sra", .{
        .root_source_file = b.path("src/sra.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    // TODO: static lib for C

    const exe = b.addExecutable(.{
        .name = "sra-archive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bin/sra-archive.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
            .imports = &.{
                .{ .name = "sra", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const step = b.step("run", "run sra-archive");
    step.dependOn(&run.step);
}

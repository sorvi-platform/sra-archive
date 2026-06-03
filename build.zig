const std = @import("std");

// zlinter-disable-next-line require_doc_comment
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlinter = @import("zlinter");
    const lint_cmd = b.step("lint", "Lint source code");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        inline for (std.enums.values(zlinter.BuiltinLintRule)) |v| {
            if (v == .declaration_naming) continue;
            if (v == .field_naming) continue;
            if (v == .no_orelse_unreachable) continue;
            if (v == .require_exhaustive_enum_switch) continue;
            if (v == .no_undefined) continue;
            if (v == .field_ordering) continue;
            if (v == .import_ordering) continue;
            if (v == .no_todo) continue;
            if (v == .max_positional_args) continue;
            if (v == .no_panic) continue;
            builder.addRule(.{ .builtin = v }, .{});
        }
        break :step builder.build();
    });

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

    const tst = b.addTest(.{
        .name = "sra-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const tst_run = b.addRunArtifact(tst);
    const tst_step = b.step("test", "run tests");
    tst_step.dependOn(&tst_run.step);
}

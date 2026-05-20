const std = @import("std");
const sra = @import("sra");
const log = std.log.scoped(.@"sra-archive");

pub fn usage(io: std.Io, failure: bool) noreturn {
    var buf: [64]u8 = undefined;
    var writer = switch (failure) {
        true => std.Io.File.stderr().writer(io, &buf),
        false => std.Io.File.stdout().writer(io, &buf),
    };
    writer.interface.writeAll(
        \\usage:
        \\  --archive [archive] [file/dir] ...
        \\  --extract [archive] [output] (path to extract) ...
        \\  --list    [archive] ...
        \\
    ) catch @panic("cannot write to out stream");
    writer.interface.flush() catch @panic("cannot flush");
    if (failure) std.process.exit(64); // EX_USAGE
    std.process.exit(0);
}

const allocator = std.heap.smp_allocator;

pub fn main(init: std.process.Init) u8 {
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    // TODO: add --update, --remove and --add
    const Mode = enum {
        @"--archive",
        @"--extract",
        @"--list",
        @"--help",
    };

    const mode: Mode = D: {
        const arg = args.next() orelse {
            log.err("missing mode argument", .{});
            usage(init.io, true);
        };
        const mode = std.meta.stringToEnum(Mode, arg) orelse {
            log.err("invalid mode: {s}", .{arg});
            usage(init.io, true);
        };
        break :D mode;
    };

    _ = switch (mode) {
        .@"--list" => doList(init.io, &args),
        .@"--help" => usage(init.io, false),
        else => {},
    } catch |err| {
        log.err("error: {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        return 70; // EX_SOFTWARE
    };

    const archive_path = args.next() orelse {
        log.err("missing archive path", .{});
        usage(init.io, true);
    };

    _ = switch (mode) {
        .@"--archive" => doArchive(init.io, archive_path, &args),
        .@"--extract" => doExtract(init.io, archive_path, &args),
        else => unreachable,
    } catch |err| {
        log.err("error: {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        return 70; // EX_SOFTWARE
    };

    return 0;
}

// This is same as sra.Writer.writeDir, but we want to have std.Progress
fn doArchiveWalkDir(io: std.Io, parent_node: std.Progress.Node, sraw: *sra.Writer, base: []const u8, path: []const u8) !void {
    const node = parent_node.start(base, 0);
    defer node.end();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var walker = try std.Io.Dir.walk(dir, allocator);
    defer walker.deinit();
    const did_push = try sraw.push(base);
    defer if (did_push) sraw.pop();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                var child = node.start(entry.path, 0);
                defer child.end();
                sraw.writeFilePath(io, entry.path, entry.dir, entry.basename, null) catch |err| switch (err) {
                    error.InvalidPath => |e| {
                        log.err("{s}", .{entry.path});
                        return e;
                    },
                    else => |e| return e,
                };
            },
            else => return error.InvalidFileType,
        }
    }
}

pub fn doArchive(io: std.Io, archive_path: []const u8, args: *std.process.Args.Iterator) !void {
    const root_node = std.Progress.start(io, .{});
    defer root_node.end();
    const node = root_node.start(archive_path, 0);
    defer node.end();
    var file = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var sraw: sra.Writer = .init(allocator, &writer.interface);
    defer sraw.deinit();
    try sraw.writeMagic(.default);
    while (args.next()) |path| {
        const base = std.fs.path.basename(path);
        const st = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        switch (st.kind) {
            .file => {
                var child = node.start(base, 0);
                defer child.end();
                sraw.writeFilePath(io, base, std.Io.Dir.cwd(), path, @intCast(@max(0, st.mtime.toMilliseconds()))) catch |err| switch (err) {
                    error.InvalidPath => |e| {
                        log.err("{s}", .{base});
                        return e;
                    },
                    else => |e| return e,
                };
            },
            .directory => try doArchiveWalkDir(io, node, &sraw, base, path),
            else => return error.InvalidFileType,
        }
    }
    try sraw.finish();
}

pub fn doExtract(io: std.Io, archive_path: []const u8, args: *std.process.Args.Iterator) !void {
    const output_path = args.next() orelse {
        log.err("missing output path", .{});
        usage(io, true);
    };

    const root_node = std.Progress.start(io, .{});
    defer root_node.end();

    var output_dir = try std.Io.Dir.cwd().createDirPathOpen(io, output_path, .{});
    defer output_dir.close(io);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    while (args.next()) |path| {
        try paths.append(arena.allocator(), try arena.allocator().dupe(u8, path));
    }

    var buffer: [4096]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);
    var reader = file.reader(io, &buffer);
    var srar: sra.Reader = try .init(&reader, .default);
    try srar.validateCrc();
    const path_bytes = try srar.allocPathBytes(arena.allocator());

    var entry_buffer: [4096]u8 = undefined;
    if (paths.items.len > 0) {
        var map: std.StringArrayHashMapUnmanaged(sra.Entry) = .empty;
        var iter = try srar.iterator();
        while (try iter.next(&srar)) |entry| {
            try entry.validate(&srar);
            try entry.path.validate(path_bytes);
            try map.putNoClobber(arena.allocator(), entry.path.slice(path_bytes), entry);
        }
        for (paths.items) |path| if (!map.contains(path)) return error.PathDoesNotExistInArchive;
        const node = root_node.start(archive_path, paths.items.len);
        defer node.end();
        for (paths.items) |path| {
            const child = node.start(path, 0);
            defer child.end();
            const entry = map.get(path) orelse unreachable;
            var entry_reader = try entry.dataReader(&reader);
            if (std.fs.path.dirname(path)) |sub_path| try output_dir.createDirPath(io, sub_path);
            var entry_file = try output_dir.createFile(io, path, .{});
            defer entry_file.close(io);
            var writer = entry_file.writer(io, &entry_buffer);
            const written = try entry_reader.interface.streamRemaining(&writer.interface);
            std.debug.assert(written == entry.data_length);
        }
    } else {
        var iter = try srar.iterator();
        const node = root_node.start(archive_path, iter.entries_length);
        defer node.end();
        while (try iter.next(&srar)) |entry| {
            try entry.validate(&srar);
            try entry.path.validate(path_bytes);
            const path = entry.path.slice(path_bytes);
            const child = node.start(path, 0);
            defer child.end();
            var entry_reader = try entry.dataReader(&reader);
            if (std.fs.path.dirname(path)) |sub_path| try output_dir.createDirPath(io, sub_path);
            var entry_file = try output_dir.createFile(io, path, .{});
            defer entry_file.close(io);
            var writer = entry_file.writer(io, &entry_buffer);
            const written = try entry_reader.interface.streamRemaining(&writer.interface);
            std.debug.assert(written == entry.data_length);
            const mtime_ms: i96 = @intCast(entry.data_mtime);
            try entry_file.setTimestamps(io, .{
                .access_timestamp = .{ .new = .fromNanoseconds(mtime_ms * std.time.ns_per_ms) },
                .modify_timestamp = .{ .new = .fromNanoseconds(mtime_ms * std.time.ns_per_ms) },
            });
        }
    }
}

const FmtBytes = struct {
    bytes: u64,
    width: u64,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        const units: []const []const u8 = &.{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
        var value = self.bytes;
        var remainder: u64 = 0;
        var unit_index: usize = 0;
        while (value >= 1024 and unit_index + 1 < units.len) {
            remainder = value % 1024;
            value /= 1024;
            unit_index += 1;
        }
        const decimal = remainder * 10 / 1024;
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        try discarding.writer.print("{d}.{d} {s}", .{ value, decimal, units[unit_index] });
        if (self.width > discarding.count) _ = try writer.splatByte(' ', self.width - discarding.count);
        try writer.print("{d}.{d} {s}", .{ value, decimal, units[unit_index] });
    }
};

fn fmtBytes(bytes: u64, width: u64) FmtBytes {
    return .{ .bytes = bytes, .width = width };
}

const FmtDate = struct {
    secs: u64,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = self.secs / std.time.ms_per_s };
        const time = epoch.getDaySeconds();
        const year = epoch.getEpochDay().calculateYearDay();
        const month = year.calculateMonthDay();
        try writer.print("{s} {d:0>2} {} {d:0>2}:{d:0>2}", .{ @tagName(month.month), month.day_index, year.year, time.getHoursIntoDay(), time.getMinutesIntoHour() });
    }
};

fn fmtDate(secs: u64) FmtDate {
    return .{ .secs = secs };
}

fn printSize(comptime fmt: []const u8, args: anytype) !usize {
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    try discarding.writer.print(fmt, args);
    return discarding.count;
}

pub fn doList(io: std.Io, args: *std.process.Args.Iterator) !void {
    var stdout_buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    var buffer: [4096]u8 = undefined;
    while (args.next()) |archive_path| {
        var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
        defer file.close(io);
        var reader = file.reader(io, &buffer);
        var srar: sra.Reader = try .init(&reader, .default);
        try srar.validateCrc();
        const path_bytes = try srar.allocPathBytes(allocator);
        defer allocator.free(path_bytes);
        var iter = try srar.iterator();
        var longest_size_width: u64 = 0;
        var longest_offset_width: u64 = 0;
        while (try iter.next(&srar)) |entry| {
            longest_size_width = @max(try printSize("{f}", .{fmtBytes(entry.data_length, 0)}), longest_size_width);
            longest_offset_width = @max(try printSize("{x}", .{entry.data_offset}), longest_offset_width);
        }
        try iter.reset(&srar);
        while (try iter.next(&srar)) |entry| {
            try entry.validate(&srar);
            try entry.path.validate(path_bytes);
            const path = entry.path.slice(path_bytes);
            try stdout.interface.print("{[size]f} {[offset]x: >[offset_w]} {[mtime]f} {[path]s}\n", .{
                .size = fmtBytes(entry.data_length, longest_size_width),
                .offset = entry.data_offset,
                .offset_w = longest_offset_width,
                .mtime = fmtDate(entry.data_mtime),
                .path = path,
            });
        }
        const width = try printSize("0x{x}", .{srar.crc});
        _ = try stdout.interface.splatByte('-', width);
        try stdout.interface.print("\n0x{x}\n", .{srar.crc});
    }
    try stdout.interface.flush();
    std.process.exit(0);
}

const std = @import("std");
const sra = @import("sra.zig");

test "validatePath - valid paths" {
    try sra.validatePath("file.txt");
    try sra.validatePath("dir/file.txt");
    try sra.validatePath("path/to/deep/file.txt");
    try sra.validatePath("file with spaces.txt");
    try sra.validatePath("assets/textures/player.png");
    try sra.validatePath("猫神.txt");
    try sra.validatePath("données/fichier.txt");
}

test "validatePath - invalid paths" {
    try std.testing.expectError(error.InvalidPath, sra.validatePath(""));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("/absolute"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("double//slash"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("trailing/"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has<bracket"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has>bracket"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has:colon"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has\"quote"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has\\backslash"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has|pipe"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has?question"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has*asterisk"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("."));
    try std.testing.expectError(error.InvalidPath, sra.validatePath(".."));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("dir/."));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("dir/.."));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("dir/./file"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("dir/../file"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has\ttab"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("has\nnewline"));
    try std.testing.expectError(error.InvalidPath, sra.validatePath("invalid\xFF\xFE"));
}

test "Writer - write and finish" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    var writer: sra.Writer = .init(std.testing.allocator, &allocating.writer);
    defer writer.deinit();
    try writer.writeMagic(.default);
    try writer.writeFileBytes("test.txt", "Hello, World!", 1234567890);
    try writer.finish();
}

test "Writer - duplicate file error" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    var writer: sra.Writer = .init(std.testing.allocator, &allocating.writer);
    defer writer.deinit();
    try writer.writeMagic(.default);
    try writer.writeFileBytes("test.txt", "Content", 1000);
    try std.testing.expectError(error.FileAlreadyExists, writer.writeFileBytes("test.txt", "Other", 2000));
}

test "Writer - push/pop directory prefix" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    var writer: sra.Writer = .init(std.testing.allocator, &allocating.writer);
    defer writer.deinit();
    try writer.writeMagic(.default);
    _ = try writer.push("assets");
    try writer.writeFileBytes("image.png", "PNG data", 1000);
    try writer.writeFileBytes("sound.ogg", "OGG data", 2000);
    writer.pop();
    try writer.finish();
}

test "Reader - invalid magic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("invalid.sra", .{ .read = true });
    defer file.close();
    try file.writeAll("INVALID\x00");
    try file.seekTo(0);
    var buffer: [16]u8 = undefined;
    var file_reader = file.reader(&buffer);
    try std.testing.expectError(error.InvalidArchive, sra.Reader.init(&file_reader, .default));
}

test "Reader - custom magic accepted and default magic rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("custom.sra", .{ .read = true });
    defer file.close();

    {
        var file_writer = file.writer(&.{});
        var writer: sra.Writer = .init(std.testing.allocator, &file_writer.interface);
        defer writer.deinit();
        try writer.writeMagic(.{ .custom = "MYA\x00" });
        try writer.writeFileBytes("a.txt", "data", 1000);
        try writer.finish();
    }

    try file.seekTo(0);
    var buffer: [16]u8 = undefined;
    var file_reader = file.reader(&buffer);
    try std.testing.expectError(error.InvalidArchive, sra.Reader.init(&file_reader, .default));
    try file.seekTo(0);
    _ = try sra.Reader.init(&file_reader, .{ .custom = "MYA\x00" });
}

test "Reader - validate CRC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("test.sra", .{ .read = true });
    defer file.close();

    {
        var file_writer = file.writer(&.{});
        var writer: sra.Writer = .init(std.testing.allocator, &file_writer.interface);
        defer writer.deinit();
        try writer.writeMagic(.default);
        try writer.writeFileBytes("test.txt", "Content", 1000);
        try writer.finish();
    }

    {
        var file_writer = file.writer(&.{});
        try file_writer.seekTo(try file.getEndPos() - 4);
        try file_writer.interface.writeInt(u32, 0xDEADBEEF, .little);
    }

    try file.seekTo(0);
    var buffer: [16]u8 = undefined;
    var file_reader = file.reader(&buffer);
    var reader: sra.Reader = try .init(&file_reader, .default);
    try std.testing.expectError(error.InvalidChecksum, reader.validateCrc());
}

test "Writer and Reader - round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("test.sra", .{ .read = true });
    defer file.close();

    const File = struct {
        name: []const u8,
        data: []const u8,
        mtime: u64,
    };

    const files: []const File = &.{
        .{ .name = "file1.txt", .data = "Hello, World!", .mtime = 1000 },
        .{ .name = "dir/file2.txt", .data = "Test content", .mtime = 2000 },
        .{ .name = "assets/data.bin", .data = "Binary data", .mtime = 3000 },
    };

    {
        var file_writer = file.writer(&.{});
        var writer: sra.Writer = .init(std.testing.allocator, &file_writer.interface);
        defer writer.deinit();
        try writer.writeMagic(.default);
        for (files) |f| try writer.writeFileBytes(f.name, f.data, f.mtime);
        try writer.finish();
    }

    {
        try file.seekTo(0);
        var buffer: [16]u8 = undefined;
        var file_reader = file.reader(&buffer);
        var reader: sra.Reader = try .init(&file_reader, .default);
        try reader.validateCrc();

        const path_bytes = try reader.allocPathBytes(std.testing.allocator);
        defer std.testing.allocator.free(path_bytes);

        var iter = try reader.iterator();
        var count: usize = 0;
        while (try iter.next(&reader)) |entry| {
            try entry.validate(&reader);
            const path = entry.path.slice(path_bytes);
            try sra.validatePath(path);
            try std.testing.expectEqualSlices(u8, files[count].name, path);
            try std.testing.expectEqual(files[count].data.len, entry.data_length);
            try std.testing.expectEqual(files[count].mtime, entry.data_mtime);
            var dbuf: [1024]u8 = undefined;
            const len = try file.preadAll(dbuf[0..entry.data_length], entry.data_offset);
            try std.testing.expectEqualSlices(u8, files[count].data, dbuf[0..len]);
            count += 1;
        }
        try std.testing.expectEqual(3, count);
    }
}

test "Writer and Reader - round trip with push/pop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("test.sra", .{ .read = true });
    defer file.close();

    {
        var file_writer = file.writer(&.{});
        var writer: sra.Writer = .init(std.testing.allocator, &file_writer.interface);
        defer writer.deinit();
        try writer.writeMagic(.default);
        _ = try writer.push("assets");
        try writer.writeFileBytes("logo.png", "PNG", 100);
        _ = try writer.push("sounds");
        try writer.writeFileBytes("click.ogg", "OGG", 200);
        writer.pop(); // sounds
        writer.pop(); // assets
        try writer.writeFileBytes("readme.txt", "README", 300);
        try writer.finish();
    }

    {
        try file.seekTo(0);
        var buffer: [16]u8 = undefined;
        var file_reader = file.reader(&buffer);
        var reader: sra.Reader = try .init(&file_reader, .default);
        try reader.validateCrc();

        const path_bytes = try reader.allocPathBytes(std.testing.allocator);
        defer std.testing.allocator.free(path_bytes);

        const expected_paths: []const []const u8 = &.{
            "assets/logo.png",
            "assets/sounds/click.ogg",
            "readme.txt",
        };

        var iter = try reader.iterator();
        var count: usize = 0;
        while (try iter.next(&reader)) |entry| {
            const path = entry.path.slice(path_bytes);
            try std.testing.expectEqualSlices(u8, expected_paths[count], path);
            count += 1;
        }
        try std.testing.expectEqual(3, count);
    }
}

test "Writer and Reader - empty archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("empty.sra", .{ .read = true });
    defer file.close();

    {
        var file_writer = file.writer(&.{});
        var writer: sra.Writer = .init(std.testing.allocator, &file_writer.interface);
        defer writer.deinit();
        try writer.writeMagic(.default);
        try writer.finish();
    }

    {
        try file.seekTo(0);
        var buffer: [16]u8 = undefined;
        var file_reader = file.reader(&buffer);
        var reader: sra.Reader = try .init(&file_reader, .default);
        try reader.validateCrc();
        var iter = try reader.iterator();
        const entry = try iter.next(&reader);
        try std.testing.expectEqual(null, entry);
    }
}

test "Path - slice" {
    const path_bytes = "file1.txtdir/file2.txt";
    const p1: sra.Path = .{ .offset = 0, .length = 9 };
    const p2: sra.Path = .{ .offset = 9, .length = 13 };
    try std.testing.expectEqualSlices(u8, "file1.txt", p1.slice(path_bytes));
    try std.testing.expectEqualSlices(u8, "dir/file2.txt", p2.slice(path_bytes));
}

test "Path - validate" {
    const path_bytes = "valid/path.txt";
    const p: sra.Path = .{ .offset = 0, .length = @intCast(path_bytes.len) };
    try p.validate(path_bytes);
}

test "Path - validate out of bounds" {
    const path_bytes = "short";
    const p: sra.Path = .{ .offset = 0, .length = 100 };
    try std.testing.expectError(error.InvalidPath, p.validate(path_bytes));
}

test "Magic - default slice" {
    const m: sra.Magic = .default;
    try std.testing.expectEqualSlices(u8, "SRA\x00", m.slice());
}

test "Magic - custom slice" {
    const m: sra.Magic = .{ .custom = "MYMAGIC\x00" };
    try std.testing.expectEqualSlices(u8, "MYMAGIC\x00", m.slice());
}

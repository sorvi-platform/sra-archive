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

test "WriteStream" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    var writer: sra.WriteStream = .init(std.testing.allocator, &allocating.writer);
    defer writer.deinit();
    const content = "Hello, World!";
    try writer.writeFileBytes("test.txt", content, 1234567890);
    const header = try writer.finish();
    try std.testing.expect(header.path_table_offset == sra.header_size + content.len);
    try std.testing.expect(header.index_offset == header.path_table_offset + "test.txt\x00".len);
}

test "WriteStream - duplicate file error" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    var writer: sra.WriteStream = .init(std.testing.allocator, &allocating.writer);
    defer writer.deinit();
    try writer.writeFileBytes("test.txt", "Content", 1000);
    try std.testing.expectError(error.FileAlreadyExists, writer.writeFileBytes("test.txt", "Other", 2000));
}

test "Reader - invalid magic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("invalid.sra", .{ .read = true });
    defer file.close();
    try file.writeAll("INVALID\x00");
    try file.seekTo(0);
    var file_reader = file.reader(&.{});
    try std.testing.expectError(error.InvalidArchive, sra.Reader.init(&file_reader));
}

test "Reader - validate CRC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("test.sra", .{ .read = true });
    defer file.close();

    {
        var file_writer = file.writer(&.{});
        var writer: sra.Writer = try .init(std.testing.allocator, &file_writer);
        defer writer.deinit();
        try writer.stream.writeFileBytes("test.txt", "Content", 1000);
        try writer.finish();
    }

    {
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&.{});
        try writer.seekTo(4);
        try writer.interface.writeInt(u32, 0xDEADBEEF, .little);
        try writer.interface.writeInt(u32, 0xDEADBEEF, .little);
        try file.seekTo(0);
        var file_reader = file.reader(&buffer);
        var reader: sra.Reader = try .init(&file_reader);
        try std.testing.expectError(error.InvalidChecksum, reader.validateCrc1());
        try std.testing.expectError(error.InvalidChecksum, reader.validateCrc2());
    }
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
        var writer: sra.Writer = try .init(std.testing.allocator, &file_writer);
        defer writer.deinit();
        for (files) |f| try writer.stream.writeFileBytes(f.name, f.data, f.mtime);
        try writer.finish();
    }

    {
        var buffer: [4096]u8 = undefined;
        try file.seekTo(0);
        var file_reader = file.reader(&buffer);
        var reader: sra.Reader = try .init(&file_reader);
        try reader.validate();
        const paths = try reader.readStringTableAlloc(std.testing.allocator);
        defer std.testing.allocator.free(paths);
        var iter = try reader.iterator();
        try std.testing.expectEqual(3, iter.num_entries);
        var count: usize = 0;
        while (try iter.next(&reader)) |entry| {
            try reader.validateEntry(entry);
            const path: []const u8 = std.mem.sliceTo(paths[entry.path_offset - reader.path_table_offset ..], 0);
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

///! Very simple random access archive format with no compression.
///! Designed for fast random access.
///!
///! * All paths must be valid UTF8.
///! * '/' is the path separator.
///! * May only contain absolute paths without leading '/'.
///! * '.' and '..' path components are not allowed.
///! * '/' character, control characters and whitespace other than the space are not allowed in path components.
///! * This means paths may not contain newlines, tabs, and such.
///! * In addition to be nice to Windows, following characters are not allowed: [<>:"/\|?*]
///! * Entries in the index may appear in any order. Applications must not rely on index ordering.
///! * mtime since epoch (UTC) in milliseconds is stored for fast file modification checks (syncing / updating the archive)
///!
///! LITTLE-ENDIAN:
///!     SRA\0
///!     crc1: u32
///!     crc2: u32
///!     index_offset: u64
///!     path_table_offset: u64
///!     ... file_data ...
///!     ... null terminated paths ...
///!     ... index ...
///! index:
///!     num_entries: u64
///!     ... entry ...
///! entry:
///!     path_offset: u64
///!     data_offset: u64
///!     data_length: u64
///!     data_mtime: u64
///!
///! crc1 is calculated in the following order:
///! - index_offset
///! - path_table_offset
///! - num_entries
///! - each entry
///!
///! crc2 is the checksum of bytes between path_table_offset and index_offset.
///!
///! The crc1 and crc2 only check the structural integrity of the archive.
///! Integrity of the entry data is not checked.
///! It is up to the reader to validate the integrity of the archive.

const std = @import("std");

pub const magic = "SRA\x00";
pub const header_size = magic.len + @sizeOf(u32) * 2 + @sizeOf(u64) * 2;

pub const PathValidationError = error { InvalidPath };

pub fn validatePath(path: []const u8) PathValidationError!void {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '/') return error.InvalidPath;
    if (std.mem.indexOf(u8, path, "//")) |_| return error.InvalidPath;
    if (path[path.len - 1] == '/') return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    while (iter.next()) |part| {
        if (std.mem.eql(u8, part, ".")) return error.InvalidPath;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
        for (part) |c| {
            if (c == '/') return error.InvalidPath;
            if (std.ascii.isControl(c)) return error.InvalidPath;
            if (c != ' ' and std.ascii.isWhitespace(c)) return error.InvalidPath;
        }
    }
}

pub const IndexEntry = struct {
    path_offset: u64,
    data_offset: u64,
    data_length: u64,
    data_mtime: u64,
};

/// Stream based writer
/// This writer does not write the header as it cannot seek.
/// `stream.finish()` returns the offsets for the header.
pub const WriteStream = struct {
    arena: std.heap.ArenaAllocator,
    underlying_writer: *std.Io.Writer,
    dir_stack: std.ArrayList([]const u8),
    files: std.StringArrayHashMapUnmanaged(IndexEntry),
    pos: u64,

    pub fn init(gpa: std.mem.Allocator, underlying_writer: *std.Io.Writer) @This() {
        return .{
            .arena = .init(gpa),
            .underlying_writer = underlying_writer,
            .dir_stack = .empty,
            .files = .empty,
            .pos = header_size,
        };
    }

    pub const PushError = error { OutOfMemory } || PathValidationError;

    pub fn push(self: *@This(), sub_path: []const u8) PushError!bool {
        if (sub_path.len == 0) return false;
        try self.dir_stack.append(self.arena.allocator(), sub_path);
        return true;
    }

    pub fn pop(self: *@This()) void {
        _ = self.dir_stack.pop();
    }

    pub const WriteFileBytesError = error { FileAlreadyExists } || PushError || std.Io.Writer.Error;

    pub fn writeFileBytes(self: *@This(), sub_path: []const u8, bytes: []const u8, mtime: u64) WriteFileBytesError!void {
        std.debug.assert(try self.push(sub_path));
        defer self.pop();
        const path = try std.mem.join(self.arena.allocator(), "/", self.dir_stack.items);
        try validatePath(sub_path);
        const kv = try self.files.getOrPut(self.arena.allocator(), path);
        if (kv.found_existing) return error.FileAlreadyExists;
        try self.underlying_writer.writeAll(bytes);
        kv.value_ptr.* = .{ .data_offset = self.pos, .data_length = bytes.len, .data_mtime = mtime, .path_offset = 0 };
        self.pos += bytes.len;
    }

    pub const WriteFileError = error { FileAlreadyExists } || PushError || std.Io.Writer.Error || std.Io.Reader.Error;

    pub fn writeFileStream(self: *@This(), sub_path: []const u8, file_reader: *std.Io.Reader, mtime: u64) WriteFileError!void {
        std.debug.assert(try self.push(sub_path));
        defer self.pop();
        const path = try std.mem.join(self.arena.allocator(), "/", self.dir_stack.items);
        try validatePath(sub_path);
        const kv = try self.files.getOrPut(self.arena.allocator(), path);
        if (kv.found_existing) return error.FileAlreadyExists;
        const size = try file_reader.streamRemaining(self.underlying_writer);
        kv.value_ptr.* = .{ .data_offset = self.pos, .data_length = size, .data_mtime = mtime, .path_offset = 0 };
        self.pos += size;
    }

    pub fn writeFile(self: *@This(), sub_path: []const u8, file_reader: *std.fs.File.Reader, mtime: u64) WriteFileError!void {
        std.debug.assert(try self.push(sub_path));
        defer self.pop();
        const path = try std.mem.join(self.arena.allocator(), "/", self.dir_stack.items);
        try validatePath(sub_path);
        const kv = try self.files.getOrPut(self.arena.allocator(), path);
        if (kv.found_existing) return error.FileAlreadyExists;
        const size = try self.underlying_writer.sendFileAll(file_reader, .unlimited);
        kv.value_ptr.* = .{ .data_offset = self.pos, .data_length = size, .data_mtime = mtime, .path_offset = 0 };
        self.pos += size;
    }

    pub const WriteFilePathError = WriteFileError || std.fs.File.OpenError;

    pub fn writeFilePath(self: *@This(), sub_path: []const u8, dir: std.fs.Dir, file_path: []const u8, mtime: ?u64) WriteFilePathError!void {
        var file = try dir.openFile(file_path, .{});
        defer file.close();
        var reader = file.reader(&.{});
        if (mtime) |ms| {
            try self.writeFile(sub_path, &reader, ms);
        } else {
            const st = try file.stat();
            try self.writeFile(sub_path, &reader, @intCast(@divFloor(@max(st.mtime, 0), std.time.ns_per_ms)));
        }
    }

    pub const WriteDirError = error { InvalidFileType } || WriteFilePathError || std.fs.Dir.OpenError;

    pub fn writeDir(self: *@This(), sub_path: []const u8, dir: std.fs.Dir) WriteDirError!void {
        var walker = try std.fs.Dir.walk(dir, std.heap.smp_allocator);
        defer walker.deinit();
        const did_push = try self.push(sub_path);
        defer if (did_push) self.pop();
        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .directory => {},
                .file => try self.writeFilePath(entry.path, entry.dir, entry.basename, null),
                else => return error.InvalidFileType,
            }
        }
    }

    pub fn writeDirPath(self: *@This(), sub_path: []const u8, dir: std.fs.Dir, dir_path: []const u8) WriteDirError!void {
        var sub_dir = try dir.openDir(dir_path, .{.iterate = true, .no_follow = true});
        defer sub_dir.close();
        try self.writeDir(sub_path, sub_dir);
    }

    pub const FinishError = std.Io.Writer.Error;

    const Header = struct {
        crc1: u32,
        crc2: u32,
        index_offset: u64,
        path_table_offset: u64,
    };

    /// Finishes the current archive.
    /// It is possible to swap the `underlying_writer` and start writing a new archive.
    /// Reusing the writer reuses the old arena allocator.
    pub fn finish(self: *@This()) FinishError!Header {
        const header = try self.writeIndex();
        try self.underlying_writer.flush();
        _ = self.arena.reset(.retain_capacity);
        self.dir_stack = .empty;
        self.files = .empty;
        return header;
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn writeIndex(self: *@This()) !Header {
        const path_table_offset = self.pos;

        var crc2: std.hash.Crc32 = .init();
        {
            var iter = self.files.iterator();
            while (iter.next()) |kv| {
                kv.value_ptr.path_offset = self.pos;
                try self.underlying_writer.writeAll(kv.key_ptr.*);
                try self.underlying_writer.writeByte(0);
                crc2.update(kv.key_ptr.*);
                crc2.update(&.{0});
                self.pos += kv.key_ptr.len + 1;
            }
        }

        const index_offset = self.pos;
        try self.underlying_writer.writeInt(u64, self.files.entries.len, .little);

        var crc1: std.hash.Crc32 = .init();
        crc1.update(std.mem.asBytes(&index_offset));
        crc1.update(std.mem.asBytes(&path_table_offset));
        crc1.update(std.mem.asBytes(&self.files.entries.len));

        var iter = self.files.iterator();
        while (iter.next()) |kv| {
            crc1.update(std.mem.asBytes(kv.value_ptr));
            try self.underlying_writer.writeInt(u64, kv.value_ptr.path_offset, .little);
            try self.underlying_writer.writeInt(u64, kv.value_ptr.data_offset, .little);
            try self.underlying_writer.writeInt(u64, kv.value_ptr.data_length, .little);
            try self.underlying_writer.writeInt(u64, kv.value_ptr.data_mtime, .little);
        }

        std.debug.assert(index_offset >= path_table_offset);
        return .{
            .crc1 = crc1.final(),
            .crc2 = crc2.final(),
            .index_offset = index_offset,
            .path_table_offset = path_table_offset,
        };
    }
};

/// File.Writer based writer.
/// This writes the header and wraps the WriteStream.
pub const Writer = struct {
    stream: WriteStream,

    pub const InitError = std.Io.Writer.Error || std.fs.File.SeekError;

    pub fn init(gpa: std.mem.Allocator, underlying_writer: *std.fs.File.Writer) InitError!@This() {
        try underlying_writer.seekTo(0);
        try underlying_writer.interface.writeAll(magic);
        try underlying_writer.interface.writeInt(u32, 0, .little); // filled later
        try underlying_writer.interface.writeInt(u32, 0, .little); // filled later
        try underlying_writer.interface.writeInt(u64, 0, .little); // filled later
        try underlying_writer.interface.writeInt(u64, 0, .little); // filled later
        return .{ .stream = .init(gpa, &underlying_writer.interface) };
    }

    pub const FinishError = std.fs.File.SeekError || WriteStream.FinishError;

    pub fn finish(self: *@This()) FinishError!void {
        const header = try self.stream.finish();
        var writer: *std.fs.File.Writer = @fieldParentPtr("interface", self.stream.underlying_writer);
        try writer.seekTo(4);
        try writer.interface.writeInt(u32, header.crc1, .little);
        try writer.interface.writeInt(u32, header.crc2, .little);
        try writer.interface.writeInt(u64, header.index_offset, .little);
        try writer.interface.writeInt(u64, header.path_table_offset, .little);
        try writer.interface.flush();
    }

    pub fn deinit(self: *@This()) void {
        self.stream.deinit();
        self.* = undefined;
    }
};

pub const Reader = struct {
    underlying_reader: *std.fs.File.Reader,
    crc1: u32,
    crc2: u32,
    index_offset: u64,
    path_table_offset: u64,

    pub const InitError = error { InvalidArchive } || std.Io.Reader.Error || std.fs.File.SeekError;

    pub fn init(underlying_reader: *std.fs.File.Reader) !@This() {
        std.debug.assert(underlying_reader.mode == .positional);
        var hdr: [4]u8 = undefined;
        try underlying_reader.seekTo(0);
        try underlying_reader.interface.readSliceAll(&hdr);
        if (!std.mem.eql(u8, &hdr, magic)) return error.InvalidArchive;
        const crc1 = try underlying_reader.interface.takeInt(u32, .little);
        const crc2 = try underlying_reader.interface.takeInt(u32, .little);
        const index_offset = try underlying_reader.interface.takeInt(u64, .little);
        const path_table_offset = try underlying_reader.interface.takeInt(u64, .little);
        return .{
            .underlying_reader = underlying_reader,
            .crc1 = crc1,
            .crc2 = crc2,
            .index_offset = index_offset,
            .path_table_offset = path_table_offset,
        };
    }

    const ValidationError = error { InvalidChecksum } || ReadError;

    pub fn validateCrc1(self: *@This()) ValidationError!void {
        var crc1: std.hash.Crc32 = .init();
        crc1.update(std.mem.asBytes(&self.index_offset));
        crc1.update(std.mem.asBytes(&self.path_table_offset));
        var iter = try self.iterator();
        crc1.update(std.mem.asBytes(&iter.num_entries));
        while (try iter.next(self)) |entry| {
            crc1.update(std.mem.asBytes(&entry));
        }
        if (crc1.final() != self.crc1) {
            return error.InvalidChecksum;
        }
    }

    pub fn validateCrc2(self: *@This()) ValidationError!void {
        var crc2: std.hash.Crc32 = .init();
        try self.underlying_reader.seekTo(self.path_table_offset);
        var pos: u64 = 0;
        const end: u64 = self.index_offset - self.path_table_offset;
        while (true) {
            var buffer: [64]u8 = undefined;
            const to_read = @min(buffer.len, end - pos);
            if (to_read == 0) break;
            const read = try self.underlying_reader.read(buffer[0..to_read]);
            pos += read;
            crc2.update(buffer[0..read]);
        }
        if (crc2.final() != self.crc2) {
            return error.InvalidChecksum;
        }
    }

    pub fn validate(self: *@This()) ValidationError!void {
        try self.validateCrc1();
        try self.validateCrc2();
    }

    pub const Iterator = struct {
        index: u64,
        num_entries: u64,

        pub const Error = std.Io.Reader.Error || std.fs.File.SeekError;

        pub fn next(self: *@This(), reader: *Reader) Error!?IndexEntry {
            if (self.index >= self.num_entries) return null;
            defer self.index += 1;
            const start_offset = reader.index_offset + @sizeOf(u64);
            try reader.underlying_reader.seekTo(start_offset + self.index * @sizeOf(IndexEntry));
            return .{
                .path_offset = try reader.underlying_reader.interface.takeInt(u64, .little),
                .data_offset = try reader.underlying_reader.interface.takeInt(u64, .little),
                .data_length = try reader.underlying_reader.interface.takeInt(u64, .little),
                .data_mtime = try reader.underlying_reader.interface.takeInt(u64, .little),
            };
        }

        pub fn reset(self: *@This()) void {
            self.index = 0;
        }
    };

    const ReadError = std.fs.File.SeekError || std.Io.Reader.Error;

    pub fn iterator(self: *@This()) ReadError!Iterator {
        try self.underlying_reader.seekTo(self.index_offset);
        const num_entries = try self.underlying_reader.interface.takeInt(u64, .little);
        return .{ .index = 0, .num_entries = num_entries };
    }

    const ReadAllocError = error { OutOfMemory } || ReadError;

    pub fn readStringTableAlloc(self: *@This(), allocator: std.mem.Allocator) ReadAllocError![]const u8 {
        const length = self.index_offset - self.path_table_offset;
        try self.underlying_reader.seekTo(self.path_table_offset);
        return self.underlying_reader.interface.readAlloc(allocator, length);
    }

    pub fn entryReader(self: *@This(), entry: IndexEntry) ReadError!std.Io.Reader.Limited {
        try self.underlying_reader.seekTo(entry.data_offset);
        return self.underlying_reader.interface.limited(.limited64(entry.data_length), &.{});
    }
};

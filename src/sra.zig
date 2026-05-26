///! Very simple random access archive format with no compression.
///! Designed for fast random access.
///!
///! * All paths must be valid UTF8.
///! * All paths must be unique (no duplicates).
///! * Max path length is 65535 bytes.
///! * '/' is the path separator.
///! * May only contain absolute paths without leading '/'.
///! * '.' and '..' path components are not allowed.
///! * '/' character, control characters and whitespace other than the space are not allowed in path components.
///! * This means paths may not contain newlines, tabs, and such.
///! * In addition to be nice to Windows, following characters are not allowed: [<>:"/\|?*]
///! * Entry order in index depends on the implementation. This reference implementation preserves the insertion order.
///! * mtime since epoch (UTC) in milliseconds is stored for fast file modification checks (syncing / updating the archive)
///!
///! LITTLE-ENDIAN:
///!     SRA\0
///!     ... entry data ...
///!     compressed_header: [compressed_header_length]u8
///!     compressed_header_length: u64
///!     decompressed_header_length: u64
///!     crc: u32
///! decompressed_header:
///!     path_bytes_length: u64,
///!     entries_length: u64,
///!     path_bytes: [path_bytes_length]u8
///!     entries: [entries_length]entry
///! entry:
///!     path_offset: u48
///!     path_length: u16
///!     data_offset: u64
///!     data_length: u64
///!     data_mtime: u64
///!
///! data_offset is the absolute file offset
///! path_offset is relative offset to path_bytes
///!
///! crc is the checksum of the decompressed_header bytes.
///! compressed_header is compressed using flate compression.
///! Integrity of the entry data is not checked.
///! It is up to the reader to validate the integrity of the archive.
const std = @import("std");

pub const PathValidationError = error{InvalidPath};

pub fn validatePath(path: []const u8) PathValidationError!void {
    if (path.len == 0) return error.InvalidPath;
    if (path.len > std.math.maxInt(u16)) return error.InvalidPath;
    if (path[0] == '/') return error.InvalidPath;
    if (std.mem.indexOf(u8, path, "//")) |_| return error.InvalidPath;
    if (path[path.len - 1] == '/') return error.InvalidPath;
    if (std.mem.indexOfAny(u8, path, "<>:\"\\|?*")) |_| return error.InvalidPath;
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

pub const Magic = union(enum) {
    default,
    custom: []const u8,

    pub fn slice(self: @This()) []const u8 {
        return switch (self) {
            .default => "SRA\x00",
            .custom => |custom| custom,
        };
    }
};

pub const Path = packed struct(u64) {
    offset: u48,
    length: u16,

    const later: @This() = .{ .offset = 0, .length = 0 };

    pub fn slice(self: @This(), path_bytes: []const u8) []const u8 {
        return path_bytes[@intCast(self.offset)..][0..self.length];
    }

    pub const ValidationError = PathValidationError;

    pub fn validate(self: @This(), path_bytes: []const u8) ValidationError!void {
        if (self.offset + self.length > path_bytes.len) {
            return error.InvalidPath;
        }
        try validatePath(self.slice(path_bytes));
    }
};

pub const Entry = struct {
    path: Path,
    data_offset: u64,
    data_length: u64,
    data_mtime: u64,

    pub const ReaderError = std.Io.File.Reader.SeekError;

    pub fn dataReader(self: *const @This(), reader: *std.Io.File.Reader) ReaderError!std.Io.Reader.Limited {
        std.debug.assert(reader.mode == .positional);
        try reader.seekTo(self.data_offset);
        return reader.interface.limited(.limited64(self.data_length), &.{});
    }

    pub fn dataSlice(self: *const @This(), data_bytes: []const u8) []const u8 {
        return data_bytes[self.data_offset..][0..self.data_length];
    }

    pub const ValidationError = error{InvalidEntry};

    pub fn validate(self: *const @This(), reader: *const Reader) ValidationError!void {
        if (reader.magic_length > self.data_offset) {
            return error.InvalidEntry;
        }
        if (self.data_offset + self.data_length > reader.flate_offset) {
            return error.InvalidEntry;
        }
    }
};

pub const Writer = struct {
    arena: std.heap.ArenaAllocator,
    underlying_writer: *std.Io.Writer,
    dir_stack: std.ArrayList([]const u8),
    files: std.StringArrayHashMapUnmanaged(Entry),
    pos: u64,

    pub fn init(gpa: std.mem.Allocator, underlying_writer: *std.Io.Writer) @This() {
        return .{
            .arena = .init(gpa),
            .underlying_writer = underlying_writer,
            .dir_stack = .empty,
            .files = .empty,
            .pos = 0,
        };
    }

    pub fn writeMagic(self: *@This(), magic: Magic) !void {
        std.debug.assert(self.pos == 0);
        try self.underlying_writer.writeAll(magic.slice());
        self.pos = magic.slice().len;
    }

    pub const PushError = error{OutOfMemory} || PathValidationError;

    pub fn push(self: *@This(), sub_path: []const u8) PushError!bool {
        if (sub_path.len == 0) return false;
        try self.dir_stack.append(self.arena.allocator(), sub_path);
        return true;
    }

    pub fn pop(self: *@This()) void {
        _ = self.dir_stack.pop();
    }

    pub const WriteFileBytesError = error{FileAlreadyExists} || PushError || std.Io.Writer.Error;

    pub fn writeFileBytes(self: *@This(), sub_path: []const u8, bytes: []const u8, mtime: u64) WriteFileBytesError!void {
        std.debug.assert(self.pos > 0); // magic is not written
        std.debug.assert(try self.push(sub_path));
        defer self.pop();
        const path = try std.mem.join(self.arena.allocator(), "/", self.dir_stack.items);
        try validatePath(sub_path);
        const kv = try self.files.getOrPut(self.arena.allocator(), path);
        if (kv.found_existing) return error.FileAlreadyExists;
        try self.underlying_writer.writeAll(bytes);
        kv.value_ptr.* = .{ .data_offset = self.pos, .data_length = bytes.len, .data_mtime = mtime, .path = .later };
        self.pos += bytes.len;
    }

    pub const WriteFileError = error{FileAlreadyExists} || PushError || std.Io.Writer.Error || std.Io.Reader.Error;

    pub fn writeFileStream(self: *@This(), sub_path: []const u8, file_reader: *std.Io.Reader, mtime: u64) WriteFileError!void {
        std.debug.assert(self.pos > 0); // magic is not written
        std.debug.assert(try self.push(sub_path));
        defer self.pop();
        const path = try std.mem.join(self.arena.allocator(), "/", self.dir_stack.items);
        try validatePath(sub_path);
        const kv = try self.files.getOrPut(self.arena.allocator(), path);
        if (kv.found_existing) return error.FileAlreadyExists;
        const size = try file_reader.streamRemaining(self.underlying_writer);
        kv.value_ptr.* = .{ .data_offset = self.pos, .data_length = size, .data_mtime = mtime, .path = .later };
        self.pos += size;
    }

    pub fn writeFile(self: *@This(), sub_path: []const u8, file_reader: *std.Io.File.Reader, mtime: u64) WriteFileError!void {
        std.debug.assert(self.pos > 0); // magic is not written
        std.debug.assert(try self.push(sub_path));
        defer self.pop();
        const path = try std.mem.join(self.arena.allocator(), "/", self.dir_stack.items);
        try validatePath(sub_path);
        const kv = try self.files.getOrPut(self.arena.allocator(), path);
        if (kv.found_existing) return error.FileAlreadyExists;
        const size = try self.underlying_writer.sendFileAll(file_reader, .unlimited);
        kv.value_ptr.* = .{ .data_offset = self.pos, .data_length = size, .data_mtime = mtime, .path = .later };
        self.pos += size;
    }

    pub const WriteFilePathError = WriteFileError || std.Io.File.OpenError || std.Io.File.StatError;

    pub fn writeFilePath(self: *@This(), io: std.Io, sub_path: []const u8, dir: std.Io.Dir, file_path: []const u8, mtime: ?u64) WriteFilePathError!void {
        var file = try dir.openFile(io, file_path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        if (mtime) |ms| {
            try self.writeFile(sub_path, &reader, ms);
        } else {
            const st = try file.stat(io);
            try self.writeFile(sub_path, &reader, @intCast(@max(st.mtime.toMilliseconds(), 0)));
        }
    }

    pub const WriteDirError = error{InvalidFileType} || WriteFilePathError || std.Io.Dir.OpenError;

    pub fn writeDir(self: *@This(), scratch: std.mem.Allocator, io: std.Io, sub_path: []const u8, dir: std.Io.Dir) WriteDirError!void {
        var walker = try std.Io.Dir.walk(dir, scratch);
        defer walker.deinit();
        const did_push = try self.push(sub_path);
        defer if (did_push) self.pop();
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .directory => {},
                .file => try self.writeFilePath(entry.path, entry.dir, entry.basename, null),
                else => return error.InvalidFileType,
            }
        }
    }

    pub fn writeDirPath(self: *@This(), scratch: std.mem.Allocator, io: std.Io, sub_path: []const u8, dir: std.Io.Dir, dir_path: []const u8) WriteDirError!void {
        var sub_dir = try dir.openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false });
        defer sub_dir.close(io);
        try self.writeDir(scratch, sub_path, sub_dir);
    }

    pub const FinishError = std.Io.Writer.Error;

    /// Finishes the current archive.
    /// It is possible to swap the `underlying_writer` and start writing a new archive.
    /// Reusing StreamWriter reuses the underlying arena allocator.
    pub fn finish(self: *@This()) FinishError!void {
        const res = try self.writeCompressedHeader(self.underlying_writer);
        try self.underlying_writer.writeInt(u64, res.compressed_length, .little);
        try self.underlying_writer.writeInt(u64, res.decompressed_length, .little);
        try self.underlying_writer.writeInt(u32, res.crc, .little);
        try self.underlying_writer.flush();
        _ = self.arena.reset(.retain_capacity);
        self.dir_stack = .empty;
        self.files = .empty;
        self.pos = 0;
    }

    // this really should be part of the std
    fn drain_into(writer: *std.Io.Writer, data: []const []const u8, splat: usize, sink: anytype) std.Io.Writer.Error!usize {
        const max_buffers_len = 16;
        const buffered = writer.buffered();
        var iov: [max_buffers_len][]const u8 = undefined;
        var len: usize = 0;
        if (buffered.len > 0) {
            iov[len] = buffered;
            len += 1;
        }
        for (data[0 .. data.len - 1]) |d| {
            if (d.len == 0) continue;
            iov[len] = d;
            len += 1;
            if (iov.len - len == 0) break;
        }
        const pattern = data[data.len - 1];
        if (iov.len - len != 0) switch (splat) {
            0 => {},
            1 => if (pattern.len != 0) {
                iov[len] = pattern;
                len += 1;
            },
            else => switch (pattern.len) {
                0 => {},
                1 => {
                    const splat_buffer_candidate = writer.buffer[writer.end..];
                    var backup_buffer: [64]u8 = undefined;
                    const splat_buffer = if (splat_buffer_candidate.len >= backup_buffer.len)
                        splat_buffer_candidate
                    else
                        &backup_buffer;
                    const memset_len = @min(splat_buffer.len, splat);
                    const buf = splat_buffer[0..memset_len];
                    @memset(buf, pattern[0]);
                    iov[len] = buf;
                    len += 1;
                    var remaining_splat = splat - buf.len;
                    while (remaining_splat > splat_buffer.len and iov.len - len != 0) {
                        std.debug.assert(buf.len == splat_buffer.len);
                        iov[len] = splat_buffer;
                        len += 1;
                        remaining_splat -= splat_buffer.len;
                    }
                    if (remaining_splat > 0 and iov.len - len != 0) {
                        iov[len] = splat_buffer[0..remaining_splat];
                        len += 1;
                    }
                },
                else => for (0..splat) |_| {
                    iov[len] = pattern;
                    len += 1;
                    if (iov.len - len == 0) break;
                },
            },
        };
        if (len == 0) return 0;
        const written = sink.writev(iov[0..len]) catch return error.WriteFailed;
        return writer.consume(written);
    }

    const Counting = struct {
        written: u64,
        writer: std.Io.Writer,
        underlying_writer: *std.Io.Writer,

        pub fn init(underlying_writer: *std.Io.Writer, buffer: []u8) @This() {
            return .{
                .written = 0,
                .writer = .{
                    .buffer = buffer,
                    .vtable = &.{
                        .drain = drain,
                    },
                },
                .underlying_writer = underlying_writer,
            };
        }

        fn writev(self: *@This(), data: []const []const u8) !usize {
            const written = try self.underlying_writer.writeVec(data);
            self.written += written;
            return written;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", w);
            return drain_into(w, data, splat, self);
        }
    };

    fn writeCompressedHeader(self: *@This(), writer: *std.Io.Writer) !struct { crc: u32, decompressed_length: u64, compressed_length: u64 } {
        var counting_buffer: [16]u8 = undefined;
        // how nice it would be if compress apis gave compressed and uncompressed sizes .. :)
        var counting: Counting = .init(writer, &counting_buffer);
        var buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var flate: std.compress.flate.Compress = try .init(&counting.writer, &buffer, .raw, .default);
        // and how nice would it be if compress apis had hooks or custom hasher
        var crc: std.Io.Writer.Hashed(std.hash.Crc32) = .initHasher(&flate.writer, .init(), &.{});
        var path_bytes_length: u64 = 0;
        for (self.files.keys(), self.files.values()) |key, *entry| {
            entry.path.offset = @intCast(path_bytes_length);
            entry.path.length = @intCast(key.len);
            path_bytes_length += key.len;
        }
        try crc.writer.writeInt(u64, path_bytes_length, .little);
        try crc.writer.writeInt(u64, self.files.count(), .little);
        for (self.files.keys()) |key| try crc.writer.writeAll(key);
        for (self.files.values()) |entry| {
            try crc.writer.writeInt(u64, @bitCast(entry.path), .little);
            try crc.writer.writeInt(u64, entry.data_offset, .little);
            try crc.writer.writeInt(u64, entry.data_length, .little);
            try crc.writer.writeInt(u64, entry.data_mtime, .little);
        }
        try crc.writer.flush();
        try flate.finish();
        try counting.writer.flush();
        comptime std.debug.assert(@sizeOf(Entry) == 32);
        return .{
            .crc = crc.hasher.final(),
            .decompressed_length = 16 + path_bytes_length + self.files.count() * @sizeOf(Entry),
            .compressed_length = counting.written,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Reader = struct {
    underlying_reader: *std.Io.File.Reader,
    magic_length: u8,
    flate_offset: u64,
    flate_length: u64,
    header_length: u64,
    crc: u32,

    pub const InitError = error{InvalidArchive} || std.Io.Reader.Error || std.Io.File.Reader.SeekError;

    pub fn init(underlying_reader: *std.Io.File.Reader, magic: Magic) !@This() {
        std.debug.assert(underlying_reader.mode == .positional);
        var magic_buf: [16]u8 = undefined;
        try underlying_reader.seekTo(0);
        try underlying_reader.interface.readSliceAll(magic_buf[0..magic.slice().len]);
        if (!std.mem.eql(u8, magic_buf[0..magic.slice().len], magic.slice())) return error.InvalidArchive;
        const size = try underlying_reader.getSize();
        if (size - magic.slice().len < 20) return error.InvalidArchive;
        try underlying_reader.seekTo(size - 20);
        const flate_length = try underlying_reader.interface.takeInt(u64, .little);
        if (size - magic.slice().len - 20 < flate_length) return error.InvalidArchive;
        const header_length = try underlying_reader.interface.takeInt(u64, .little);
        const crc = try underlying_reader.interface.takeInt(u32, .little);
        return .{
            .underlying_reader = underlying_reader,
            .magic_length = @intCast(magic.slice().len),
            .flate_offset = size - 20 - flate_length,
            .flate_length = flate_length,
            .header_length = header_length,
            .crc = crc,
        };
    }

    pub const ValidationError = error{InvalidChecksum} || std.Io.Reader.Error || std.Io.File.Reader.SeekError;

    pub fn validateCrc(self: *@This()) ValidationError!void {
        var block: [16]u8 = undefined;
        var bytes_left = self.header_length;
        var hasher: std.hash.Crc32 = .init();
        var buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var flate = try self.flateReader(&buffer);
        while (bytes_left > 0) {
            const len = @min(block.len, bytes_left);
            try flate.reader.readSliceAll(block[0..len]);
            hasher.update(block[0..len]);
            bytes_left -= len;
        }
        if (self.crc != hasher.final()) return error.InvalidChecksum;
    }

    fn flateReader(self: *@This(), buffer: []u8) !std.compress.flate.Decompress {
        try self.underlying_reader.seekTo(self.flate_offset);
        return .init(&self.underlying_reader.interface, .raw, buffer);
    }

    const StreamError = std.Io.Reader.StreamError || std.Io.File.Reader.SeekError;

    pub fn streamPathBytes(self: *@This(), writer: *std.Io.Writer) StreamError!void {
        var buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var flate = try self.flateReader(&buffer);
        const path_bytes_length = try flate.reader.takeInt(u64, .little);
        try flate.reader.discardAll(8);
        try flate.reader.streamExact64(writer, path_bytes_length);
    }

    const AllocError = error{OutOfMemory} || StreamError;

    pub fn allocPathBytes(self: *@This(), allocator: std.mem.Allocator) AllocError![]const u8 {
        var allocating: std.Io.Writer.Allocating = .init(allocator);
        try self.streamPathBytes(&allocating.writer);
        return allocating.toOwnedSlice();
    }

    pub const Iterator = struct {
        index: u64,
        entries_length: u64,
        raw_offset: u64,
        buffer: [std.compress.flate.max_window_len]u8,
        flate: std.compress.flate.Decompress,

        pub const Error = std.Io.Reader.Error || std.Io.File.SeekError;

        fn init(reader: *Reader) Error!@This() {
            var buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var flate = try reader.flateReader(&buffer);
            const path_bytes_length = try flate.reader.takeInt(u64, .little);
            const entries_length = try flate.reader.takeInt(u64, .little);
            try flate.reader.discardAll64(path_bytes_length);
            return .{
                .index = 0,
                .entries_length = entries_length,
                .raw_offset = reader.underlying_reader.logicalPos(),
                .buffer = buffer,
                .flate = flate,
            };
        }

        pub fn next(self: *@This(), reader: *Reader) Error!?Entry {
            if (self.index >= self.entries_length) return null;
            defer self.index += 1;
            defer self.raw_offset = reader.underlying_reader.logicalPos();
            try reader.underlying_reader.seekTo(self.raw_offset);
            self.flate.reader.buffer = &self.buffer;
            return .{
                .path = @bitCast(try self.flate.reader.takeInt(u64, .little)),
                .data_offset = try self.flate.reader.takeInt(u64, .little),
                .data_length = try self.flate.reader.takeInt(u64, .little),
                .data_mtime = try self.flate.reader.takeInt(u64, .little),
            };
        }

        pub fn reset(self: *@This(), reader: *Reader) Error!void {
            self.* = try .init(reader);
        }
    };

    pub fn iterator(self: *@This()) Iterator.Error!Iterator {
        return .init(self);
    }
};

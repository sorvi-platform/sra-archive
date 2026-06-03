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

// zlinter-disable-next-line require_doc_comment
pub const PathValidationError = error{
    /// Path does not follow the SRA path spec
    InvalidPath,
};

/// Validates that the path follows the SRA's path spec
pub fn validatePath(path: []const u8) PathValidationError!void {
    if (path.len == 0) return error.InvalidPath;
    if (path.len > std.math.maxInt(u16)) return error.InvalidPath;
    if (path[0] == '/') return error.InvalidPath;
    if (std.mem.find(u8, path, "//")) |_| return error.InvalidPath;
    if (path[path.len - 1] == '/') return error.InvalidPath;
    if (std.mem.findAny(u8, path, "<>:\"\\|?*")) |_| return error.InvalidPath;
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

/// Describes the starting bytes that identify the archive
pub const Magic = union(enum) {
    /// Assume default magic bytes `SRA\x00`
    default,
    /// Assume custom magic bytes
    custom: []const u8,

    /// Returns the expected starting bytes as a slice
    pub fn slice(self: @This()) []const u8 {
        return switch (self) {
            .default => "SRA\x00",
            .custom => |custom| custom,
        };
    }
};

/// Describes a path inside the archive
pub const Path = packed struct(u64) {
    /// Offset starting from the path bytes
    offset: u48,
    /// Length of the path starting from the offset
    length: u16,

    const later: @This() = .{ .offset = 0, .length = 0 };

    /// Given the `path_bytes` returns the path as UTF8 encoded slice
    pub fn slice(self: @This(), path_bytes: []const u8) []const u8 {
        return path_bytes[@intCast(self.offset)..][0..self.length];
    }

    // zlinter-disable-next-line require_doc_comment
    pub const ValidationError = PathValidationError;

    /// Given the `path_bytes` validates the contraints of the path within the archive
    /// If the path does not pass validation, it is unsafe to access
    pub fn validate(self: @This(), path_bytes: []const u8) ValidationError!void {
        if (self.offset + self.length > path_bytes.len) {
            return error.InvalidPath;
        }
        try validatePath(self.slice(path_bytes));
    }
};

/// Describes a file entry inside the archive
pub const Entry = struct {
    /// Full path of the entry
    path: Path,
    /// Absolute offset inside the archive
    data_offset: u64,
    /// Length of the data starting from the offset
    data_length: u64,
    /// Modification time of the entry since epoch (UTC), milliseconds
    data_mtime: u64,

    // zlinter-disable-next-line require_doc_comment
    pub const ReaderError = std.Io.File.Reader.SeekError;

    /// Given the `reader` returns `std.Io.Reader.Limited` for the entry data
    pub fn dataReader(self: *const @This(), reader: *std.Io.File.Reader) ReaderError!std.Io.Reader.Limited {
        std.debug.assert(reader.mode == .positional);
        try reader.seekTo(self.data_offset);
        return reader.interface.limited(.limited64(self.data_length), &.{});
    }

    /// Given `data_bytes` returns bytes as a slice for the entry data
    pub fn dataSlice(self: *const @This(), data_bytes: []const u8) []const u8 {
        return data_bytes[self.data_offset..][0..self.data_length];
    }

    /// InvalidEntry: The entry data is corrupted and cannot be trusted
    pub const ValidationError = error{InvalidEntry};

    /// Validates the constraints of the entry data within the archive
    /// If the entry data does not pass validation, it is unsafe to access
    pub fn validate(self: *const @This(), reader: *const Reader) ValidationError!void {
        if (reader.magic_length > self.data_offset) {
            return error.InvalidEntry;
        }
        if (self.data_offset + self.data_length > reader.flate_offset) {
            return error.InvalidEntry;
        }
    }
};

/// Reusable writer for writing archives
pub const Writer = struct {
    arena: std.heap.ArenaAllocator,
    underlying_writer: *std.Io.Writer,
    dir_stack: std.ArrayList([]const u8),
    files: std.array_hash_map.String(Entry),
    pos: u64,

    /// Initializes the writer
    /// Provide `underlying_writer` where the bytes will be written to
    pub fn init(gpa: std.mem.Allocator, underlying_writer: *std.Io.Writer) @This() {
        return .{
            .arena = .init(gpa),
            .underlying_writer = underlying_writer,
            .dir_stack = .empty,
            .files = .empty,
            .pos = 0,
        };
    }

    /// Write magic header to the archive file
    /// This must be called before writing anything else
    pub fn writeMagic(self: *@This(), magic: Magic) std.Io.Writer.Error!void {
        std.debug.assert(self.pos == 0);
        try self.underlying_writer.writeAll(magic.slice());
        self.pos = magic.slice().len;
    }

    // zlinter-disable-next-line require_doc_comment
    pub const PushError = error{
        /// The allocator failed to allocate memory
        OutOfMemory,
    } || PathValidationError;

    /// Pushes a new path to the directory stack
    /// New files will be written under the full path constructed from the stack
    pub fn push(self: *@This(), sub_path: []const u8) PushError!bool {
        if (sub_path.len == 0) return false;
        try self.dir_stack.append(self.arena.allocator(), sub_path);
        return true;
    }

    /// Pops a path from the directory stack
    pub fn pop(self: *@This()) void {
        _ = self.dir_stack.pop();
    }

    // zlinter-disable-next-line require_doc_comment
    pub const WriteFileBytesError = error{
        /// File already exists in the archive
        FileAlreadyExists,
    } || PushError || std.Io.Writer.Error;

    /// Writes `bytes` into the archive as a file located in the `sub_path` of current directory stack
    /// `mtime` is the modification time of the data since epoch (UTC), milliseconds
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

    // zlinter-disable-next-line require_doc_comment
    pub const WriteFileError = WriteFileBytesError || std.Io.Reader.Error;

    /// Writes remaining bytes from the `reader` into the archive as a file located in the `sub_path` of current directory stack
    /// `mtime` is the modification time of the data since epoch (UTC), milliseconds
    pub fn writeFileStream(self: *@This(), sub_path: []const u8, reader: *std.Io.Reader, mtime: u64) WriteFileError!void {
        std.debug.assert(self.pos > 0); // magic is not written
        std.debug.assert(try self.push(sub_path));
        defer self.pop();
        const path = try std.mem.join(self.arena.allocator(), "/", self.dir_stack.items);
        try validatePath(sub_path);
        const kv = try self.files.getOrPut(self.arena.allocator(), path);
        if (kv.found_existing) return error.FileAlreadyExists;
        const size = try reader.streamRemaining(self.underlying_writer);
        kv.value_ptr.* = .{ .data_offset = self.pos, .data_length = size, .data_mtime = mtime, .path = .later };
        self.pos += size;
    }

    /// Writes remaining bytes from the `file_reader` into the archive as a file located in the `sub_path` of current directory stack
    /// `mtime` is the modification time of the data since epoch (UTC), milliseconds
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

    // zlinter-disable-next-line require_doc_comment
    pub const WriteFilePathError = WriteFileError || std.Io.File.OpenError || std.Io.File.StatError;

    /// Writes file from the `file_path` relative to `dir` into the archive as a file located in the `sub_path` of current directory stack
    /// `mtime` is the modification time of the data since epoch (UTC), milliseconds
    /// If `mtime` is null, it is determined from the file itself
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

    // zlinter-disable-next-line require_doc_comment
    pub const WriteDirError = error{
        /// File has a type that is not supported by the SRA spec
        InvalidFileType,
    } || WriteFilePathError || std.Io.Dir.OpenError;

    /// Walks the directory `dir` and writes the containing hierarchy recursively into the archive mimicing the path structure
    /// The initial directory for the hierarchy will be `sub_path` of current directory stack
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

    /// Walks the directory `dir_path` relative to `dir` and writes teh containing hierarchy recursively into the archive mimicng the path structure
    /// The initial directory for the hierarchy will be `sub_path` of current directory stack
    pub fn writeDirPath(self: *@This(), scratch: std.mem.Allocator, io: std.Io, sub_path: []const u8, dir: std.Io.Dir, dir_path: []const u8) WriteDirError!void {
        var sub_dir = try dir.openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false });
        defer sub_dir.close(io);
        try self.writeDir(scratch, sub_path, sub_dir);
    }

    // zlinter-disable-next-line require_doc_comment
    pub const FinishError = std.Io.Writer.Error;

    /// Finishes the current archive
    /// It is possible to swap the `underlying_writer` and start writing a new archive
    /// Reusing StreamWriter reuses the underlying arena allocator
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
    fn drainInto(writer: *std.Io.Writer, data: []const []const u8, splat: usize, sink: anytype) std.Io.Writer.Error!usize {
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

        fn init(underlying_writer: *std.Io.Writer, buffer: []u8) @This() {
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
            return drainInto(w, data, splat, self);
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

    /// Releases the reserved memory
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Seeking reader for archives
pub const Reader = struct {
    underlying_reader: *std.Io.File.Reader,
    magic_length: u8,
    flate_offset: u64,
    flate_length: u64,
    header_length: u64,
    crc: u32,

    // zlinter-disable-next-line require_doc_comment
    pub const InitError = error{
        /// Not a valid SRA archive
        InvalidArchive,
    } || std.Io.Reader.Error || std.Io.File.Reader.SeekError;

    /// Initializes the reader
    /// Provide seekable `underlying_reader` from where the bytes will be read from
    /// Failing to contain the `magic` as starting bytes causes `error.InvalidArchive` to be returned
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

    // zlinter-disable-next-line require_doc_comment
    pub const ValidationError = error{
        /// The archive is corrupted
        InvalidChecksum,
    } || std.Io.Reader.Error || std.Io.File.Reader.SeekError;

    /// Validates the crc checksum of the archive
    /// If the validation fails the integrity of the archive index is not guaranteed
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

    // zlinter-disable-next-line require_doc_comment
    const StreamError = std.Io.Reader.StreamError || std.Io.File.Reader.SeekError;

    /// Stream the path bytes from the archive into the given `writer`
    pub fn streamPathBytes(self: *@This(), writer: *std.Io.Writer) StreamError!void {
        var buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var flate = try self.flateReader(&buffer);
        const path_bytes_length = try flate.reader.takeInt(u64, .little);
        try flate.reader.discardAll(8);
        try flate.reader.streamExact64(writer, path_bytes_length);
    }

    // zlinter-disable-next-line require_doc_comment
    const AllocError = error{
        /// The allocator failed to allocate memory
        OutOfMemory,
    } || StreamError;

    /// Return the path bytes from the archive as a owned slice
    pub fn allocPathBytes(self: *@This(), allocator: std.mem.Allocator) AllocError![]const u8 {
        var allocating: std.Io.Writer.Allocating = .init(allocator);
        errdefer allocating.deinit();
        try self.streamPathBytes(&allocating.writer);
        return allocating.toOwnedSlice();
    }

    /// Iterates the entries inside the archive
    /// The iterator tracks the seek position, so it is safe to use this even if `reader`'s seek position has changed
    pub const Iterator = struct {
        index: u64,
        entries_length: u64,
        raw_offset: u64,
        buffer: [std.compress.flate.max_window_len]u8,
        flate: std.compress.flate.Decompress,

        // zlinter-disable-next-line require_doc_comment
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

        /// Returns the next entry from the given archive `reader`
        /// If there is no next entry a `null` is returned instead
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

        /// Resets the iterator so it starts iterating entries from the beginning
        pub fn reset(self: *@This(), reader: *Reader) Error!void {
            self.* = try .init(reader);
        }
    };

    /// Returns entry iterator for the archive
    pub fn iterator(self: *@This()) Iterator.Error!Iterator {
        return .init(self);
    }
};

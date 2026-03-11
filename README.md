```zig
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
```

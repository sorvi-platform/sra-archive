```zig
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
///! * Entry order in index depends on the implementation. This reference implementation preserves the insertion order.
///! * mtime since epoch (UTC) in milliseconds is stored for fast file modification checks (syncing / updating the archive)
///!
///! LITTLE-ENDIAN:
///!     SRA\0
///!     crc1: u32
///!     crc2: u32
///!     index_offset: u64
///!     path_table_offset: u64
///!     ... file data ...
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
```

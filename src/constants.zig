const std = @import("std");
const expect = std.testing.expect;

pub const MAGIC = [_]u8{0x6b, 0x6d, 0x73, 0x74};

pub const MAJOR_VERSION: u8 = 0;
pub const MINOR_VERSION: u8 = 0;
pub const PATCH_VERSION: u8 = 0;

pub const FANOUT_THRESHHOLD: u8 = 0x16;

pub const TOMBSTONE: u16 = 0xffff;

pub const LEAF_SIZE: comptime_int = 40;
pub const NODE_SIZE: comptime_int = 48;

pub const PAGE_SIZE: comptime_int = 4096;
pub const PAGE_CONTENT_SIZE: comptime_int = 4080;
pub const PAGE_LEAF_CAPACITY: comptime_int = 102;
pub const PAGE_NODE_CAPACITY: comptime_int = 85;
pub const TOMBSTONE_CAPACITY: comptime_int = 496;
// pub const PAGE_SIZE: comptime_int = 256;
// pub const PAGE_CONTENT_SIZE: comptime_int = 240;
// pub const PAGE_LEAF_CAPACITY: comptime_int = 6;
// pub const PAGE_NODE_CAPACITY: comptime_int = 5;
// pub const TOMBSTONE_CAPACITY: comptime_int = 48;

pub const ZERO_HASH = [_]u8{
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

pub const DEFAULT_MEMORY_STORE_PAGE_LIMIT: u32 = 2048;

test "validate content alignment" {
  comptime {
    try expect(PAGE_LEAF_CAPACITY * LEAF_SIZE == PAGE_CONTENT_SIZE);
    try expect(PAGE_NODE_CAPACITY * NODE_SIZE == PAGE_CONTENT_SIZE);
  }
}


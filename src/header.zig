const std = @import("std");
const expect = std.testing.expect;

const constants = @import("./constants.zig");

pub const Header = packed struct {
  magic: [4]u8,
  major_version: u8,
  minor_version: u8,
  patch_version: u8,
  fanout_threshhold: u8,
  root_id_bytes: [4]u8,
  root_hash: [32]u8,
  page_count_bytes: [4]u8,
  height_bytes: [4]u8,
  leaf_count_bytes: [8]u8,
  tombstone_count_bytes: [4]u8,
  tombstones: [constants.TOMBSTONE_CAPACITY][4]u8,
  // padding: [2048]u8,

  pub fn init(self: *Header, fanout_threshhold: u8) void {
    self.magic = constants.MAGIC;
    self.major_version = constants.MAJOR_VERSION;
    self.minor_version = constants.MINOR_VERSION;
    self.patch_version = constants.PATCH_VERSION;
    self.fanout_threshhold = fanout_threshhold;
    self.set_root_id(1);
    self.set_leaf_count(1);
    self.set_page_count(1);
    self.set_height(1);
    self.set_tombstone_count(0);
  }

  pub fn get_root_id(self: *const Header) u32 {
    return std.mem.readIntLittle(u32, &self.root_id_bytes);
  }

  pub fn set_root_id(self: *Header, root_id: u32) void {
    std.mem.writeIntLittle(u32, &self.root_id_bytes, root_id);
  }

  pub fn get_page_count(self: *const Header) u32 {
    return std.mem.readIntLittle(u32, &self.page_count_bytes);
  }

  pub fn set_page_count(self: *Header, page_count: u32) void {
    std.mem.writeIntLittle(u32, &self.page_count_bytes, page_count);
  }

  pub fn get_height(self: *const Header) u32 {
    return std.mem.readIntLittle(u32, &self.height_bytes);
  }

  pub fn set_height(self: *Header, height: u32) void {
    std.mem.writeIntLittle(u32, &self.height_bytes, height);
  }

  pub fn get_leaf_count(self: *const Header) u64 {
    return std.mem.readIntLittle(u64, &self.leaf_count_bytes);
  }

  pub fn set_leaf_count(self: *Header, leaf_count: u64) void {
    std.mem.writeIntLittle(u64, &self.leaf_count_bytes, leaf_count);
  }

  pub fn get_tombstone_count(self: *const Header) u32 {
    return std.mem.readIntLittle(u32, &self.tombstone_count_bytes);
  }

  pub fn set_tombstone_count(self: *Header, tombstone_count: u32) void {
    std.mem.writeIntLittle(u32, &self.tombstone_count_bytes, tombstone_count);
  }

  pub fn get_tombstone(self: *Header) u32 {
    const count = self.get_tombstone_count();
    if (count > 0) {
      const index = count - 1;
      const id = std.mem.readIntLittle(u32, &self.tombstones[index]);
      self.set_tombstone_count(index);
      return id;
    } else {
      return 0;
    }
  }
};

test "validate header size" {
  comptime {
    try expect(@sizeOf(Header) == constants.PAGE_SIZE);
  }
}
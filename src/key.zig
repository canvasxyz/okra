const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;

const constants = @import("./constants.zig");

pub fn Key(comptime X: usize) type {
  return packed struct {
    pub const SIZE: comptime_int = 2 + X;
    var printBuffer: [4+1+(2*X)]u8 = undefined;

    bytes: [SIZE]u8,

    pub fn create(level: u16, data: ?*const [X]u8) Key(X) {
      var key = @bitCast(Key(X), [_]u8{0} ** (2 + X));
      key.setLevel(level);

      if (data) |bytes| {
        std.mem.copy(u8, key.bytes[2..2+X], bytes);
      } else {
        std.mem.set(u8, key.bytes[2..2+X], 0);
      }
      return key;
    }

    pub fn getLevel(self: *const Key(X)) u16 {
      return std.mem.readIntBig(u16, self.bytes[0..2]);
    }

    pub fn setLevel(self: *Key(X), level: u16) void {
      std.mem.writeIntBig(u16, self.bytes[0..2], level);
    }

    pub fn getData(self: *const Key(X)) *const [X]u8 {
      return self.bytes[2..2+X];
    }

    pub fn setData(self: *Key(X), data: ?*const [X]u8) void {
      if (data) |ptr| {
        std.mem.copy(u8, self.bytes[2..2+X], ptr);
      } else {
        std.mem.set(u8, self.bytes[2..2+X], 0);
      }
    }
  
    pub fn isLeftEdge(self: *const Key(X)) bool {
      for (self.getData()) |byte| {
        if (byte != 0) return false;
      }

      return true;
    }

    pub fn toString(self: *const Key(X)) ![]u8 {
      return std.fmt.bufPrint(&printBuffer, "{x}:{x}", .{
        std.fmt.fmtSliceHexLower(self.bytes[0..2]),
        std.fmt.fmtSliceHexLower(self.getData()),
      });
    }

    pub fn getChild(self: *const Key(X)) Key(X) {
      const level = self.getLevel();
      assert(level > 0);
      return Key(X).create(level - 1, self.getData());
    }

    pub fn getParent(self: *const Key(X)) Key(X) {
      const level = self.getLevel();
      return Key(X).create(level + 1, self.getData());
    }

    pub fn clone(self: *const Key(X)) Key(X) {
      const level = self.getLevel();
      return Key(X).create(level, self.getData());
    }

    pub fn equals(self: *const Key(X), target: *const Key(X)) bool {
      return std.mem.eql(u8, self.bytes[2..SIZE], target.bytes[2..SIZE]);
    }

    pub fn lessThan(self: *const Key(X), target: *const Key(X)) bool {
      return std.mem.lessThan(u8, self.bytes[2..SIZE], target.bytes[2..SIZE]);
    }
  };
}

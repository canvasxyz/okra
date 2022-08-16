const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;

const constants = @import("./constants.zig");

pub fn isValueSplit(value: []const u8) bool {
  return value[0] < constants.FANOUT;
}

var printHashBuffer: [64]u8 = undefined;

pub fn printHash(hash: []const u8) ![]u8 {
  assert(hash.len == 32);
  return std.fmt.bufPrint(&printHashBuffer, "{x}", .{ std.fmt.fmtSliceHexLower(hash) });
}

test "test print_hash" {
  const emptyHash = [_]u8{
    0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
    0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
    0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
    0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
  };

  const result = try printHash(&emptyHash);
  try expect(std.mem.eql(u8, result, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
}

pub fn parseHash(input: []const u8) ![32]u8 {
  assert(input.len == 64);

  var result: [32]u8 = constants.ZERO_HASH;
  _ = try std.fmt.hexToBytes(&result, input);
  return result;
}

test "test parsing hashes" {
  const emptyHash = [_]u8{
    0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
    0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
    0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
    0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
  };

  const bytes = try parseHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  try expect(std.mem.eql(u8, bytes[0..32], emptyHash[0..32]));
}

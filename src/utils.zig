const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;

const constants = @import("./constants.zig");

// e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
const empty_hash = [_]u8{
  0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
  0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
  0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
  0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
};

var print_hash_buffer: [64]u8 = undefined;

pub fn print_hash(hash: []const u8) ![]u8 {
  const formatter = std.fmt.fmtSliceHexLower(hash);
  return std.fmt.bufPrint(print_hash_buffer[0..(hash.len * 2)], "{x}", .{ formatter });
}

test "test print_hash" {
  const result = try print_hash(&empty_hash);
  try expect(std.mem.eql(u8, result, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
}

pub fn parse_hash(input: []const u8) ![32]u8 {
  assert(input.len <= 64);
  assert(input.len % 2 == 0);

  var result: [32]u8 = constants.ZERO_HASH;
  _ = try std.fmt.hexToBytes(result[(32-input.len/2)..32], input);
  return result;
}

test "test parsing hashes" {
  const bytes = try parse_hash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  try expect(std.mem.eql(u8, bytes[0..32], empty_hash[0..32]));
}

pub fn swap(comptime T: type, a: []T, b: []T) void {
  assert(a.len == b.len);
  for (a) |av, i| {
    const bv = b[i];
    b[i] = av;
    a[i] = bv;
  }
}

test "test swap" {
  var a = [_]u8{1, 2, 3, 4};
  var b = [_]u8{5, 6, 7, 8};
  swap(u8, &a, &b);
  try expect(std.mem.eql(u8, &a, &[_]u8{5, 6, 7, 8}));
  try expect(std.mem.eql(u8, &b, &[_]u8{1, 2, 3, 4}));
}

// fn shift(
//   comptime T: type,
//   comptime capacity: u8,
//   dst: *[capacity]T,
//   dst_len: u8,
//   src: *[capacity]T,
//   src_len: u8,
// ) u8 {
//   if (dst_len + src_len <= capacity) {
//     std.mem.copyBackwards(T, dst[src_len..src_len+dst_len], dst[0..dst_len]);
//     std.mem.copy(T, dst[0..src_len], src[0..src_len]);
//     return 0;
//   }
  
//   if (dst_len > src_len) {
//     swap(T, src[0..dst_len], dst[0..dst_len]);
//   } else {
//     swap(T, src[0..src_len], dst[0..src_len]);
//   }

//   const remaining_capacity = capacity - src_len;
//   std.mem.copy(T, dst[src_len..src_len+remaining_capacity], src[0..remaining_capacity]);
//   std.mem.copy(T, src[0..dst_len-remaining_capacity], src[remaining_capacity..dst_len]);

//   return dst_len - remaining_capacity;
// }

// fn splice2(
//   comptime T: type,
//   comptime capacity: u8,
//   dst: *[capacity]T,
//   dst_len: u8,
//   index: u8, 
//   src: *[capacity]T,
//   src_len: u8,
// ) u8 {
//   assert(index < dst_len);
//   assert(dst_len <= capacity);
//   assert(src_len <= capacity);
// }

// fn splice(
//   comptime T: type,
//   comptime capacity: u8,
//   content: *[capacity]T,
//   count: u8,
//   index: u8,
//   values: []const T,
//   buffer: *[capacity]T,
// ) u8 {
//   assert(index < count);
//   assert(values.len <= capacity);

//   const values_len = @intCast(u8, values.len);

//   if (index + values_len > capacity) {
//     // CASE 1 ---
//     // the values slice itself will overflow the original page, so
//     // we actually have to start the buffer with that part of the values slice.
//     // Example: capacity = 8, count = 7, index = 5, values.len = 5
  
//     const overflow_length = index + values_len - capacity;
//     const overflow_start = capacity - index;
//     const overflow_end = values_len;
//     std.mem.copy(T, buffer[0..overflow_length], values[overflow_start..overflow_end]);

//     // copy the actual page content tail to the buffer
//     const dst_start = overflow_length;
//     const dst_end = overflow_length + (count - index);
//     const src_start = index;
//     const src_end = count;
//     std.mem.copy(T, buffer[dst_start..dst_end], content[src_start..src_end]);

//     // write the part of the values that fits into the original page
//     std.mem.copy(T, content[index..capacity], values[0..overflow_start]);

//     return dst_end;
//   } else if (count + values_len > capacity) {
//     // CASE 2 ---
//     // here just the existing tail overflows, so we actually want to copy the overflow
//     // into the beginning of the buffer, then use copyBackwards to shift the tail down,
//     // and then write the values slice.
//     // Example: capacity = 8, count = 7, index = 2, values.len = 3

//     const overflow_length = count + values_len - capacity; // 2
//     const overflow_start = capacity - values_len; // 5
//     const overflow_end = count;
//     std.mem.copy(T, buffer[0..overflow_length], content[overflow_start..overflow_end]);

//     const dst_start = index + values_len;
//     const dst_end = capacity;
//     const src_start = index;
//     const src_end = overflow_start;
//     std.mem.copyBackwards(T, content[dst_start..dst_end], content[src_start..src_end]);
  
//     std.mem.copy(T, content[index..dst_start], values);

//     return overflow_length;
//   } else {
//     // CASE 3 ---
//     // everything fits in the existing page!
//     // Example: capacity = 8, count = 5, index = 2, values.len = 2
//     std.mem.copyBackwards(T, content[(index + values_len)..(count + values_len)], content[index..count]);
//     std.mem.copy(T, content[index..(index + values_len)], values);
//     return 0;
//   }
// }


// test "test splice logic: case 1" {
//   const count = 7;
//   const index = 5;
//   var values_len: u8 = 5;

//   var content = [_]u8{1, 2, 3, 4, 5, 6, 7, 0 };
//   var buffer = [_]u8{0, 0, 0, 0, 0, 0, 0, 0 };
//   const values = [_]u8{0xA, 0xB, 0xC, 0xD, 0xE};
  
//   const buffer_length = splice(u8, 8, &content, count, index, values[0..values_len], &buffer);
//   try expect(buffer_length == 4);
//   try expect(std.mem.eql(u8, buffer[0..4], &[_]u8{0xD, 0xE, 6, 7}));
//   try expect(std.mem.eql(u8, content[0..8], &[_]u8{1, 2, 3, 4, 5, 0xA, 0xB, 0xC}));
// }

// test "test splice logic: case 2" {
//   const count = 7;
//   const index = 2;
//   var values_len: u8 = 3;

//   var content = [_]u8{1, 2, 3, 4, 5, 6, 7, 0 };
//   var buffer = [_]u8{0, 0, 0, 0, 0, 0, 0, 0 };
//   const values = [_]u8{0xA, 0xB, 0xC};
  
//   const buffer_length = splice(u8, 8, &content, count, index, values[0..values_len], &buffer);
//   try expect(buffer_length == 2);
//   try expect(std.mem.eql(u8, buffer[0..2], &[_]u8{6, 7}));
//   try expect(std.mem.eql(u8, content[0..8], &[_]u8{1, 2, 0xA, 0xB, 0xC, 3, 4, 5}));
// }

// test "test splice logic: case 3" {
//   const count = 5;
//   const index = 2;
//   var values_len: u8 = 2;

//   var content = [_]u8{1, 2, 3, 4, 5, 0, 0, 0 };
//   var buffer = [_]u8{0, 0, 0, 0, 0, 0, 0, 0 };
//   const values = [_]u8{0xA, 0xB};
  
//   const buffer_length = splice(u8, 8, &content, count, index, values[0..values_len], &buffer);
//   try expect(buffer_length == 0);
//   try expect(std.mem.eql(u8, content[0..8], &[_]u8{1, 2, 0xA, 0xB, 3, 4, 5, 0}));
// }
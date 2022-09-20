const std = @import("std");

pub fn Node(comptime X: usize) type {
  return struct {
    const V = 32;
    leaf: [X]u8,
    hash: [V]u8,
  };
}
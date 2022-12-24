const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const lmdb = @import("lmdb");
const constants = @import("constants.zig");
const utils = @import("utils.zig");

const Error = error{
    InvalidDatabase,
};

const Node = struct {
    key: []const u8,
    hash: *const [32]u8,
};

// fn getChildren(level: u8, key: []const u8, hash: ?*[32]u8, allocator: std.mem.Allocator) std.ArrayList([]const u8) {
//     assert(level > 0);
// }

// Option A:
// - Iterator { next() -> Entry; previous() -> Entry; seek(key) -> Entry }
// - Source { getChildren(level, key) -> []Node }
// - Target { seek(level, key) -> ?Node }

// Option B:
// - Iterator { next() -> Entry; previous() -> Entry; seek(key) -> Entry }
// - Transaction { getChildren() }

// fn SkipListCursor(comptime Transaction: type, comptime getHash: fn (key: []const u8, value: []const u8, hash: *[32]u8) Error!void) type {
//     return struct {
//         const Self = @This();

//         cursor: lmdb.Cursor,
//         key: std.ArrayList(u8),

//         pub fn open(allocator: std.mem.Allocator, txn: *const Transaction) !Self {
//             var cursor: Self = undefined;
//             cursor.init(allocator, txn);
//             return cursor;
//         }

//         pub fn init(self: *Self, allocator: std.mem.Allocator, txn: *const Transaction) !void {
//             self.cursor = try lmdb.Cursor.open(txn.txn);
//             self.key = std.ArrayList(u8).init(allocator);
//         }

//         pub fn close(self: *Self) void {
//             self.key.deinit();
//             self.cursor.close();
//         }

//         pub fn seek(self: *Self, level: u8, key: []const u8) !void {
//             try self.key.resize(1 + bytes.len);
//             self.key.items[0] = level;
//             std.mem.copy(u8, self.key.items[1..], bytes);
//             try self.cursor.seek(self.key.items);
//         }

//         pub fn goToNode(self: *Self, level: u8, key: ?[]const u8) !void {
//             if (key) |bytes| {
//                 try self.key.resize(1 + bytes.len);
//                 self.key.items[0] = level;
//                 std.mem.copy(u8, self.key.items[1..], bytes);
//             } else {
//                 try self.key.resize(1);
//                 self.key.items[0] = level;
//             }

//             try self.cursor.goToKey(self.key.items);
//         }

//         pub fn goToNext(self: *Self) !?[]const u8 {
//             if (self.key.items.len == 0) {
//                 return error.KeyNotFound;
//             }

//             if (try self.cursor.goToNext()) |bytes| {
//                 if (bytes.len == 0 or bytes[0] != self.key.items[0]) {
//                     try self.cursor.goToKey(self.key.items);
//                     return null;
//                 }

//                 try self.key.resize(bytes.len + 1);
//                 std.mem.copy(u8, self.key.items[1..], bytes);
//                 return self.key.items[1..];
//             } else {
//                 return null;
//             }
//         }

//         pub fn goToPrevious(self: *Self) !?[]const u8 {
//             if (self.key.items.len == 0) {
//                 return error.KeyNotFound;
//             }

//             if (try self.cursor.goToNext()) |bytes| {
//                 if (bytes.len == 0 or bytes[0] != self.key.items[0]) {
//                     try self.cursor.goToKey(self.key.items);
//                     return null;
//                 }

//                 try self.key.resize(bytes.len + 1);
//                 std.mem.copy(u8, self.key.items[1..], bytes);
//                 return self.key.items[1..];
//             } else {
//                 return null;
//             }
//         }

//         pub fn getCurrentHash(self: *Self, hash: *[32]u8) !void {
//             if (self.key.items.len == 0 || std.mem.eql(u8, self.key.items, &constants.METADATA_KEY)) {
//                 return error.KeyNotFound;
//             }

//             const value = try self.cursor.getCurrentValue();
//             if (self.key.items[0] > 0) {
//                 if (value.len != 32) {
//                     return error.InvalidDatabase;
//                 }

//                 std.mem.copy(u8, hash, value);
//             } else {
//                 getHash(self.key.items[1..], value, hash);
//             }
//         }
//     };
// }

fn getSetHash(key: []const u8, _: []const u8, hash: *[32]u8) Error!void {
    if (key.len != 32) {
        return Error.InvalidDatabase;
    }

    std.mem.copy(u8, hash, key);
}

fn getMapHash(_: []const u8, value: []const u8, hash: *[32]u8) Error!void {
    if (value.len < 32) {
        return Error.InvalidDatabase;
    }

    std.mem.copy(u8, hash, value[0..32]);
}

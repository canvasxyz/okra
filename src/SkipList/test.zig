const std = @import("std");
const expect = std.testing.expect;

const lmdb = @import("lmdb");

const Builder = @import("./Builder.zig").Builder;
const SkipList = @import("./SkipList.zig").SkipList;
const SkipListCursor = @import("./SkipListCursor.zig").SkipListCursor;

const allocator = std.heap.c_allocator;

test "initialize SkipList" {
    try expect(true);
    
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n", .{});
    
    var tmp = std.testing.tmpDir(.{});
    const reference_path = try utils.resolvePath(allocator, tmp.dir, "reference.mdb");
    defer allocator.free(reference_path);
}
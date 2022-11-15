const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Environment = @import("./environment.zig").Environment;
const Transaction = @import("./transaction.zig").Transaction;
const Cursor = @import("./cursor.zig").Cursor;

const Options = struct {
    log: ?std.fs.File.Writer = null,
};

pub fn compareEntries(env_a: Environment, env_b: Environment, options: Options) !usize {
    if (options.log) |log| try log.print("{s:-<80}\n", .{ "START DIFF " });

    var differences: usize = 0;

    var txn_a = try Transaction.open(env_a, true);
    var txn_b = try Transaction.open(env_b, true);
    var cursor_a = try Cursor.open(txn_a);
    var cursor_b = try Cursor.open(txn_b);

    var key_a = try cursor_a.goToFirst();
    var key_b = try cursor_b.goToFirst();
    while (key_a != null or key_b != null) {
        if (key_a) |bytes_a| {
            const value_a = try cursor_a.getCurrentValue();
            if (key_b) |bytes_b| {
                const value_b = try cursor_b.getCurrentValue();
                switch (std.mem.order(u8, bytes_a, bytes_b)) {
                    .lt => {
                        differences += 1;
                        if (options.log) |log|
                            try log.print("{s}\n- a: {s}\n- b: null\n", .{ hex(bytes_a), hex(value_a), });

                        key_a = try cursor_a.goToNext();
                    },
                    .gt => {
                        differences += 1;
                        if (options.log) |log|
                            try log.print("{s}\n- a: null\n- b: {s}\n", .{ hex(bytes_a), hex(value_b), });

                        key_b = try cursor_b.goToNext();
                    },
                    .eq =>{
                        if (!std.mem.eql(u8, value_a, value_b)) {
                            differences += 1;
                            if (options.log) |log|
                                try log.print("{s}\n- a: {s}\n- b: {s}\n", .{ hex(bytes_a), hex(value_a), hex(value_b) });
                        }

                        key_a = try cursor_a.goToNext();
                        key_b = try cursor_b.goToNext();
                    }
                }
            } else {
                differences += 1;
                if (options.log) |log|
                    try log.print("{s}\n- a: {s}\n- b: null\n", .{ hex(bytes_a), hex(value_a) });

                key_a = try cursor_a.goToNext();
            }
        } else {
            if (key_b) |bytes_b| {
                const value_b = try cursor_b.getCurrentValue();
                differences += 1;
                if (options.log) |log|
                    try log.print("{s}\n- a: null\n- b: {s}\n", .{ hex(bytes_b), hex(value_b) });

                key_b = try cursor_b.goToNext();
            } else {
                break;
            }
        }
    }

    if (options.log) |log| try log.print("{s:-<80}\n", .{ "END DIFF " });

    cursor_a.close();
    cursor_b.close();
    txn_a.abort();
    txn_b.abort();

    return differences;
}

pub fn expectEqualEntries(env: Environment, entries: []const [2][]const u8) !void {
    var txn = try Transaction.open(env, true);
    defer txn.abort();

    var cursor = try Cursor.open(txn);
    defer cursor.close();
    
    var i: usize = 0;
    var key = try cursor.goToFirst();
    while (key != null) : (key = try cursor.goToNext()) {
        try expect(i < entries.len);
        try expectEqualSlices(u8, try cursor.getCurrentKey(), entries[i][0]);
        try expectEqualSlices(u8, try cursor.getCurrentValue(), entries[i][1]);
        i += 1;
    }

    try expectEqual(i, entries.len);
}

const allocator = std.heap.c_allocator;

test "expectEqualEntries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [4096]u8 = undefined;
    var tmp_path = try tmp.dir.realpath(".", &buffer);

    var path = try std.fs.path.joinZ(allocator, &.{ tmp_path, "data.mdb" });
    defer allocator.free(path);
    
    var env = try Environment.open(path, .{});
    defer env.close();
    
    var txn = try Transaction.open(env, false);
    errdefer txn.abort();
    
    try txn.set("a", "foo");
    try txn.set("b", "bar");
    try txn.set("c", "baz");
    try txn.set("d", "qux");
    try txn.commit();
    
    try expectEqualEntries(env, &[_][2][]const u8{
       .{ "a", "foo" },
       .{ "b", "bar" },
       .{ "c", "baz" },
       .{ "d", "qux" },
    });
}
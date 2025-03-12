const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");
const keys = @import("keys.zig");

var path_buffer: [std.fs.max_path_bytes]u8 = undefined;

pub fn open(dir: std.fs.Dir, options: lmdb.Environment.Options) !lmdb.Environment {
    const path = try dir.realpath(".", &path_buffer);
    path_buffer[path.len] = 0;
    return try lmdb.Environment.init(path_buffer[0..path.len :0], options);
}

pub fn printEntries(env: lmdb.Environment, writer: std.fs.File.Writer) !void {
    const txn = try lmdb.Transaction.open(env, .{ .read_only = true });
    defer txn.abort();

    const cursor = try lmdb.Cursor.open(txn);
    var entry = try cursor.goToFirst();
    while (entry) |key| : (entry = try cursor.goToNext()) {
        const value = try cursor.getCurrentValue();
        try writer.print("{s}\t{s}\n", .{ hex(key), hex(value) });
    }
}

pub fn expectEqualEntries(db: lmdb.Database, entries: []const [2][]const u8) !void {
    const cursor = try lmdb.Cursor.init(db);
    defer cursor.deinit();

    var i: usize = 0;
    var key = try cursor.goToFirst();
    while (key != null) : (key = try cursor.goToNext()) {
        try expect(i < entries.len);
        try expectEqualSlices(u8, entries[i][0], try cursor.getCurrentKey());
        try expectEqualSlices(u8, entries[i][1], try cursor.getCurrentValue());
        i += 1;
    }

    try expectEqual(entries.len, i);
}

pub fn expectEqualDatabases(expected: lmdb.Database, actual: lmdb.Database) !void {
    const expected_cursor = try expected.cursor();
    defer expected_cursor.deinit();

    const actual_cursor = try actual.cursor();
    defer actual_cursor.deinit();

    var expected_key = try expected_cursor.goToFirst();
    var actual_key = try actual_cursor.goToFirst();
    try keys.expectEqual(expected_key, actual_key);

    while (expected_key != null and actual_key != null) {
        expected_key = try expected_cursor.goToNext();
        actual_key = try actual_cursor.goToNext();
        try keys.expectEqual(expected_key, actual_key);
    }
}

pub const CompareOptions = struct {
    log: ?std.fs.File.Writer = null,
};

pub fn compareEnvironments(env_a: lmdb.Environment, env_b: lmdb.Environment, dbs: ?[][*:0]const u8, options: CompareOptions) !usize {
    const txn_a = try lmdb.Transaction.init(env_a, .{ .mode = .ReadOnly });
    defer txn_a.abort();

    const txn_b = try lmdb.Transaction.init(env_b, .{ .mode = .ReadOnly });
    defer txn_b.abort();

    if (dbs) |names| {
        var sum: usize = 0;
        for (names) |name| {
            const db_a = try txn_a.database(name, .{});
            const db_b = try txn_b.database(name, .{});
            sum += try compareDatabases(db_a, db_b, options);
        }

        return sum;
    } else {
        const db_a = try txn_a.database(null, .{});
        const db_b = try txn_b.database(null, .{});
        return try compareDatabases(db_a, db_b, options);
    }
}

pub fn compareDatabases(expected: lmdb.Database, actual: lmdb.Database, options: CompareOptions) !usize {
    if (options.log) |log| try log.print("{s:-<80}\n", .{"START DIFF "});

    var differences: usize = 0;

    const cursor_a = try lmdb.Cursor.init(expected);
    defer cursor_a.deinit();

    const cursor_b = try lmdb.Cursor.init(actual);
    defer cursor_b.deinit();

    var key_a = try cursor_a.goToFirst();
    var key_b = try cursor_b.goToFirst();
    while (key_a != null or key_b != null) {
        if (key_a) |key_a_bytes| {
            const value_a = try cursor_a.getCurrentValue();
            if (key_b) |key_b_bytes| {
                const value_b = try cursor_b.getCurrentValue();
                switch (std.mem.order(u8, key_a_bytes, key_b_bytes)) {
                    .lt => {
                        differences += 1;
                        if (options.log) |log|
                            try log.print("{s}\n- expected: {s}\n- actual:   null\n", .{ hex(key_a_bytes), hex(value_a) });

                        key_a = try cursor_a.goToNext();
                    },
                    .gt => {
                        differences += 1;
                        if (options.log) |log|
                            try log.print("{s}\n- expected: null\n- actual:   {s}\n", .{
                                hex(key_b_bytes),
                                hex(value_b),
                            });

                        key_b = try cursor_b.goToNext();
                    },
                    .eq => {
                        if (!std.mem.eql(u8, value_a, value_b)) {
                            differences += 1;
                            if (options.log) |log|
                                try log.print("{s}\n- expected: {s}\n- actual:   {s}\n", .{ hex(key_a_bytes), hex(value_a), hex(value_b) });
                        }

                        key_a = try cursor_a.goToNext();
                        key_b = try cursor_b.goToNext();
                    },
                }
            } else {
                differences += 1;
                if (options.log) |log|
                    try log.print("{s}\n- expected: {s}\n- actual:   null\n", .{ hex(key_a_bytes), hex(value_a) });

                key_a = try cursor_a.goToNext();
            }
        } else {
            if (key_b) |bytes_b| {
                const value_b = try cursor_b.getCurrentValue();
                differences += 1;
                if (options.log) |log|
                    try log.print("{s}\n- expected: null\n- actual:   {s}\n", .{ hex(bytes_b), hex(value_b) });

                key_b = try cursor_b.goToNext();
            } else {
                break;
            }
        }
    }

    if (options.log) |log| try log.print("{s:-<80}\n", .{"END DIFF "});

    return differences;
}

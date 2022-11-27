const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;

const lmdb = @import("lmdb");
const utils = @import("utils.zig");
const SkipListCursor = @import("SkipListCursor.zig").SkipListCursor;

pub fn printEntries(env: lmdb.Environment, writer: std.fs.File.Writer) !void {
    const txn = try lmdb.Transaction.open(env, .{ .read_only = true });
    defer txn.abort();

    const cursor = try lmdb.Cursor.open(txn);
    var entry = try cursor.goToFirst();
    while (entry) |key| : (entry = try cursor.goToNext()) {
        const value = try cursor.getCurrentValue();
        try writer.print("{s} <- {s}\n", .{ hex(value), hex(key) });
    }
}

const Printer = struct {
    const Options = struct {
        compact: bool = true,
    };

    writer: std.fs.File.Writer,
    cursor: SkipListCursor,
    height: u8,
    limit: u8,
    key: std.ArrayList(u8),
    options: Options,

    pub fn init(
        allocator: std.mem.Allocator,
        env: lmdb.Environment,
        writer: std.fs.File.Writer,
        options: Options,
    ) !Printer {
        var cursor = try SkipListCursor.open(allocator, env, true);
        if (try utils.getMetadata(cursor.txn)) |metadata| {
            const limit = try utils.getLimit(metadata.degree);
            return Printer{
                .cursor = cursor,
                .writer = writer,
                .height = metadata.height,
                .limit = limit,
                .key = std.ArrayList(u8).init(allocator),
                .options = options,
            };
        } else {
            return error.InvalidDatabase;
        }
    }

    pub fn deinit(self: *Printer) void {
        self.key.deinit();
        self.cursor.abort();
    }

    fn isSplit(self: *const Printer, value: []const u8) bool {
        return value[31] < self.limit;
    }

    pub fn print(self: *Printer) !void {
        try self.key.resize(0);
        try self.cursor.goToNode(0, self.key.items);
        assert(try self.printRange(0, self.height, self.key.items) == null);
    }

    // const Result = enum { oef, fjdksla };
    // returns the value of the first key of the next range
    fn printRange(self: *Printer, depth: u8, level: u8, first_key: []const u8) !?[]const u8 {
        if (level == 0) {
            var value = try self.cursor.getCurrentValue();
            try self.printValue(value);
            try self.writer.print("| {s}\n", .{hex(first_key)});

            while (try self.cursor.goToNext(level)) |next_key| {
                const next_value = try self.cursor.getCurrentValue();
                if (self.isSplit(next_value)) {
                    try self.key.resize(next_key.len);
                    std.mem.copy(u8, self.key.items, next_key);
                    return self.key.items;
                } else {
                    try self.printPrefix(depth);
                    try self.printValue(next_value);
                    try self.writer.print("| {s}\n", .{hex(next_key)});
                }
            }

            return null;
        }

        if (try self.cursor.get(level, first_key)) |value| {
            try self.printValue(value);
        } else {
            try self.writer.print("missing key {s} at level {d}\n", .{ hex(first_key), level });
            return error.KeyNotFound;
        }

        var key = first_key;
        while (try self.printRange(depth + 1, level - 1, key)) |next_key| : (key = next_key) {
            if (try self.cursor.get(level, next_key)) |next_value| {
                if (self.isSplit(next_value)) {
                    return next_key;
                } else {
                    try self.printPrefix(depth);
                    try self.printValue(next_value);
                }
            } else {
                // try self.writer.print("\nAAAAAA {s}\n", .{ hex(next_key) });
                try self.writer.print("missing key {s} at level {d}\n", .{ hex(next_key), level });
                return error.KeyNotFound;
            }
        }

        return null;

        // return error.InvalidDatabase;

        // while (try self.printRange(depth + 1, level - 1, next_key))

        // while (try self.cursor.get(level, first_key)) |value| {

        // }

        // if (try self.cursor.get(level, self.key.items)) |value| {
        //     try self.printValue(value);

        //     if (try self.printRange(depth + 1, level - 1)) {
        //         return true;
        //     }

        //     while (try self.cursor.get(level, self.key.items)) |next_value| {
        //         if (self.isSplit(next_value)) {
        //             return false;
        //         } else {
        //             try self.printPrefix(depth);
        //             try self.printValue(next_value);
        //             if (try self.printRange(depth + 1, level - 1)) {
        //                 return true;
        //             }
        //         }
        //     }

        //     return error.InvalidDatabase;
        // } else {
        //     return error.KeyNotFound;
        // }
    }

    fn printValue(self: *Printer, value: []const u8) !void {
        if (self.options.compact) {
            const tail = value[value.len - 3 ..];
            try self.writer.print("...{s} ", .{hex(tail)});
        } else {
            try self.writer.print("{s} ", .{hex(value)});
        }
    }

    fn printPrefix(self: *Printer, depth: u8) !void {
        assert(depth > 0);
        var i: u8 = 0;
        while (i < depth) : (i += 1) {
            if (self.options.compact) {
                try self.writer.print("          ", .{});
            } else {
                try self.writer.print("                                                                 ", .{});
            }
        }
    }
};

pub fn printTree(allocator: std.mem.Allocator, env: lmdb.Environment, writer: std.fs.File.Writer, options: Printer.Options) !void {
    var printer = try Printer.init(allocator, env, writer, options);
    try printer.print();
    printer.deinit();
}

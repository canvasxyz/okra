const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;

const lmdb = @import("lmdb");
const utils = @import("utils.zig");

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
    const Options = struct { compact: bool = true };

    txn: lmdb.Transaction,
    cursor: lmdb.Cursor,
    writer: std.fs.File.Writer,
    height: u8,
    limit: u8,
    key: std.ArrayList(u8),
    buffer: std.ArrayList(u8),
    options: Options,

    pub fn init(
        allocator: std.mem.Allocator,
        txn: lmdb.Transaction,
        writer: std.fs.File.Writer,
        options: Options,
    ) !Printer {
        if (try utils.getMetadata(txn)) |metadata| {
            const cursor = try lmdb.Cursor.open(txn);
            const limit = try utils.getLimit(metadata.degree);
            return Printer{
                .txn = txn,
                .cursor = cursor,
                .writer = writer,
                .height = metadata.height,
                .limit = limit,
                .key = std.ArrayList(u8).init(allocator),
                .buffer = std.ArrayList(u8).init(allocator),
                .options = options,
            };
        } else {
            return error.InvalidDatabase;
        }
    }

    pub fn deinit(self: *Printer) void {
        self.cursor.close();
        self.key.deinit();
        self.buffer.deinit();
    }

    fn isSplit(self: *const Printer, value: []const u8) bool {
        return value[31] < self.limit;
    }

    pub fn print(self: *Printer) !void {
        try self.key.resize(0);
        try self.goToNode(0, self.key.items);
        assert(try self.printRange(0, self.height, self.key.items) == null);
    }

    // returns the value of the first key of the next range
    fn printRange(self: *Printer, depth: u8, level: u8, first_key: []const u8) !?[]const u8 {
        if (level == 0) {
            var value = try self.cursor.getCurrentValue();
            try self.printValue(value);
            try self.writer.print("| {s}\n", .{hex(first_key)});

            while (try self.goToNext(level)) |next_key| {
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

        if (try self.getNode(level, first_key)) |value| {
            try self.printValue(value);
        } else {
            try self.writer.print("missing key {s} at level {d}\n", .{ hex(first_key), level });
            return error.KeyNotFound;
        }

        var key = first_key;
        while (try self.printRange(depth + 1, level - 1, key)) |next_key| : (key = next_key) {
            if (try self.getNode(level, next_key)) |next_value| {
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

    fn setKey(self: *Printer, level: u8, key: []const u8) !void {
        try self.buffer.resize(1 + key.len);
        self.buffer.items[0] = level;
        std.mem.copy(u8, self.buffer.items[1..], key);
    }

    fn getNode(self: *Printer, level: u8, key: []const u8) !?[]const u8 {
        try self.setKey(level, key);
        return try self.txn.get(self.buffer.items);
    }

    fn goToNode(self: *Printer, level: u8, key: []const u8) !void {
        try self.setKey(level, key);
        try self.cursor.goToKey(self.buffer.items);
    }

    fn goToNext(self: *Printer, level: u8) !?[]const u8 {
        if (try self.cursor.goToNext()) |key| {
            if (key[0] == level) {
                return key[1..];
            }
        }

        return null;
    }
};

pub fn printTree(allocator: std.mem.Allocator, env: lmdb.Environment, writer: std.fs.File.Writer, options: Printer.Options) !void {
    const txn = try lmdb.Transaction.open(env, .{ .read_only = true });
    defer txn.abort();

    var printer = try Printer.init(allocator, txn, writer, options);
    try printer.print();
    printer.deinit();
}

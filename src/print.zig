const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;
const assert = std.debug.assert;

const lmdb = @import("lmdb");
const utils = @import("./utils.zig");
const SkipListCursor = @import("./SkipListCursor.zig").SkipListCursor;

pub fn printEntries(env: lmdb.Environment, writer: std.fs.File.Writer) !void {
    const txn = try lmdb.Transaction.open(env, true);
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
    height: u16,
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
            const limit = @intCast(u8, 256 / @intCast(u16, metadata.degree));
            return Printer {
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
        try self.cursor.goToNode(0, &[_]u8 {});
        assert(try self.printRange(0, self.height));
    }
    
    fn printRange(self: *Printer, depth: u16, level: u16) !bool {
        if (level == 0) {
            var value = try self.cursor.getCurrentValue();
            if (self.options.compact) {
                const tail = value[value.len-3..];
                try self.writer.print("...{s} | {s}\n", .{ hex(tail), hex(self.key.items) });
            } else {
                try self.writer.print("{s} | {s}\n", .{ hex(value), hex(self.key.items) });
            }

            while (try self.cursor.goToNext()) |next_key| {
                const next_value = try self.cursor.getCurrentValue();
                if (self.isSplit(next_value)) {
                    try self.key.resize(next_key.len);
                    std.mem.copy(u8, self.key.items, next_key);
                    return false;
                } else {
                    try self.printPrefix(depth);
                    if (self.options.compact) {
                        const tail = next_value[next_value.len-3..];
                        try self.writer.print("...{s} | {s}\n", .{ hex(tail), hex(next_key) });
                    } else {
                        try self.writer.print("{s} | {s}\n", .{ hex(next_value), hex(next_key) });
                    }
                }
            }

            return true;
        } else if (try self.cursor.get(level, self.key.items)) |value| {
            if (self.options.compact) {
                const tail = value[value.len-3..];
                try self.writer.print("...{s} ", .{ hex(tail) });
            } else {
                try self.writer.print("{s} ", .{ hex(value) });
            }

            if (try self.printRange(depth + 1, level - 1)) return true;
            while (try self.cursor.get(level, self.key.items)) |next_value| {
                if (self.isSplit(next_value)) {
                    return false;
                } else {
                    try self.printPrefix(depth);

                    if (self.options.compact) {
                        const tail = next_value[next_value.len-3..];
                        try self.writer.print("...{s} ", .{ hex(tail) });
                    } else {
                        try self.writer.print("{s} ", .{ hex(next_value) });
                    }

                    if (try self.printRange(depth + 1, level - 1)) {
                        return true;
                    }
                }
            }
        }

        return error.InvalidDatabase;
    }
    
    fn printPrefix(self: *Printer, depth: u16) !void {
        assert(depth > 0);
        var i: u16 = 0;
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

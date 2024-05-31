const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const okra = @import("okra");
const utils = @import("utils.zig");

const Printer = @This();

allocator: std.mem.Allocator,
map: *okra.Map,
iter: okra.Iterator,
writer: std.fs.File.Writer,
encoding: utils.Encoding,
prefix: std.ArrayList(u8),
is_a_tty: bool,

pub fn init(allocator: std.mem.Allocator, map: *okra.Map, encoding: utils.Encoding) !Printer {
    const stdout = std.io.getStdOut();
    const iter = try okra.Iterator.init(allocator, map.db, .{ .level = 0 });
    return .{
        .allocator = allocator,
        .map = map,
        .iter = iter,
        .writer = stdout.writer(),
        .is_a_tty = std.posix.isatty(stdout.handle),
        .encoding = encoding,
        .prefix = std.ArrayList(u8).init(allocator),
    };
}

pub fn deinit(self: *Printer) void {
    self.iter.deinit();
    self.prefix.deinit();
}

pub fn printRoot(self: *Printer, height: ?u8, depth: ?u8) !void {
    const root = try self.map.getRoot();

    var pad: u8 = 0;
    if (height) |h| {
        if (root.level < h) {
            pad = h - root.level;
        }
    }

    try self.prefix.resize(0);

    var i: u8 = 0;
    while (i < pad) : (i += 1) {
        try self.prefix.appendSlice(last_indentation_unit);
    }

    try self.writer.writeByte('\n');
    _ = try self.writer.write(self.prefix.items);

    const len = if (depth) |d| d else root.level;

    // var len: u8 = root.level;
    // if (depth) |d| d else root.level

    i = 0;
    while (i < len + 1) : (i += 1) {
        try self.writer.print("│  level {d: <3}", .{root.level - i});
    }

    try self.writer.print("│ key\n", .{});
    try self.writer.print("{s}", .{self.prefix.items});

    i = 0;
    while (i < len + 1) : (i += 1) {
        try self.writer.print("{s}", .{header_indentation_unit});
    }

    try self.writer.print("┼──────\n", .{});
    try self.writer.print("{s}", .{self.prefix.items});

    try self.indentLast();
    try self.printTree(root, null, len, "──");
}

fn printTree(self: *Printer, node: okra.Node, limit: ?[]const u8, depth: u8, bullet: []const u8) !void {
    try self.writer.print("{s}", .{bullet});
    try self.printHash(node.hash);
    if (node.level == 0 or depth == 0) {
        try self.printKey(node.key);
    } else {
        var children = okra.NodeList.init(self.allocator);
        defer children.deinit();

        try self.iter.reset(.{
            .level = node.level - 1,
            .lower_bound = .{ .key = node.key, .inclusive = true },
            .upper_bound = if (limit) |key| .{ .key = key, .inclusive = false } else null,
        });

        while (try self.iter.next()) |child| {
            try children.append(child);
        }

        const last_index = children.nodes.items.len - 1;

        for (children.nodes.items, 0..) |child, i| {
            if (i > 0) {
                try self.writer.print("{s}", .{self.prefix.items});
            }

            if (i == last_index) {
                try self.indentLast();
                defer self.dedentLast();

                try self.printTree(child, limit, depth - 1, if (i == 0) "──" else "└─");
            } else {
                try self.indent();
                defer self.dedent();

                const next_limit = children.nodes.items[i + 1].key;
                try self.printTree(child, next_limit, depth - 1, if (i == 0) "┬─" else "├─");
            }
        }
    }
}

const hash_size = 4;
const indentation_unit = "│   " ++ "  " ** hash_size;
const last_indentation_unit = "    " ++ "  " ** hash_size;
const header_indentation_unit = "┴───" ++ "──" ** hash_size;

fn indent(self: *Printer) !void {
    try self.prefix.appendSlice(indentation_unit);
}

fn dedent(self: *Printer) void {
    if (self.prefix.items.len >= indentation_unit.len) {
        self.prefix.resize(self.prefix.items.len - indentation_unit.len) catch unreachable;
    }
}

fn indentLast(self: *Printer) !void {
    try self.prefix.appendSlice(last_indentation_unit);
}

fn dedentLast(self: *Printer) void {
    if (self.prefix.items.len >= last_indentation_unit.len) {
        self.prefix.resize(self.prefix.items.len - last_indentation_unit.len) catch unreachable;
    }
}

fn printKey(self: *const Printer, key: ?[]const u8) !void {
    if (key) |bytes| {
        switch (self.encoding) {
            .hex => try self.writer.print("│ {s}\n", .{hex(bytes)}),
            .raw => try self.writer.print("│ {s}\n", .{bytes}),
        }
    } else {
        try self.writer.print("│\n", .{});
    }
}

fn printHash(self: *const Printer, hash: *const [okra.K]u8) !void {
    try self.writer.print(" {s} ", .{hex(hash[0..hash_size])});
}

const color_clear = "0";
const color_highlight = "33;1";

fn printColor(self: *const Printer, color: []const u8) !void {
    if (self.is_a_tty) {
        // try std.fmt.format(self.writer, )
        try self.writer.print("{c}[{s}m", .{ 0x1b, color });
    }
}

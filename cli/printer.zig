const std = @import("std");
const okra = @import("okra");
const hex = std.fmt.fmtSliceHexLower;

const utils = @import("utils.zig");

pub const Printer = struct {
    cursor: okra.Cursor,
    writer: std.fs.File.Writer,
    encoding: utils.Encoding,
    prefix: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, txn: okra.Transaction, encoding: utils.Encoding) !Printer {
        var cursor = try okra.Cursor.open(allocator, &txn);
        const writer = std.io.getStdOut().writer();
        return .{
            .cursor = cursor,
            .writer = writer,
            .encoding = encoding,
            .prefix = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Printer) void {
        self.cursor.close();
        self.prefix.deinit();
    }

    pub fn printRoot(self: *Printer, pad: u8, depth: ?u8) !void {
        try self.prefix.resize(0);
        var i: u8 = 0;
        while (i < pad) : (i += 1) {
            try self.prefix.appendSlice(last_indentation_unit);
        }

        try self.writer.print("{s}", .{self.prefix.items});

        const root = try self.cursor.goToRoot();
        try self.indentLast();
        try self.printTree(root, null, if (depth) |value| value else root.level, "──");
    }

    fn printTree(self: *Printer, node: okra.Node, limit: ?[]const u8, depth: u8, bullet: []const u8) !void {
        if (node.level == 0 or depth == 0) {
            try self.writer.print("{s} {s} │ ", .{ bullet, hex(node.hash[0..hash_size]) });
            try self.printKey(node.key);
        } else {
            try self.writer.print("{s} {s} ", .{ bullet, hex(node.hash[0..hash_size]) });

            const children = try okra.NodeList.init(&self.cursor, node.level, node.key, limit);
            defer children.deinit();
            const last_index = children.nodes.items.len - 1;

            for (children.nodes.items) |child, i| {
                if (i == last_index) {
                    if (i > 0) {
                        try self.writer.print("{s}", .{self.prefix.items});
                    }

                    try self.indentLast();
                    defer self.dedentLast();
                    try self.printTree(
                        child,
                        children.getLimit(i, limit),
                        depth - 1,
                        if (i == 0) "──" else "└─",
                    );
                } else {
                    if (i > 0) {
                        try self.writer.print("{s}", .{self.prefix.items});
                    }

                    try self.indent();
                    defer self.dedent();
                    try self.printTree(
                        child,
                        children.getLimit(i, limit),
                        depth - 1,
                        if (i == 0) "┬─" else "├─",
                    );
                }
            }
        }
    }

    const hash_size = 4;
    const indentation_unit = "│   " ++ "  " ** hash_size;
    const last_indentation_unit = "    " ++ "  " ** hash_size;

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
                .hex => try self.writer.print("{s}\n", .{hex(bytes)}),
                .utf8 => try self.writer.print("{s}\n", .{bytes}),
            }
        } else {
            try self.writer.print("\n", .{});
        }
    }
};

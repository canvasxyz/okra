const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

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

pub fn Printer(comptime K: u8, comptime Q: u32) type {
    const Node = @import("node.zig").Node(K, Q);
    const Tree = @import("tree.zig").Tree(K, Q);
    const NodeList = @import("node_list.zig").NodeList(K, Q);
    const Transaction = @import("transaction.zig").Transaction(K, Q);
    const Cursor = @import("cursor.zig").Cursor(K, Q);

    return struct {
        const Self = @This();

        log: std.fs.File.Writer,
        txn: *Transaction,
        cursor: *Cursor,
        prefix: std.ArrayList(u8),
        stack: std.ArrayList(Node),

        pub fn init(allocator: std.mem.Allocator, tree: *const Tree, log: std.fs.File.Writer) !Self {
            const txn = try Transaction.open(allocator, tree, .{ .read_only = true });
            const cursor = try Cursor.open(allocator, txn);
            return .{
                .log = log,
                .txn = txn,
                .cursor = cursor,
                .prefix = std.ArrayList(u8).init(allocator),
                .stack = std.ArrayList(Node).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.cursor.close();
            self.txn.abort();
            self.prefix.deinit();
            self.stack.deinit();
        }

        pub fn print(self: *Self) !void {
            const root = try self.cursor.goToRoot();
            try self.printNode(root, null);
        }

        fn printNode(self: *Self, node: Node, limit: ?[]const u8) !void {
            try self.printHash(node.hash);
            if (node.level == 0) {
                if (node.key) |key| {
                    try self.log.print("| {s}\n", .{hex(key)});
                } else {
                    try self.log.print("|\n", .{});
                }
            } else {
                const children = try NodeList.init(self.cursor, node.level, node.key, limit);
                defer children.deinit();

                try self.indent();
                defer self.deindent();

                for (children.nodes.items) |child, i| {
                    if (i > 0) try self.log.print("{s}", .{self.prefix.items});
                    try self.printNode(child, children.getLimit(i, limit));
                }
            }
        }

        fn printHash(self: *Self, hash: *const [K]u8) !void {
            try self.log.print("{s} ", .{hex(hash)});
        }

        const indentation_unit = "  " ** K ++ " ";

        fn indent(self: *Self) !void {
            try self.prefix.appendSlice(indentation_unit);
        }

        fn deindent(self: *Self) void {
            if (self.prefix.items.len >= indentation_unit.len) {
                self.prefix.resize(self.prefix.items.len - indentation_unit.len) catch unreachable;
            }
        }
    };
}

// pub fn printTree(allocator: std.mem.Allocator, tree: lmdb.Environment, writer: std.fs.File.Writer, options: Printer.Options) !void {
//     const txn = try lmdb.Transaction.open(env, .{ .read_only = true });
//     defer txn.abort();

//     var printer = try Printer.init(allocator, txn, writer, options);
//     try printer.print();
//     printer.deinit();
// }

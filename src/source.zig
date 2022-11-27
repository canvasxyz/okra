const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

const okra = @import("lib.zig");
const utils = @import("utils.zig");

/// A Source is the basic read interface to a tree.
/// .key is an internal [K]u8 array that holds the source's *current location*,
/// .rootLevel stores the root level of the tree at transaction-time.
/// You can call source.getChildren(level, leaf) to page the given key's
/// children into .nodes. The rule for using .get (which is enforced)
/// is that every key passed to .get MUST be strictly greater than the
/// current key, ordered first by leaf comparison and second by reverse
/// level (lower levels are greater than higher levels).
/// It's important to close sources in a timely manner.
pub fn Source(comptime X: usize, comptime Q: u8) type {
    return struct {
        const K = 2 + X;
        const V = 32;
        const Txn = lmdb.Transaction(K, V);
        const Cursor = lmdb.Cursor(K, V);
        const Tree = okra.Tree(X, Q);
        const Node = okra.Node(X);

        pub const Error = error{ InvalidLevel, Rewind, InvalidDatabase };

        txn: Txn,
        cursor: Cursor,
        rootLevel: u16,
        rootValue: Tree.Value,
        key: Tree.Key,

        pub fn init(self: *Source(X, Q), _: std.mem.Allocator, tree: *const Tree) !void {
            self.txn = try Txn.open(tree.env, true);
            self.cursor = try Cursor.open(self.txn, tree.dbi);
            if (try self.cursor.goToLast()) |key| {
                const level = Tree.getLevel(key);
                if (Tree.isKeyLeftEdge(key) and level > 0) {
                    self.rootLevel = level;
                    std.mem.copy(u8, &self.rootValue, try self.cursor.getCurrentValue());
                } else {
                    return Error.InvalidDatabase;
                }
            } else {
                return Error.InvalidDatabase;
            }

            self.key = Tree.createKey(self.rootLevel, null);
        }

        pub fn getChildren(self: *Source(X, Q), level: u16, leaf: ?*const Tree.Leaf, nodes: *std.ArrayList(Node)) !void {
            if (level == 0) return Error.InvalidLevel;

            if (Tree.lessThan(leaf, Tree.getLeaf(&self.key))) {
                return Error.Rewind;
            } else if (Tree.getLevel(&self.key) < level) {
                if (leaf) |leafBytes| {
                    if (std.mem.eql(u8, leafBytes, Tree.getLeaf(&self.key))) {
                        return Error.Rewind;
                    }
                } else if (Tree.isKeyLeftEdge(&self.key)) {
                    return Error.Rewind;
                }
            }

            self.key = Tree.createKey(level - 1, leaf);
            try self.cursor.goToKey(&self.key);
            try append(nodes, Tree.getLeaf(&self.key), try self.cursor.getCurrentValue());

            while (try self.cursor.goToNext()) |key| {
                const value = try self.cursor.getCurrentValue();
                if (Tree.getLevel(key) != level - 1) break;
                if (Tree.isSplit(value)) break;
                try append(nodes, Tree.getLeaf(key), value);
            }
        }

        fn append(nodes: *std.ArrayList(Node), leaf: *const Tree.Leaf, value: *const Tree.Value) !void {
            try nodes.append(.{ .leaf = leaf.*, .hash = value.* });
        }

        pub fn close(self: *Source(X, Q)) void {
            self.cursor.close();
            self.txn.abort();
        }
    };
}

test "source" {
    const X = 6;
    const Q = 0x42;
    const Tree = okra.Tree(X, Q);
    const Node = okra.Node(X);
    const allocator = std.heap.c_allocator;

    var tmp = std.testing.tmpDir(.{});
    const path = try utils.resolvePath(allocator, tmp.dir, "data.mdb");
    defer allocator.free(path);

    var tree: Tree = undefined;
    try tree.init(allocator, path, .{});
    defer tree.close();

    var leaf = [_]u8{0} ** X;
    var hash: Tree.Value = undefined;
    const permutation = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    for (permutation) |i| {
        std.mem.writeIntBig(u16, leaf[(X - 2)..X], i + 1);
        Sha256.hash(&leaf, &hash, .{});
        try tree.insert(&leaf, &hash);
    }

    var source: Source(X, Q) = undefined;
    try source.init(allocator, &tree);
    defer source.close();

    var nodes = std.ArrayList(Node).init(allocator);
    defer nodes.deinit();
    // try source.getChildren(source.rootLevel, null, &nodes);
    // try expectEqualSlices(Node, &[_]Node{
    //   .{
    //     .leaf = [_]u8{ 0, 0, 0, 0, 0, 0 },
    //     .hash = utils.parseHash("8c0f5c019987df13c9db17498afbeed5a98cdabbd0619ae7d1407e0ea47505aa"),
    //   },
    //   .{
    //     .leaf = [_]u8{ 0, 0, 0, 0, 0, 3 },
    //     .hash = utils.parseHash("fa4530d6ce61a2a493e37083f018aa1beb835dd2661f921f201bd870eeee38ec"),
    //   },
    //   .{
    //     .leaf = [_]u8{ 0, 0, 0, 0, 0, 5 },
    //     .hash = utils.parseHash("fa23b8df5a4ddb651f3997f8ee9e7766356fc3eb3fd6b283ccebd666e803a51b"),
    //   },
    // }, nodes.items);
    // try nodes.resize(0);

    // try source.getChildren(2, &[_]u8{ 0, 0, 0, 0, 0, 5 }, &nodes);
    // try expectEqualSlices(Node, &[_]Node{
    //   .{
    //     .leaf = [_]u8{ 0, 0, 0, 0, 0, 5 },
    //     .hash = utils.parseHash("1ed43d22ab1f8714a58e57d25455350c2ea48b2a7d51c20d8ee48a1e7b4ae29e"),
    //   },
    //   .{
    //     .leaf = [_]u8{ 0, 0, 0, 0, 0, 8 },
    //     .hash = utils.parseHash("c8e441d5955c26d76b3cf2202cad48028a4f3a097d50db8810a71a34a69bdedd"),
    //   },
    //   .{
    //     .leaf = [_]u8{ 0, 0, 0, 0, 0, 9 },
    //     .hash = utils.parseHash("4cd0b46302810af02c86bad8ed6ebf13ead97ee3830b7fdd968307fd2647de76"),
    //   },
    // }, nodes.items);
    // try nodes.resize(0);

    // try source.getChildren(1, &[_]u8{ 0, 0, 0, 0, 0, 8 }, &nodes);
    // try expectEqualSlices(Node, &[_]Node{
    //   .{
    //     .leaf = [_]u8{ 0, 0, 0, 0, 0, 8 },
    //     .hash = utils.parseHash("33935bd20b29e71c259688628b274310649244541a297726019eb69c5c4b7c57"),
    //   },
    // }, nodes.items);
    // try nodes.resize(0);

    // try expectError(error.Rewind, source.getChildren(1, &[_]u8{ 0, 0, 0, 0, 0, 5 }, &nodes));

    tmp.cleanup();
}

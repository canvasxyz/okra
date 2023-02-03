const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocator = std.heap.c_allocator;

const lmdb = @import("lmdb");

const K = 32;
const Q = 4;

const Tree = @import("tree.zig").Tree(K, Q);
const Builder = @import("builder.zig").Builder(K, Q);
const Transaction = @import("transaction.zig").Transaction(K, Q);

const utils = @import("utils.zig");
const print = @import("print.zig");
const library = @import("library.zig");

fn h(comptime value: *const [64]u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&buffer, value) catch unreachable;
    return buffer;
}

fn leaf(hash: *const [64]u8, value: u8) [33]u8 {
    var result: [33]u8 = undefined;
    _ = std.fmt.hexToBytes(result[0..32], hash) catch unreachable;
    result[32] = value;
    return result;
}

test "Transaction.get" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    var tree = try Tree.open(allocator, path, .{});
    defer tree.close();

    var txn = try Transaction.open(allocator, &tree, .{ .read_only = false });
    defer txn.abort();

    try txn.set("a", "foo");
    try txn.set("b", "bar");
    try txn.set("c", "baz");

    try if (try txn.get("b")) |value| try expectEqualSlices(u8, value, "bar") else error.NotFound;
    try if (try txn.get("a")) |value| try expectEqualSlices(u8, value, "foo") else error.NotFound;
    try if (try txn.get("c")) |value| try expectEqualSlices(u8, value, "baz") else error.NotFound;
}

test "Transaction.set" {
    for (&library.tests) |t| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const path = try utils.resolvePath(tmp.dir, ".");
        var tree = try Tree.open(allocator, path, .{});
        defer tree.close();

        {
            var txn = try Transaction.open(allocator, &tree, .{ .read_only = false });
            errdefer txn.abort();
            for (t.leaves) |entry| try txn.set(entry[0], entry[1]);
            try txn.commit();
        }

        try lmdb.expectEqualEntries(tree.env, t.entries);
    }
}

test "delete a leaf anchor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    var tree = try Tree.open(allocator, path, .{});
    defer tree.close();

    {
        var txn = try Transaction.open(allocator, &tree, .{ .read_only = false });
        errdefer txn.abort();
        for (library.tests[2].leaves) |entry| {
            try txn.set(entry[0], entry[1]);
        }

        try txn.delete("d");
        try txn.commit();
    }

    try lmdb.expectEqualEntries(tree.env, &.{
        .{ &[_]u8{0}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{ 0, 'a' }, &leaf("a0568b6bb51648ab5b2df66ca897ffa4c58ed956cdbcf846d914b269ff182e02", 0x00) },
        .{ &[_]u8{ 0, 'b' }, &leaf("d21fa5d709077fd5594f180a8825852aae07c2f32ab269cfece930978f72c7f9", 0x01) },
        .{ &[_]u8{ 0, 'c' }, &leaf("690b688439b13abeb843a1d7a24d0ea7f40ee1cb038a26bcf16acdab50de9192", 0x02) },
        .{ &[_]u8{ 0, 'e' }, &leaf("e754a835f3376cb88e9409bbd32171ed35a7fba438046562140fe6611b9b9c19", 0x04) },
        .{ &[_]u8{ 0, 'f' }, &leaf("3036e350f1987268c6b3b0e3d77ab42bd231a63a59747b420aa27b7531b612e1", 0x05) },
        .{ &[_]u8{ 0, 'g' }, &leaf("1205bde66f06562c541fc2da7a0520522140dc9e79c726774d548809ce13f387", 0x06) },
        .{ &[_]u8{ 0, 'h' }, &leaf("9f6a45a8ad078a5d6e26d841a5cda5bc7a6a45e431b9569c7d4a190b7e329514", 0x07) },
        .{ &[_]u8{ 0, 'i' }, &leaf("7b3ab478e1555bcfb823e59f7c3d2b7fda3e268876aead5d664cdfd57441b89a", 0x08) },
        .{ &[_]u8{ 0, 'j' }, &leaf("661ebf57575dfc3d87a8d7ad0cb9f9eb9f6f20aa0f004ae4282d7a8d172e4a5d", 0x09) },
        .{ &[_]u8{1}, &h("7ba4b9fd7a5b818f342615616c0a5697735b01e2fe6297a44a576a8d0286a670") },
        .{ &[_]u8{ 1, 'f' }, &h("578f1b9cca1874716a2d51a9c7eaed0ad56398398f55e4cbd73b99ddd6a38401") },
        .{ &[_]u8{ 1, 'g' }, &h("e5abbf8e6e3e589a0c6174861d7f8f9ea56e05d3d67ef4b4a65c4c7f21cfe32f") },
        .{ &[_]u8{2}, &h("4124354b00d608e230b707504173482baf7b11636c62a8ec3abb0471e7ce89ed") },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
    });
}

test "overwrite a leaf anchor with another anchor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    var tree = try Tree.open(allocator, path, .{});
    defer tree.close();

    {
        var txn = try Transaction.open(allocator, &tree, .{ .read_only = false });
        errdefer txn.abort();
        for (library.tests[2].leaves) |entry| {
            try txn.set(entry[0], entry[1]);
        }

        try txn.delete("d");
        try txn.set("d", "\x0c"); // 0fbcd74bb6796c5ee4fb2103c7fc26aba1d07a495b6d961c0f9d3b21e959c8c2
        try txn.commit();
    }

    try lmdb.expectEqualEntries(tree.env, &.{
        .{ &[_]u8{0}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{ 0, 'a' }, &leaf("a0568b6bb51648ab5b2df66ca897ffa4c58ed956cdbcf846d914b269ff182e02", 0x00) },
        .{ &[_]u8{ 0, 'b' }, &leaf("d21fa5d709077fd5594f180a8825852aae07c2f32ab269cfece930978f72c7f9", 0x01) },
        .{ &[_]u8{ 0, 'c' }, &leaf("690b688439b13abeb843a1d7a24d0ea7f40ee1cb038a26bcf16acdab50de9192", 0x02) },
        .{ &[_]u8{ 0, 'd' }, &leaf("0fbcd74bb6796c5ee4fb2103c7fc26aba1d07a495b6d961c0f9d3b21e959c8c2", 0x0c) },
        .{ &[_]u8{ 0, 'e' }, &leaf("e754a835f3376cb88e9409bbd32171ed35a7fba438046562140fe6611b9b9c19", 0x04) },
        .{ &[_]u8{ 0, 'f' }, &leaf("3036e350f1987268c6b3b0e3d77ab42bd231a63a59747b420aa27b7531b612e1", 0x05) },
        .{ &[_]u8{ 0, 'g' }, &leaf("1205bde66f06562c541fc2da7a0520522140dc9e79c726774d548809ce13f387", 0x06) },
        .{ &[_]u8{ 0, 'h' }, &leaf("9f6a45a8ad078a5d6e26d841a5cda5bc7a6a45e431b9569c7d4a190b7e329514", 0x07) },
        .{ &[_]u8{ 0, 'i' }, &leaf("7b3ab478e1555bcfb823e59f7c3d2b7fda3e268876aead5d664cdfd57441b89a", 0x08) },
        .{ &[_]u8{ 0, 'j' }, &leaf("661ebf57575dfc3d87a8d7ad0cb9f9eb9f6f20aa0f004ae4282d7a8d172e4a5d", 0x09) },
        .{ &[_]u8{1}, &h("70ff616136e6ca5726aa564f5db211806ee00a5beb72bbe8d5ce29e95351e092") },
        .{ &[_]u8{ 1, 'd' }, &h("8c2f38a49b3e3b3e0bf4914ce5c87e4992be4c98b1df18638787cba6437b0287") },
        .{ &[_]u8{ 1, 'f' }, &h("578f1b9cca1874716a2d51a9c7eaed0ad56398398f55e4cbd73b99ddd6a38401") },
        .{ &[_]u8{ 1, 'g' }, &h("e5abbf8e6e3e589a0c6174861d7f8f9ea56e05d3d67ef4b4a65c4c7f21cfe32f") },
        .{ &[_]u8{2}, &h("14953d0fc005ee26c8bfbc3757b4f2642d9936a7b3a99eb6d6d7347b7ec2cd97") },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
    });
}

test "overwrite a leaf anchor with a non-anchor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    var tree = try Tree.open(allocator, path, .{});
    defer tree.close();

    {
        var txn = try Transaction.open(allocator, &tree, .{ .read_only = false });
        errdefer txn.abort();
        for (library.tests[2].leaves) |entry| {
            try txn.set(entry[0], entry[1]);
        }

        try txn.delete("d");
        try txn.set("d", "\x00"); // ad102c3188252e5ed321ea5a06231f6054c8a3e9e23a8dc7461f615688b0a542
        try txn.commit();
    }

    try lmdb.expectEqualEntries(tree.env, &.{
        .{ &[_]u8{0}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
        .{ &[_]u8{ 0, 'a' }, &leaf("a0568b6bb51648ab5b2df66ca897ffa4c58ed956cdbcf846d914b269ff182e02", 0x00) },
        .{ &[_]u8{ 0, 'b' }, &leaf("d21fa5d709077fd5594f180a8825852aae07c2f32ab269cfece930978f72c7f9", 0x01) },
        .{ &[_]u8{ 0, 'c' }, &leaf("690b688439b13abeb843a1d7a24d0ea7f40ee1cb038a26bcf16acdab50de9192", 0x02) },
        .{ &[_]u8{ 0, 'd' }, &leaf("ad102c3188252e5ed321ea5a06231f6054c8a3e9e23a8dc7461f615688b0a542", 0x00) },
        .{ &[_]u8{ 0, 'e' }, &leaf("e754a835f3376cb88e9409bbd32171ed35a7fba438046562140fe6611b9b9c19", 0x04) },
        .{ &[_]u8{ 0, 'f' }, &leaf("3036e350f1987268c6b3b0e3d77ab42bd231a63a59747b420aa27b7531b612e1", 0x05) },
        .{ &[_]u8{ 0, 'g' }, &leaf("1205bde66f06562c541fc2da7a0520522140dc9e79c726774d548809ce13f387", 0x06) },
        .{ &[_]u8{ 0, 'h' }, &leaf("9f6a45a8ad078a5d6e26d841a5cda5bc7a6a45e431b9569c7d4a190b7e329514", 0x07) },
        .{ &[_]u8{ 0, 'i' }, &leaf("7b3ab478e1555bcfb823e59f7c3d2b7fda3e268876aead5d664cdfd57441b89a", 0x08) },
        .{ &[_]u8{ 0, 'j' }, &leaf("661ebf57575dfc3d87a8d7ad0cb9f9eb9f6f20aa0f004ae4282d7a8d172e4a5d", 0x09) },
        .{ &[_]u8{1}, &h("16ca86834b817987b8b75bd54ab477d938d494f012c8f86ce564e201df19e125") },
        .{ &[_]u8{ 1, 'f' }, &h("578f1b9cca1874716a2d51a9c7eaed0ad56398398f55e4cbd73b99ddd6a38401") },
        .{ &[_]u8{ 1, 'g' }, &h("e5abbf8e6e3e589a0c6174861d7f8f9ea56e05d3d67ef4b4a65c4c7f21cfe32f") },
        .{ &[_]u8{2}, &h("733469f093b400276d5f804fc7f698e4a5a6d608bd4e75190f5917e1ff6663b1") },
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
    });
}

test "open a named database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try utils.resolvePath(tmp.dir, ".");
    const dbs: []const [*:0]const u8 = &.{ "a", "b" };

    var tree = try Tree.open(allocator, path, .{ .dbs = dbs });
    defer tree.close();

    {
        var txn = try Transaction.open(allocator, &tree, .{ .read_only = false, .dbi = "a" });
        errdefer txn.abort();
        try txn.set("x", "foo");
        try txn.commit();
    }

    {
        var txn = try Transaction.open(allocator, &tree, .{ .read_only = false, .dbi = "b" });
        errdefer txn.abort();
        try txn.set("x", "bar");
        try txn.commit();
    }

    {
        var txn = try Transaction.open(allocator, &tree, .{ .read_only = true, .dbi = "a" });
        defer txn.abort();
        try if (try txn.get("x")) |value| expectEqualSlices(u8, "foo", value) else error.KeyNotFound;
    }

    {
        var txn = try Transaction.open(allocator, &tree, .{ .read_only = true, .dbi = "b" });
        defer txn.abort();
        try if (try txn.get("x")) |value| expectEqualSlices(u8, "bar", value) else error.KeyNotFound;
    }

    try expectError(
        error.DatabaseNotFound,
        Transaction.open(allocator, &tree, .{ .read_only = true, .dbi = "c" }),
    );
}

fn testPseudoRandomPermutations(
    comptime N: u16,
    comptime P: u16,
    comptime R: u16,
    log: ?std.fs.File.Writer,
    environment_options: lmdb.Environment.Options,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try expect(R < P);

    var permutations: [N][P]u16 = undefined;

    var prng = std.rand.DefaultPrng.init(0x0000000000000000);
    var random = prng.random();

    var n: u16 = 0;
    while (n < N) : (n += 1) {
        var p: u16 = 0;
        while (p < P) : (p += 1) permutations[n][p] = p;
        std.rand.Random.shuffle(random, u16, &permutations[n]);
    }

    var key: [2]u8 = undefined;
    var value: [32]u8 = undefined;

    var name_buffer: [24]u8 = undefined;
    for (&permutations) |permutation, p| {
        const reference_name = try std.fmt.bufPrint(&name_buffer, "r{d}.{x}", .{ N, p });
        try tmp.dir.makeDir(reference_name);
        const reference_path = try utils.resolvePath(tmp.dir, reference_name);
        const reference_env = try lmdb.Environment.open(reference_path, environment_options);
        defer reference_env.close();

        {
            var builder = try Builder.open(allocator, reference_env, .{});
            errdefer builder.abort();

            for (permutation) |i| {
                std.mem.writeIntBig(u16, &key, i);
                Sha256.hash(&key, &value, .{});
                try builder.set(&key, &value);
            }

            for (permutations[(p + 1) % N][0..R]) |i| {
                std.mem.writeIntBig(u16, &key, i);
                try builder.delete(&key);
            }

            try builder.commit();
        }

        const name = try std.fmt.bufPrint(&name_buffer, "p{d}.{x}", .{ N, p });
        try tmp.dir.makeDir(name);
        const path = try utils.resolvePath(tmp.dir, name);
        var tree = try Tree.open(allocator, path, .{});
        defer tree.close();

        {
            var txn = try Transaction.open(allocator, &tree, .{ .read_only = false, .log = log });
            errdefer txn.abort();

            for (permutation) |i, j| {
                if (log) |writer|
                    try writer.print("---------- {d} ({d} / {d}) ---------\n", .{ i, j, permutation.len });

                std.mem.writeIntBig(u16, &key, i);
                Sha256.hash(&key, &value, .{});
                try txn.set(&key, &value);
            }

            for (permutations[(p + 1) % N][0..R]) |i| {
                std.mem.writeIntBig(u16, &key, i);
                try txn.delete(&key);
            }

            try txn.commit();
        }

        if (log) |writer| {
            try writer.print("PERMUTATION -----\n{any}\n", .{permutation});
            try writer.print("EXPECTED -----------------------------------------\n", .{});
            try print.printEntries(reference_env, writer);
            // try print.printTree(allocator, reference_env, writer, .{});
            try writer.print("ACTUAL -------------------------------------------\n", .{});
            // try print.printTree(allocator, env, writer, .{});
            try print.printEntries(tree.env, writer);
        }

        const delta = try lmdb.compareEntries(reference_env, tree.env, .{ .log = log });
        try expect(delta == 0);
    }
}

test "1 pseudo-random permutations of 10, deleting 0" {
    // const log = std.io.getStdErr().writer();
    // try log.print("\n", .{});
    try testPseudoRandomPermutations(1, 10, 0, null, .{});
}

test "100 pseudo-random permutations of 50, deleting 0" {
    try testPseudoRandomPermutations(100, 50, 0, null, .{});
}

test "100 pseudo-random permutations of 500, deleting 50" {
    try testPseudoRandomPermutations(100, 500, 50, null, .{});
}

test "100 pseudo-random permutations of 1000, deleting 200" {
    try testPseudoRandomPermutations(100, 1000, 200, null, .{});
}

test "10 pseudo-random permutations of 10000, deleting 500" {
    try testPseudoRandomPermutations(10, 10000, 500, null, .{ .map_size = 2 * 1024 * 1024 * 1024 });
}

test "10 pseudo-random permutations of 50000, deleting 1000" {
    try testPseudoRandomPermutations(10, 10000, 1000, null, .{ .map_size = 2 * 1024 * 1024 * 1024 });
}

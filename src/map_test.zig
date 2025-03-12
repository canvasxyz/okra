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

const Builder = @import("Builder.zig").Builder(K, Q);
const Map = @import("Map.zig").Map(K, Q);
const keys = @import("keys.zig");
const library = @import("library.zig");
const utils = @import("utils.zig");

fn h(value: *const [64]u8) [32]u8 {
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

test "open a Tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    {
        var map = try Map.init(allocator, db, .{});
        defer map.deinit();

        try utils.expectEqualEntries(db, &.{
            .{ &[_]u8{0}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
            .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 } },
        });
    }
}

test "basic get/set/delete operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    {
        var map = try Map.init(allocator, db, .{});
        defer map.deinit();

        try map.set("a", "foo");
        try map.set("b", "bar");
        try map.set("c", "baz");

        try keys.expectEqual("foo", try map.get("a"));
        try keys.expectEqual("bar", try map.get("b"));
        try keys.expectEqual("baz", try map.get("c"));
        try keys.expectEqual(null, try map.get("d"));
    }
}

test "set empty values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    {
        var map = try Map.init(allocator, db, .{});
        defer map.deinit();

        try map.set("a", "");
        try map.set("b", "");
        try map.set("c", "");

        try keys.expectEqual("", try map.get("a"));
        try keys.expectEqual("", try map.get("b"));
        try keys.expectEqual("", try map.get("c"));
        try keys.expectEqual(null, try map.get("d"));
    }
}

test "library tests" {
    for (&library.tests) |t| {
        const log = std.io.getStdErr().writer();
        try log.writeByte('\n');

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const env = try utils.open(tmp.dir, .{ .max_dbs = 2 });
        defer env.deinit();

        const txn = try env.transaction(.{ .mode = .ReadWrite });
        defer txn.abort();

        const expected = try txn.database("expected", .{ .create = true });
        const actual = try txn.database("actual", .{ .create = true });

        {
            var builder = try Builder.init(allocator, expected, .{});
            defer builder.deinit();

            for (t.leaves) |entry| try builder.set(entry[0], entry[1]);
            try builder.build();
        }

        {
            var map = try Map.init(allocator, actual, .{ .log = null });
            defer map.deinit();

            for (t.leaves) |entry| try map.set(entry[0], entry[1]);
        }

        try utils.expectEqualDatabases(expected, actual);
        // try expectEqual(@as(usize, 0), try utils.compareDatabases(expected, actual, .{ .log = log }));
    }
}

test "set the same entry twice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    {
        var map = try Map.init(allocator, db, .{});
        defer map.deinit();

        try map.set("a", "foo");
        try map.set("a", "foo");

        try if (try map.get("a")) |value| expectEqualSlices(u8, "foo", value) else error.KeyNotFound;
    }
}

test "delete a leaf boundary" {
    const log = std.io.getStdErr().writer();
    try log.writeByte('\n');

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    {
        var map = try Map.init(allocator, db, .{ .log = null });
        defer map.deinit();

        for (library.tests[2].leaves) |entry| {
            try map.set(entry[0], entry[1]);
        }

        try map.delete("d");
    }

    // {
    //     var sl = try Tree.init(allocator, db, .{ .log = null });
    //     defer sl.deinit();

    //     for (library.tests[2].leaves) |entry| {
    //         try sl.set(entry[0], entry[1]);
    //     }

    //     try sl.delete("d");
    // }

    try utils.expectEqualEntries(db, &.{
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
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 } },
    });
}

test "overwrite a leaf boundary with another boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try env.transaction(.{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    {
        var map = try Map.init(allocator, db, .{});
        defer map.deinit();

        for (library.tests[2].leaves) |entry| {
            try map.set(entry[0], entry[1]);
        }

        try map.delete("d");
        try map.set("d", "\x0c"); // 0fbcd74bb6796c5ee4fb2103c7fc26aba1d07a495b6d961c0f9d3b21e959c8c2
    }

    // {
    //     var sl = try Tree.init(allocator, db, .{});
    //     defer sl.deinit();

    //     for (library.tests[2].leaves) |entry| {
    //         try sl.set(entry[0], entry[1]);
    //     }

    //     try sl.delete("d");
    //     try sl.set("d", "\x0c"); // 0fbcd74bb6796c5ee4fb2103c7fc26aba1d07a495b6d961c0f9d3b21e959c8c2
    // }

    try utils.expectEqualEntries(db, &.{
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
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 } },
    });
}

test "overwrite a leaf boundary with a non-boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const env = try utils.open(tmp.dir, .{});
    defer env.deinit();

    const txn = try lmdb.Transaction.init(env, .{ .mode = .ReadWrite });
    defer txn.abort();

    const db = try txn.database(null, .{});

    {
        var map = try Map.init(allocator, db, .{});
        defer map.deinit();

        for (library.tests[2].leaves) |entry| {
            try map.set(entry[0], entry[1]);
        }

        try map.delete("d");
        try map.set("d", "\x00"); // ad102c3188252e5ed321ea5a06231f6054c8a3e9e23a8dc7461f615688b0a542
    }

    // {
    //     var sl = try Tree.init(allocator, db, .{});
    //     defer sl.deinit();

    //     for (library.tests[2].leaves) |entry| {
    //         try sl.set(entry[0], entry[1]);
    //     }

    //     try sl.delete("d");
    //     try sl.set("d", "\x00"); // ad102c3188252e5ed321ea5a06231f6054c8a3e9e23a8dc7461f615688b0a542
    // }

    try utils.expectEqualEntries(db, &.{
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
        .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 } },
    });
}

const PermutationOptions = struct {
    log: ?std.fs.File.Writer = null,
    map_size: usize = 10 * 1024 * 1024,
};

fn testPseudoRandomPermutations(
    comptime N: u16,
    comptime P: u16,
    comptime R: u16,
    options: PermutationOptions,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try expect(R < P);

    var permutations: [N][P]u16 = undefined;

    var prng = std.Random.DefaultPrng.init(0x0000000000000000);
    const random = prng.random();

    var n: u16 = 0;
    while (n < N) : (n += 1) {
        var p: u16 = 0;
        while (p < P) : (p += 1) permutations[n][p] = p;
        std.Random.shuffle(random, u16, &permutations[n]);
    }

    var key: [2]u8 = undefined;
    var value: [32]u8 = undefined;

    var name_buffer: [24]u8 = undefined;
    for (&permutations, 0..) |permutation, p| {
        const name = try std.fmt.bufPrint(&name_buffer, "{d}.{x}", .{ N, p });
        try tmp.dir.makeDir(name);

        var dir = try tmp.dir.openDir(name, .{});
        defer dir.close();

        const env = try utils.open(dir, .{ .max_dbs = 2, .map_size = options.map_size });
        defer env.deinit();

        const txn = try lmdb.Transaction.init(env, .{ .mode = .ReadWrite });
        defer txn.abort();

        const expected = try txn.database("expected", .{ .create = true });
        const actual = try txn.database("actual", .{ .create = true });

        // build reference tree
        {
            var builder = try Builder.init(allocator, expected, .{});
            defer builder.deinit();

            for (permutation) |i| {
                std.mem.writeInt(u16, &key, i, .big);
                Sha256.hash(&key, &value, .{});
                try builder.set(&key, &value);
            }

            for (permutations[(p + 1) % N][0..R]) |i| {
                std.mem.writeInt(u16, &key, i, .big);
                try builder.delete(&key);
            }

            try builder.build();
        }

        {
            var map = try Map.init(allocator, actual, .{ .log = options.log });
            defer map.deinit();

            {
                for (permutation, 0..) |i, j| {
                    if (options.log) |writer|
                        try writer.print("---------- {d} ({d} / {d}) ---------\n", .{ i, j, permutation.len });

                    std.mem.writeInt(u16, &key, i, .big);
                    Sha256.hash(&key, &value, .{});
                    try map.set(&key, &value);
                }

                for (permutations[(p + 1) % N][0..R]) |i| {
                    std.mem.writeInt(u16, &key, i, .big);
                    try map.delete(&key);
                }
            }
        }

        // if (log) |writer| {
        //     try writer.print("PERMUTATION -----\n{any}\n", .{permutation});
        //     try writer.print("EXPECTED -----------------------------------------\n", .{});
        //     try utils.printEntries(reference_env, writer);
        //     try writer.print("ACTUAL -------------------------------------------\n", .{});
        //     try utils.printEntries(tree.env, writer);
        // }

        try utils.expectEqualDatabases(expected, actual);
        // try expectEqual(@as(usize, 0), try utils.compareDatabases(expected, actual, .{ .log = options.log }));
    }
}

test "1 pseudo-random permutations of 10, deleting 0" {
    // const log = std.io.getStdErr().writer();
    // try log.writeByte('\n');
    try testPseudoRandomPermutations(1, 10, 0, .{ .log = null });
}

test "100 pseudo-random permutations of 50, deleting 0" {
    // const log = std.io.getStdErr().writer();
    // try log.writeByte('\n');
    // try testPseudoRandomPermutations(100, 50, 0, .{ .log = log });
    try testPseudoRandomPermutations(100, 50, 0, .{ .log = null });
}

test "100 pseudo-random permutations of 500, deleting 50" {
    try testPseudoRandomPermutations(100, 500, 50, .{});
}

test "100 pseudo-random permutations of 1000, deleting 200" {
    try testPseudoRandomPermutations(100, 1000, 200, .{});
}

test "10 pseudo-random permutations of 10000, deleting 500" {
    try testPseudoRandomPermutations(10, 10000, 500, .{ .map_size = 2 * 1024 * 1024 * 1024 });
}

test "10 pseudo-random permutations of 50000, deleting 1000" {
    try testPseudoRandomPermutations(10, 10000, 1000, .{ .map_size = 2 * 1024 * 1024 * 1024 });
}

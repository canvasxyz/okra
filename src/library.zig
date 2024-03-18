const std = @import("std");

const utils = @import("utils.zig");

const Entry = [2][]const u8;

pub const Test = struct { leaves: []const Entry, entries: []const Entry };

// Sha256() = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

pub const tests = [_]Test{
    .{
        .leaves = &.{},
        .entries = &.{
            .{ &[_]u8{0}, &node("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
            .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 } },
        },
    },
    .{
        .leaves = &.{
            .{ "a", "\x00" }, // f39bd65e0288b1f54b1f9d0aed56898742f58eaa1a48ab7570de9cb39e0b6ef1
            .{ "b", "\x01" }, // 89902f000cf47c6c01c66da838aadb70fc63a434b1742d3617d688b394cff2dd
            .{ "c", "\x02" }, // 0bcff62fc85f03c136c9cb7fbd35821698d92e168c58fbdb794b1df4566e291d
        },
        .entries = &.{
            .{ &[_]u8{0}, &node("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
            .{ &[_]u8{ 0, 'a' }, &leaf("f39bd65e0288b1f54b1f9d0aed56898742f58eaa1a48ab7570de9cb39e0b6ef1", 0x00) },
            .{ &[_]u8{ 0, 'b' }, &leaf("89902f000cf47c6c01c66da838aadb70fc63a434b1742d3617d688b394cff2dd", 0x01) },
            .{ &[_]u8{ 0, 'c' }, &leaf("0bcff62fc85f03c136c9cb7fbd35821698d92e168c58fbdb794b1df4566e291d", 0x02) },
            .{ &[_]u8{1}, &node("61d1b2573fd5fe5d4f0888a08f7a0f203eb55d18a905688103c5937be7235234") },
            .{ &[_]u8{ 1, 'c' }, &node("c7bba63ef64ca26da2a9580dc89fcb08817fd92398e55a9b416c520e593f862c") },
            .{ &[_]u8{2}, &node("93da8808149acea3cc8c9dfb30b90e327e2cf725e3125d502fadd7a443f861b3") },
            .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 } },
        },
    },
    .{
        .leaves = &.{
            .{ "a", "\x00" }, // f39bd65e0288b1f54b1f9d0aed56898742f58eaa1a48ab7570de9cb39e0b6ef1
            .{ "b", "\x01" }, // 89902f000cf47c6c01c66da838aadb70fc63a434b1742d3617d688b394cff2dd
            .{ "c", "\x02" }, // 0bcff62fc85f03c136c9cb7fbd35821698d92e168c58fbdb794b1df4566e291d
            .{ "d", "\x03" }, // 44c2b8aa88501e2a4c7f421e6e51ed3b3cc61aab4f17a4083c4d1ff17d5384de
            .{ "e", "\x04" }, // 8d43c7102a89ffcc3c92870ccd274123ed283dd99c1f8579a3ca2ac77860a1e1
            .{ "f", "\x05" }, // edd8af13d204466eb5012817d59cabcee535ea89e4701f9fd7eb79f4da91725f
            .{ "g", "\x06" }, // b6dd4ac2b6f02aa5cef5a1f271b12a971670f7805af859de1c0b2f7b750f0af7
            .{ "h", "\x07" }, // b62f220f0b56f6132093314a89ac6b56440b5e46664b78630b3174038353b45a
            .{ "i", "\x08" }, // db92b989b3dfd1c90c344d51894bcb0267b580102b6f21dda19ad320965be59c
            .{ "j", "\x09" }, // d3e590efcc1e808909ad4daa28ff9db3b2e86b9762ed2838e604c210fc6898dd
        },
        .entries = &.{
            .{ &[_]u8{0}, &node("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") },
            .{ &[_]u8{ 0, 'a' }, &leaf("f39bd65e0288b1f54b1f9d0aed56898742f58eaa1a48ab7570de9cb39e0b6ef1", 0x00) },
            .{ &[_]u8{ 0, 'b' }, &leaf("89902f000cf47c6c01c66da838aadb70fc63a434b1742d3617d688b394cff2dd", 0x01) },
            .{ &[_]u8{ 0, 'c' }, &leaf("0bcff62fc85f03c136c9cb7fbd35821698d92e168c58fbdb794b1df4566e291d", 0x02) },
            .{ &[_]u8{ 0, 'd' }, &leaf("44c2b8aa88501e2a4c7f421e6e51ed3b3cc61aab4f17a4083c4d1ff17d5384de", 0x03) },
            .{ &[_]u8{ 0, 'e' }, &leaf("8d43c7102a89ffcc3c92870ccd274123ed283dd99c1f8579a3ca2ac77860a1e1", 0x04) },
            .{ &[_]u8{ 0, 'f' }, &leaf("edd8af13d204466eb5012817d59cabcee535ea89e4701f9fd7eb79f4da91725f", 0x05) },
            .{ &[_]u8{ 0, 'g' }, &leaf("b6dd4ac2b6f02aa5cef5a1f271b12a971670f7805af859de1c0b2f7b750f0af7", 0x06) },
            .{ &[_]u8{ 0, 'h' }, &leaf("b62f220f0b56f6132093314a89ac6b56440b5e46664b78630b3174038353b45a", 0x07) },
            .{ &[_]u8{ 0, 'i' }, &leaf("db92b989b3dfd1c90c344d51894bcb0267b580102b6f21dda19ad320965be59c", 0x08) },
            .{ &[_]u8{ 0, 'j' }, &leaf("d3e590efcc1e808909ad4daa28ff9db3b2e86b9762ed2838e604c210fc6898dd", 0x09) },
            .{ &[_]u8{1}, &node("61d1b2573fd5fe5d4f0888a08f7a0f203eb55d18a905688103c5937be7235234") },
            .{ &[_]u8{ 1, 'c' }, &node("f9176bfe8ff9df7573ace13a5c494214849d1ee54c08068fa8ba4369139b285f") },
            .{ &[_]u8{2}, &node("0ab7cb2bcc8cf5448fa502a4084709fdd1eb3f23eaeb15f098a8576ff7098f71") },
            .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 2, 32, 0, 0, 0, 4 } },
        },
    },
};

fn leaf(hash: *const [64]u8, value: u8) [33]u8 {
    @setEvalBranchQuota(2000);
    var result: [33]u8 = undefined;
    _ = std.fmt.hexToBytes(result[0..32], hash) catch unreachable;
    result[32] = value;
    return result;
}

fn node(value: *const [64]u8) [32]u8 {
    @setEvalBranchQuota(2000);
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, value) catch unreachable;
    return result;
}

const std = @import("std");

const utils = @import("utils.zig");

const Entry = [2][]const u8;

pub const Test = struct { leaves: []const Entry, entries: []const Entry };

// Blake3() = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262

pub const tests = [_]Test{
    .{
        .leaves = &.{},
        .entries = &.{
            .{ &[_]u8{0}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
            .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
        },
    },
    .{
        .leaves = &.{
            .{ "a", "\x00" }, // a0568b6bb51648ab5b2df66ca897ffa4c58ed956cdbcf846d914b269ff182e02
            .{ "b", "\x01" }, // d21fa5d709077fd5594f180a8825852aae07c2f32ab269cfece930978f72c7f9
            .{ "c", "\x02" }, // 690b688439b13abeb843a1d7a24d0ea7f40ee1cb038a26bcf16acdab50de9192
        },
        .entries = &.{
            .{ &[_]u8{0}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
            .{ &[_]u8{ 0, 'a' }, &l("a0568b6bb51648ab5b2df66ca897ffa4c58ed956cdbcf846d914b269ff182e02", 0x00) },
            .{ &[_]u8{ 0, 'b' }, &l("d21fa5d709077fd5594f180a8825852aae07c2f32ab269cfece930978f72c7f9", 0x01) },
            .{ &[_]u8{ 0, 'c' }, &l("690b688439b13abeb843a1d7a24d0ea7f40ee1cb038a26bcf16acdab50de9192", 0x02) },
            .{ &[_]u8{1}, &h("70ff616136e6ca5726aa564f5db211806ee00a5beb72bbe8d5ce29e95351e092") },
            .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
        },
    },
    .{
        .leaves = &.{
            .{ "a", "\x00" }, // a0568b6bb51648ab5b2df66ca897ffa4c58ed956cdbcf846d914b269ff182e02
            .{ "b", "\x01" }, // d21fa5d709077fd5594f180a8825852aae07c2f32ab269cfece930978f72c7f9
            .{ "c", "\x02" }, // 690b688439b13abeb843a1d7a24d0ea7f40ee1cb038a26bcf16acdab50de9192
            .{ "d", "\x03" }, // 283fc563889411201d0d09674fd9d0ad2ddb6da4631b104c81d0d46bfae972d4
            .{ "e", "\x04" }, // e754a835f3376cb88e9409bbd32171ed35a7fba438046562140fe6611b9b9c19
            .{ "f", "\x05" }, // 3036e350f1987268c6b3b0e3d77ab42bd231a63a59747b420aa27b7531b612e1
            .{ "g", "\x06" }, // 1205bde66f06562c541fc2da7a0520522140dc9e79c726774d548809ce13f387
            .{ "h", "\x07" }, // 9f6a45a8ad078a5d6e26d841a5cda5bc7a6a45e431b9569c7d4a190b7e329514
            .{ "i", "\x08" }, // 7b3ab478e1555bcfb823e59f7c3d2b7fda3e268876aead5d664cdfd57441b89a
            .{ "j", "\x09" }, // 661ebf57575dfc3d87a8d7ad0cb9f9eb9f6f20aa0f004ae4282d7a8d172e4a5d
        },
        .entries = &.{
            .{ &[_]u8{0}, &h("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262") },
            .{ &[_]u8{ 0, 'a' }, &l("a0568b6bb51648ab5b2df66ca897ffa4c58ed956cdbcf846d914b269ff182e02", 0x00) },
            .{ &[_]u8{ 0, 'b' }, &l("d21fa5d709077fd5594f180a8825852aae07c2f32ab269cfece930978f72c7f9", 0x01) },
            .{ &[_]u8{ 0, 'c' }, &l("690b688439b13abeb843a1d7a24d0ea7f40ee1cb038a26bcf16acdab50de9192", 0x02) },
            .{ &[_]u8{ 0, 'd' }, &l("283fc563889411201d0d09674fd9d0ad2ddb6da4631b104c81d0d46bfae972d4", 0x03) },
            .{ &[_]u8{ 0, 'e' }, &l("e754a835f3376cb88e9409bbd32171ed35a7fba438046562140fe6611b9b9c19", 0x04) },
            .{ &[_]u8{ 0, 'f' }, &l("3036e350f1987268c6b3b0e3d77ab42bd231a63a59747b420aa27b7531b612e1", 0x05) },
            .{ &[_]u8{ 0, 'g' }, &l("1205bde66f06562c541fc2da7a0520522140dc9e79c726774d548809ce13f387", 0x06) },
            .{ &[_]u8{ 0, 'h' }, &l("9f6a45a8ad078a5d6e26d841a5cda5bc7a6a45e431b9569c7d4a190b7e329514", 0x07) },
            .{ &[_]u8{ 0, 'i' }, &l("7b3ab478e1555bcfb823e59f7c3d2b7fda3e268876aead5d664cdfd57441b89a", 0x08) },
            .{ &[_]u8{ 0, 'j' }, &l("661ebf57575dfc3d87a8d7ad0cb9f9eb9f6f20aa0f004ae4282d7a8d172e4a5d", 0x09) },
            .{ &[_]u8{1}, &h("70ff616136e6ca5726aa564f5db211806ee00a5beb72bbe8d5ce29e95351e092") },
            .{ &[_]u8{ 1, 'd' }, &h("9020fa923ffc2eeafe4197a26afb7e1efd7176912d8ac7e86ddc2f3a7c106452") },
            .{ &[_]u8{ 1, 'f' }, &h("578f1b9cca1874716a2d51a9c7eaed0ad56398398f55e4cbd73b99ddd6a38401") },
            .{ &[_]u8{ 1, 'g' }, &h("e5abbf8e6e3e589a0c6174861d7f8f9ea56e05d3d67ef4b4a65c4c7f21cfe32f") },
            .{ &[_]u8{2}, &h("2e5d52802433b30f1bf5ed26d55c4b2cf2df1ac40db1639a44c213e612878cff") },
            .{ &[_]u8{0xFF}, &[_]u8{ 'o', 'k', 'r', 'a', 1, 32, 0, 0, 0, 4 } },
        },
    },
};

fn l(hash: *const [64]u8, value: u8) [33]u8 {
    @setEvalBranchQuota(2000);
    var result: [33]u8 = undefined;
    _ = std.fmt.hexToBytes(result[0..32], hash) catch unreachable;
    result[32] = value;
    return result;
}

fn h(value: *const [64]u8) [32]u8 {
    @setEvalBranchQuota(2000);
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, value) catch unreachable;
    return result;
}

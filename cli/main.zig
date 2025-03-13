const std = @import("std");

const cli = @import("zig-cli");

const init = @import("./commands/init.zig");

const cat = @import("./commands/cat.zig");
const ls = @import("./commands/ls.zig");
const tree = @import("./commands/tree.zig");

const get = @import("./commands/get.zig");
const set = @import("./commands/set.zig");
const delete = @import("./commands/delete.zig");
const stat = @import("./commands/stat.zig");

pub fn main() !void {
    var r = try cli.AppRunner.init(std.heap.page_allocator);

    const app = &cli.App{
        .command = .{
            .name = "okra",
            .description = .{ .one_line = "okra is a deterministic pseudo-random merkle tree built on LMDB" },
            .target = .{
                .subcommands = &.{
                    try init.command(&r),

                    try cat.command(&r),
                    try ls.command(&r),
                    try tree.command(&r),

                    try get.command(&r),
                    try set.command(&r),
                    try delete.command(&r),

                    try stat.command(&r),
                },
            },
        },
    };

    return r.run(app);
}

// fn run_server() !void {
//     std.log.info("blah blah lba", .{});
// }

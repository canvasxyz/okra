const std = @import("std");
const allocator = std.heap.c_allocator;

const cli = @import("zig-cli");

const init = @import("./commands/init.zig").command;

const cat = @import("./commands/cat.zig").command;
const ls = @import("./commands/ls.zig").command;
const tree = @import("./commands/tree.zig").command;

const get = @import("./commands/get.zig").command;
const set = @import("./commands/set.zig").command;
const delete = @import("./commands/delete.zig").command;

var app = &cli.App{
    .name = "okra",
    .description = "okra is a deterministic pseudo-random merkle tree built on LMDB",
    .subcommands = &.{
        init,

        cat,
        ls,
        tree,

        get,
        set,
        delete,
    },
};

pub fn main() !void {
    return cli.run(app, allocator);
}

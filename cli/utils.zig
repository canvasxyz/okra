const std = @import("std");

pub const Encoding = enum { raw, hex };

pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    const w = std.io.getStdErr().writer();
    std.fmt.format(w, "ERROR: ", .{}) catch unreachable;
    std.fmt.format(w, fmt, args) catch unreachable;
    std.fmt.format(w, "\n", .{}) catch unreachable;
    std.os.exit(1);
}

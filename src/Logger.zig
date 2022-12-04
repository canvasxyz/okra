const std = @import("std");

const indentation_unit = "| ";

pub const Logger = struct {
    writer: ?std.fs.File.Writer,
    prefix: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, writer: ?std.fs.File.Writer) Logger {
        return Logger{ .writer = writer, .prefix = std.ArrayList(u8).init(allocator) };
    }

    pub fn reset(self: *Logger) void {
        self.prefix.shrinkAndFree(0);
    }

    pub fn deinit(self: *Logger) void {
        self.prefix.deinit();
    }

    pub fn indent(self: *Logger) !void {
        if (self.writer != null) {
            try self.prefix.appendSlice(indentation_unit);
        }
    }

    pub fn deindent(self: *Logger) void {
        if (self.writer != null and self.prefix.items.len >= indentation_unit.len) {
            self.prefix.shrinkAndFree(self.prefix.items.len - indentation_unit.len);
        }
    }

    pub fn print(self: *Logger, comptime format: []const u8, args: anytype) !void {
        if (self.writer) |writer| {
            try writer.print("{s}", .{self.prefix.items});
            try writer.print(format ++ "\n", args);
        }
    }
};

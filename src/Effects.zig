const std = @import("std");

const Effects = @This();

timer: std.time.Timer,
create: usize = 0,
update: usize = 0,
delete: usize = 0,
height: u8 = 0,
cursor_ops: usize = 0,
cursor_goto_latency: f64 = 0,
cursor_next_latency: f64 = 0,
cursor_prev_latency: f64 = 0,
cursor_seek_latency: f64 = 0,

pub fn init() !Effects {
    const timer = try std.time.Timer.start();
    return .{ .timer = timer };
}

pub fn reset(self: *Effects) void {
    self.create = 0;
    self.update = 0;
    self.delete = 0;
    self.height = 0;
    self.cursor_ops = 0;
    self.cursor_goto_latency = 0;
    self.cursor_next_latency = 0;
    self.cursor_prev_latency = 0;
    self.cursor_seek_latency = 0;
}

const std = @import("std");

const Effects = @This();

create: usize = 0,
update: usize = 0,
delete: usize = 0,
height: u8 = 0,

pub fn reset(self: *Effects) void {
    self.* = Effects{};
}

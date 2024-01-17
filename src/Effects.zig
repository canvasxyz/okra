const Effects = @This();

create: usize = 0,
update: usize = 0,
delete: usize = 0,
height: u8 = 0,
cursor_ops: usize = 0,

pub fn reset(self: *Effects) void {
    self.create = 0;
    self.update = 0;
    self.delete = 0;
    self.height = 0;
    self.cursor_ops = 0;
}

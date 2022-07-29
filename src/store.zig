const std = @import("std");
const assert = std.debug.assert;

const constants = @import("./constants.zig");

const Header = @import("./header.zig").Header;
const Page = @import("./page.zig").Page;

pub const MemoryStore = struct {
  page_limit: u32,
  matrix: []?*[256]?*Page,

  pub fn create(allocator: std.mem.Allocator, page_limit: u32) !*MemoryStore {
    var row_count = page_limit / 256;
    if (page_limit % 256 > 0) {
      row_count += 1;
    }

    const memory_store = try allocator.create(MemoryStore); 
    memory_store.page_limit = page_limit;
    memory_store.matrix = try allocator.alloc(?*[256]?*Page, row_count);
    std.mem.set(?*[256]?*Page, memory_store.matrix, null);
    return memory_store;
  }

  pub fn create_page(self: *MemoryStore, allocator: std.mem.Allocator, page_id: u32) !*Page {
    assert(page_id > 0);
    assert(page_id <= self.page_limit);
    const row_index = (page_id - 1) / 256;
    const col_index = (page_id - 1) % 256;

    if (self.matrix[row_index]) |row| {
      if (row[col_index]) |page| {
        return page;
      } else {
        const page = try allocator.create(Page);
        row[col_index] = page;
        return page;
      }
    } else {
      const row = try allocator.create([256]?*Page);
      std.mem.set(?*Page, row, null);

      const page = try allocator.create(Page);
      row[col_index] = page;

      self.matrix[row_index] = row;
      return page;
    }
  }

  pub fn get_page(self: *MemoryStore, page_id: u32) *Page {
    assert(page_id > 0);
    assert(page_id <= self.page_limit);
    const row_index = (page_id - 1) / 256;
    const col_index = (page_id - 1) % 256;
    if (self.matrix[row_index]) |row| {
      if (row[col_index]) |page| {
        return page;
      } else {
        @panic("MemoryStore: invalid page index");
      }
    } else {
      @panic("MemoryStore: invalid chapter index");
    }
  }

  pub fn close(self: *MemoryStore, allocator: std.mem.Allocator) void {
    for (self.matrix) |row| {
      if (row) |cols| {
        for (cols) |cell| {
          if (cell) |page| {
            allocator.destroy(page);
          }
        }

        allocator.destroy(cols);
      }
    }
  }
};

pub const FileStore = struct {
  file: std.fs.File,

  pub fn create(allocator: std.mem.Allocator, path: []const u8) !*FileStore {
    const store = try allocator.create(FileStore);
    store.file = try std.fs.cwd().createFile(path, .{
      .read = true,
      .exclusive = true,
      .lock = std.fs.File.Lock.Exclusive,
    });

    return store;
  }

  pub fn open(self: *FileStore, allocator: std.mem.Allocator, path: []const u8, header: *Header, root: *Page) !*FileStore {
    const store = try allocator.create(FileStore);
    store.file = try std.fs.cwd().openFile(path, .{
      .read = true,
      .write = true,
      .lock = std.fs.File.Lock.Exclusive,
    });

    const header_bytes = @ptrCast(*[constants.PAGE_SIZE]u8, header);
    const header_bytes_read = try self.file.readAll(header_bytes);
    assert(header_bytes_read == constants.PAGE_SIZE);
    
    store.open_page(header.get_root_id(), root);

    return store;
  }

  pub fn open_page(self: *FileStore, page_id: u32, page: *Page) !void {
    assert(page_id > 0);
    const page_bytes = @ptrCast(*[constants.PAGE_SIZE]u8, page);
    try self.file.seekTo(page_id * constants.PAGE_SIZE);
    const bytes_read = try self.file.readAll(page_bytes);
    assert(bytes_read == constants.PAGE_SIZE);
  }
  
  pub fn write_page(self: *FileStore, page_id: u32, page: *Page) !void {
    try self.file.seekTo(page_id * constants.PAGE_SIZE);
    const page_bytes = @ptrCast(*[constants.PAGE_SIZE]u8, page);
    try self.file.writeAll(page_bytes);
  }

  pub fn close(self: *FileStore, allocator: std.mem.Allocator) void {
    self.file.close();
    allocator.destroy(self);
  }
};
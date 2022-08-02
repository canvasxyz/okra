const std = @import("std");
const os = std.os;
const expect = std.testing.expect;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const constants = @import("./constants.zig");

const StoreTag = enum { file, memory };

pub const Store = union(StoreTag) {
  pub const Error = FileStore.Error || MemoryStore.Error;

  file: FileStore,
  memory: MemoryStore,

  pub fn open(allocator: Allocator, path: ?[]const u8) Error!Store {
    if (path) |p| {
      const file_store = try FileStore.open(p);
      return Store{ .file = file_store };
    } else {
      const memory_store = try MemoryStore.open(allocator);
      return Store{ .memory = memory_store };
    }
  }

  pub fn created(store: Store) bool {
    return switch (store) {
      StoreTag.file => |file_store| file_store.created,
      StoreTag.memory => true,
    };
  }

  pub fn close(store: *Store) void {
    switch (store.*) {
      StoreTag.file => |*file_store| file_store.close(),
      StoreTag.memory => |*memory_store| memory_store.close(),
    }
  }

  pub fn get(store: *Store, id: u32) Error!*[constants.PAGE_SIZE]u8 {
    return switch (store.*) {
      StoreTag.file => |*file_store| {
        return file_store.get(id);
      },
      StoreTag.memory => |*memory_store| {
        return memory_store.get(id);
      },
    };
  }
};

// Alright here's our file mapping strategy

// We're gonna use mmap for both reads and writes. This simplifies almost all
// the code we have to write with the exception of appends. Appending to a
// memory-mapped file is complicated.

// There are a two levels of "allocation" that happen independently:
// - We allocate *empty pages on disk* in blocks of 64 pages (262KB)
// - We allocate *address space* in units of 8 blocks (2GB)
// This means we pre-allocate a multiple of 2GB of address space on open.
// When we run out of empty pages on disk, we ftruncate() another 64 pages and
// mmap() a *contiguous* block of memory with the MAP_FIXED flag.
// If we've run out of pre-allocated address space, we munmap() and mmap(null, ...)
// with an additional gigabyte.

// https://stackoverflow.com/questions/15684771/how-to-portably-extend-a-file-accessed-using-mmap
// https://stackoverflow.com/questions/35891525/mmap-for-writing-sequential-log-file-for-speed

const PAGES_PER_BLOCK: comptime_int = 64;
const BLOCKS_PER_UNIT: comptime_int = 8;

const BLOCK_SIZE: comptime_int = PAGES_PER_BLOCK * constants.PAGE_SIZE;
const UNIT_SIZE: comptime_int = BLOCKS_PER_UNIT * BLOCK_SIZE;

const OS_FLAGS = os.O.RDWR | os.O.CREAT;
const FILE_PERMS = os.S.IRUSR | os.S.IWUSR | os.S.IRGRP | os.S.IWGRP | os.S.IROTH | os.S.IWOTH;

const FileStore = struct {
  pub const Error = std.os.MMapError || std.os.TruncateError || std.os.OpenError;

  created: bool,
  fd: i32,
  unit_count: u32,
  block_count: u32,
  ptr: [*]align(std.mem.page_size)u8,
  pages: []align(std.mem.page_size)[constants.PAGE_SIZE]u8,

  fn open(path: []const u8) Error!FileStore {
    var fs = FileStore {
      .created = true,
      .fd = -1,
      .unit_count = 0,
      .block_count = 0,
      .ptr = undefined,
      .pages = undefined,
    };

    fs.fd = try os.open(path, OS_FLAGS, FILE_PERMS);
    std.log.info("opened fd {d}", .{ fs.fd });

    const stat = try os.fstat(fs.fd);
    const size = @intCast(u32, stat.size);
    fs.created = size == 0;

    if (fs.created) {
      // creating a new file
      try os.ftruncate(fs.fd, BLOCK_SIZE);
      fs.block_count = 1;
      fs.unit_count = 1;
    } else {
      // opening an existing file
      assert(size % BLOCK_SIZE == 0);
      fs.block_count = size / BLOCK_SIZE;
      fs.unit_count = (size + UNIT_SIZE - 1) / UNIT_SIZE;
    }

    // allocate address space
    fs.ptr = try FileStore.allocate_address_space(fs.unit_count * UNIT_SIZE);
    std.log.info("memory allocated at ptr {d}", .{ @ptrToInt(fs.ptr) });

    // map the entire existing file
    try FileStore.map(fs.ptr, fs.fd, 0, fs.block_count * BLOCK_SIZE);

    const page_count = fs.block_count * PAGES_PER_BLOCK;
    fs.pages = @ptrCast([*][constants.PAGE_SIZE]u8, fs.ptr)[0..page_count];
    return fs;
  }

  fn close(self: *FileStore) void {
    const end = self.unit_count * UNIT_SIZE;
    os.munmap(@ptrCast([*]align(std.mem.page_size)u8, self.ptr)[0..end]);
    os.close(self.fd);
  }

  fn allocate_address_space(size: u32) Error![*]align(std.mem.page_size)u8 {
    const prot = os.PROT.NONE;
    const flags = os.MAP.ANONYMOUS | os.MAP.PRIVATE;
    const buffer = try os.mmap(null, size, prot, flags, -1, 0);
    return buffer.ptr;
  }

  fn map(ptr: [*]align(std.mem.page_size)u8, fd: i32, offset: u32, size: u32) Error!void {
    const prot = os.PROT.READ | os.PROT.WRITE;
    const flags = os.MAP.SHARED | os.MAP.FIXED;
    std.log.info("mapping ptr {d}, size {d}, fd {d}, offset {d}", .{ @ptrToInt(ptr), size, fd, offset });

    assert(offset % std.mem.page_size == 0);
    const start = @intToPtr([*]align(std.mem.page_size)u8, @ptrToInt(ptr) + offset);
    const block = try os.mmap(start, size, prot, flags, fd, offset);
    std.log.info("got result from mmap: ptr {d} len {d}", .{ @ptrToInt(block.ptr), block.len });
    assert(block.ptr == ptr + offset);
  }

  fn get(self: *FileStore, id: u32) Error!*[constants.PAGE_SIZE]u8 {
    if (id < self.pages.len) {
      return &self.pages[id];
    } else if (id == self.pages.len) {
      try self.append_block();
      return &self.pages[id];
    } else {
      @panic("noncontiguous page request");
    }
  }

  fn append_block(self: *FileStore) Error!void {
    const start = self.block_count * BLOCK_SIZE;
    const end = start + BLOCK_SIZE;

    // first, we extend the actual file on disk
    try os.ftruncate(self.fd, end);
    
    if (self.block_count % BLOCKS_PER_UNIT == 0) {
      // need to unmap and remap
      @panic("not implemented");

      // os.munmap()
      // const data = os.mmap(null, BLOCK_SIZE, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED, self.fd, 0);
      // self.data = data
    } else {
      try FileStore.map(self.ptr, self.fd, start, BLOCK_SIZE);
    }

    self.block_count += 1;
    const page_count = self.block_count * PAGES_PER_BLOCK;
    self.pages = @ptrCast([*][constants.PAGE_SIZE]u8, self.ptr)[0..page_count];
  }
};

const PageList = std.ArrayList(*[constants.PAGE_SIZE]u8);

const MemoryStore = struct {
  pub const Error = Allocator.Error;

  list: PageList,
  allocator: Allocator,

  fn open(allocator: Allocator) Error!MemoryStore {
    const list = try PageList.initCapacity(allocator, PAGES_PER_BLOCK);
    return MemoryStore {
      .list = list,
      .allocator = allocator,
    };
  }

  fn close(self: *MemoryStore) void {
    for (self.list.items) |page| {
      self.allocator.destroy(page);
    }

    self.list.deinit();
  }

  fn get(self: *MemoryStore, id: u32) Error!*[constants.PAGE_SIZE]u8 {
    if (id < self.list.items.len) {
      return self.list.items[id];
    } else if (id == self.list.items.len) {
      const page = try self.allocator.create([constants.PAGE_SIZE]u8);
      try self.list.append(page);
      return page;
    } else {
      @panic("noncontiguous page request");
    }
  }
};
const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

const SkipListCursor = @import("./SkipListCursor.zig").SkipListCursor;

const utils = @import("./utils.zig");
const constants = @import("./constants.zig");

const Node = struct { key: []const u8, value: [32]u8 };

// Possible sources of new_siblings node keys:
// 1. the top-level key: []const u8 argument.
// 2. the target_keys array, all of whose elements are allocated and freed
//    by the entry SkipListp.insert() method.

pub const SkipList = struct {
    allocator: std.mem.Allocator,
    limit: u8,
    root_level: u16,
    root_value: [32]u8,
    env: lmdb.Environment,
    log: ?std.fs.File.Writer,
    log_prefix: std.ArrayList(u8),
    new_siblings: std.ArrayList(Node),
    target_keys: std.ArrayList(std.ArrayList(u8)),
    previous_child: std.ArrayList(u8),

    pub const Error = error {
        UnsupportedVersion,
        InvalidDatabase,
        InvalidFanoutDegree,
        Duplicate,
        InsertError,
    };

    pub const Options = struct {
        degree: u8 = 32,
        map_size: usize = 10485760,
        variant: constants.Variant = constants.Variant.UnorderedSet,
        log: ?std.fs.File.Writer = null,
    };
    
    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8, options: Options) !SkipList {
        var env = try lmdb.Environment.open(path, .{ .map_size = options.map_size });

        var skip_list = SkipList {
            .allocator = allocator,
            .limit = @intCast(u8, 256 / @intCast(u16, options.degree)),
            .root_level = 0,
            .root_value = undefined,
            .env = env,
            .log = options.log,
            .log_prefix = std.ArrayList(u8).init(allocator),
            .new_siblings = std.ArrayList(Node).init(allocator),
            .target_keys = std.ArrayList(std.ArrayList(u8)).init(allocator),
            .previous_child = std.ArrayList(u8).init(allocator),
        };

        // Initialize the metadata and root entries if necessary
        var txn = try lmdb.Transaction.open(env, false);
        errdefer txn.abort();

        var root_key: [2]u8 = undefined;
        if (try utils.getMetadata(txn)) |metadata| {
            if (metadata.degree != options.degree) {
                return error.InvalidDegree;
            } else if (metadata.variant != options.variant) {
                return error.InvalidVariant;
            }

            std.mem.writeIntBig(u16, &root_key, metadata.height);
            if (try txn.get(&root_key)) |root_value| {
                skip_list.root_level = metadata.height;
                std.mem.copy(u8, &skip_list.root_value, root_value);
            } else {
                return error.InvalidDatabase;
            }
        } else {
            skip_list.root_level = 0;
            Sha256.hash(&[0]u8 { }, &skip_list.root_value, .{});
            std.mem.writeIntBig(u16, &root_key, metadata.height);
            try txn.set(&root_key, &skip_list.root_value);
            try utils.setMetadata(txn, .{ .degree = options.degree, .variant = options.variant, .height = 0 });
            try txn.commit();
        }

        return skip_list;
    }
    
    pub fn close(self: *SkipList) void {
        self.env.close();
        self.prefix.deinit();
        self.new_siblings.deinit();
        self.target_keys.deinit();
        self.previous_child.deinit();
    }

    pub fn newCursor(self: *SkipList, read_only: bool) SkipListCursor {
        return SkipListCursor.open(self.allocator, self.env, read_only);
    }
    
    const InsertResultTag = enum { delete, update };
    const InsertResult = union (InsertResultTag) { delete: void, update: [32]u8 };

    pub fn insert(self: *SkipList, cursor: *SkipListCursor, key: []const u8, value: []const u8) !void {
        try self.log("insert({s}, {s})\n", .{ hex(key), hex(value) });
        try self.log("rootLevel {d}\n", .{ self.root_level });
        try self.prefix.resize(0);
        try self.indent();

        self.target_keys.resize(self.rootLevel);
        for (self.target_keys.items) |*item| {
            item.* = std.ArrayList(u8).init(self.allocator);
        }

        const result = try self.insertNode(cursor, key, value, self.root_level, &[_]u8 {});

        switch (result) {
            .update => |root_value| {
                std.mem.copy(u8, &self.root_value, &root_value);
            },
            .delete => {
                return Error.InsertError;
            },
        }
        
        try self.prefix.resize(0);

        try self.log("new root {d} -> {s}\n", .{ self.root_level, hex(&self.root_value) });
        try self.log("new_siblings: {d}\n", .{ self.new_siblings.items.len });
        for (self.new_siblings.items) |node| {
            try self.log("- {s} -> {s}\n", .{ hex(node.key), hex(&node.value) });
        }
        
        var new_sibling_count = self.new_siblings.items.len;
        while (new_sibling_count > 0) : (new_sibling_count = self.new_siblings.items.len) {
            try cursor.set(self.root_level, &[_]u8 {}, &self.root_value);
            for (self.new_siblings.items) |node| {
                try cursor.set(node.key, &node.value);
            }
            
            try self.hashRange(cursor, self.root_level, &[_]u8 { }, &self.root_value);
            self.root_level += 1;
            for (self.new_siblings.items) |node| {
                if (isSplit(&node.value)) {
                    var next = Node { .key = node.key, .value = undefined };
                    try self.hashRange(cursor, next.key, &next.value);
                    try self.new_siblings.append(next);
                }
            }
            
            try self.new_siblings.replaceRange(0, new_sibling_count, &.{});

            try self.log("new root {d} -> {s}\n", .{ self.root_level, hex(&self.root_value) });
            try self.log("new_siblings: {d}\n", .{ self.new_siblings.items.len });
            for (self.new_siblings.items) |node| {
                try self.log("- {s} -> {s}\n", .{ hex(node.key), hex(&node.value) });
            }
        }
        
        try cursor.set(self.root_level, &[_]u8 { }, &self.root_value);
        
        
        if (try cursor.goToNode(self.root_level, &[_]u8 { })) |last_key| {
            try self.log("last key: {s}\n", .{ hex(last_key) });
        } else {
            return Error.InsertError;
        }

        while (try cursor.goToPrevious()) |previous_key| {
            if (previous_key.len > 2) {
                break;
            } else if (utils.getLevel(previous_key) == self.root_level - 1) {
                try cursor.delete(self.root_level, &[_]u8 { });
                self.root_level -= 1;
                std.mem.copy(u8, &self.root_value, try cursor.getCurrentValue());
                try self.log("replace root key: {d}\n", .{ self.root_level });
            } else {
                return Error.InvalidDatabase;
            }
        }

        for (self.target_keys.items) |item| item.deinit();
        self.target_keys.resize(0);
    }
    
    fn indent(self: *SkipList) !void {
        try self.prefix.append('|');
        try self.prefix.append(' ');
    }

    fn insertNode(
        self: *SkipList,
        cursor: *SkipListCursor,
        key: []const u8,
        value: []const u8,
        level: u16,
        first_child: []const u8,
    ) !InsertResult {
        try self.log("insertNode({s}, {s})", .{ hex(key), hex(value) });
        try self.log("level: {d}\n", .{ level });
        if (first_child.len > 0) {
            try self.log("first_child: {s}\n", .{ hex(first_child) });
        } else {
            try self.log("first_child: null\n", .{ });
        }
        
        if (std.mem.eql(u8, key, first_child)) {
            return Error.Duplicate;
        }
        
        assert(std.mem.lessThan(u8, first_child, key));
        
        if (level == 0) {
            try cursor.set(0, key, value);
        
            var parent_value: [32]u8 = undefined;
            try self.hashRange(cursor, 0, first_child, &parent_value);
            
            if (isSplit(value)) {
                var node = Node { .key = key, .value = undefined };
                try self.hashRange(cursor, 0, key, &node.value);
                try self.new_siblings.append(node);
            }
            
            return InsertResult { .update = parent_value };
        }
        
        // var target = std.ArrayList(u8).init(allocator);
        // defer target.deinit();
        var target = &self.target_keys[level];

        try self.findTargetKey(cursor, level, first_child, key);
        try self.log("target: {s}\n", .{ hex(target.items) });
        
        const is_left_edge = first_child.len == 0;
        try self.log("is_left_edge: {bool}", .{ is_left_edge });

        const is_first_child = std.mem.eql(u8, target.items, first_child);
        try self.log("is_first_child: {bool}", .{ is_first_child });

        const depth = self.prefix.items.len;
        try self.indent();
        
        const result = try self.insertNode(cursor, key, value, level - 1, target.items);
        
        try self.prefix.resize(depth);

        switch (result) {
            InsertResult.delete => try self.log("result: delete\n", .{ }),
            InsertResult.update => |parent_value| try self.log("result: update ({s})\n", .{ hex(parent_value) }),
        }
        
        const old_sibling_count = self.new_siblings.items.len;
        
        var parent_result: InsertResult = undefined;
        
        switch (result) {
            InsertResult.delete => {
                assert(!is_left_edge or !is_first_child);
                
                // delete the entry and move to the previous child
                try utils.copy(&self.previous_child, target.items);
                try cursor.goToNode(level, self.previous_child.items);
                try cursor.delete(level, self.previous_child.items);
                while (try cursor.goToPrevious()) |previous_child| {
                    if (try cursor.get(level - 1, previous_child)) |previous_grand_child_value| {
                        if (previous_child.len == 0 or self.isSplit(previous_grand_child_value)) {
                            try utils.copy(&self.previous_child, previous_child);
                            break;
                        }
                    }
                    
                    try cursor.delete(previous_child);
                }
                
                // target now holds the previous child key
                try self.log("previous_child {s}", .{ hex(self.previous_child.items) });
                
                for (self.new_siblings.items) |node| {
                    try cursor.set(node.key, &node.value);
                }
                
                var previous_child_value: [32]u8 = undefined;
                try self.hashRange(cursor, level - 1, self.previous_child.items, &previous_child_value);
                try cursor.set(self.previous_child.items, &previous_child_value);
                
                if (is_first_child or std.mem.lessThan(u8, target.items, first_child)) {
                    // if target is the first child, or if we've deleted the previous siblings,
                    // then we also have to delete our parent.
                    if (self.isSplit(&previous_child_value)) {
                        // TODO: clone target.items somehow :/
                        var node = Node { .key = target.items, .value = undefined };
                        try self.hashRange(cursor, level, target.items, &node.value);
                        try self.new_siblings.append(node);
                    }
                    
                    parent_result = InsertResult { .delete = {} };
                } else if (std.mem.eql(u8, target.items, first_child)) {
                    // if the target is not the first child,
                    // we still need to check if the previous child was the first child.
                    if (is_left_edge or self.isSplit(&previous_child_value)) {
                        parent_result = InsertResult { .update = undefined };
                        try self.hashRange(cursor, level, first_child, &parent_result.update);
                    } else {
                        parent_result = InsertResult { .delete = {} };
                    }
                } else {
                    parent_result = InsertResult { .update = undefined };
                    try self.hashRange(cursor, first_child, &parent_result.update);
                    if (self.isSplit(&previous_child_value)) {
                        var node = Node { .key = target.items, .value = undefined };
                        try self.hashRange(cursor, target.items, &node.value);
                        try self.new_siblings.append(node);
                    }
                }
            },
            InsertResult.update => |parent_value| {
                try cursor.set(target.items, &parent_value);
                
                for (self.new_siblings.items) |node| try cursor.set(node.key, &node.value);
                
                const is_target_split = self.isSplit(&parent_value);
                try self.log("is_target_split: {bool}", .{ is_target_split });
                
                if (is_first_child) {
                    // is_first_child means either targetKey's original value was already a split,
                    // or is_left_edge is true.
                    if (is_target_split or is_left_edge) {
                        parent_result = InsertResult { .update = undefined };
                        try self.hashRange(cursor, level, target.items, &parent_result.update);
                    } else {
                        // !is_target_split && !isLeftEdge means that the current target
                        // has lost its status as a split and needs to get merged left.
                        parent_result = InsertResult{ .delete = {} };
                    }
                } else {
                    parent_result = InsertResult { .update = undefined };
                    try self.hashRange(cursor, first_child, &parent_result.update);
                    
                    if (is_target_split) {
                        var node = Node { .key = target.items, .value = undefined };
                        try self.hashRange(cursor, level, target.items, &node.value);
                        try self.new_siblings.append(node);
                    }
                }
            }
        }
        
        for (self.new_siblings.items[0..old_sibling_count]) |old_sibling| {
            if (self.isSplit(&old_sibling.value)) {
                var node = Node { .key = old_sibling.key, .value = undefined };
                try self.hashRange(cursor, old_sibling.key, &node.value);
                try self.new_children.append(node);
            }
        }
        
        try self.new_siblings.replaceRange(0, old_sibling_count, &.{});
        return parent_result;
    }
    
    fn findTargetKey(
        self: *SkipList,
        cursor: *SkipListCursor,
        level: u16,
        first_child: []const u8,
        key: []const u8,
    ) !void {
        const target = &self.target_keys[level];
        try utils.copy(target, first_child);

        try cursor.goToNode(level, first_child);
        while (try cursor.goToNext()) |next_child| {
            if (std.mem.lessThan(u8, key, next_child)) {
                return;
            } else {
                try utils.copy(target, next_child);
            }
        }
    }
    
    fn hashRange(
        self: *SkipList,
        cursor: *SkipListCursor,
        level: u16,
        first_child: []const u8,
        result: *[32]u8,
    ) !void {
        try self.log("{s}hashRange({d}, {s})\n", .{ level, hex(first_child) });
        
        try cursor.toGoNode(level, first_child);
        var digest = Sha256.init(.{});
        
        const value = try cursor.getCurrentValue();
        try self.log("- hashing {s} -> {s}\n", .{ hex(first_child), hex(value) });
        digest.update(value);

        while (try cursor.goToNext()) |next_key| {
            const next_value = cursor.getCurrentValue();
            if (isSplit(next_value)) break;
            try self.log("- hashing {s} -> {s}\n", .{ hex(next_key), hex( next_value) });
            digest.update(next_value);
        }

        digest.final(result);
        try self.log("--------------------------- {s}\n", .{ hex(result) });
    }

    fn isSplit(self: *const SkipList, value: []const u8) bool {
        return value[value.len - 1] < self.limit;
    }
    
    fn log(self: *const SkipList, comptime format: []const u8, args: anytype) !void {
        if (self.log) |writer| {
            try writer.print("{s}", .{ self.prefix.items });
            try writer.print(format, args);
        }
    }
};


test "initialize SkipList" {
    const allocator = std.heap.c_allocator;
    
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n", .{});
    
    var tmp = std.testing.tmpDir(.{});
    const reference_path = try utils.resolvePath(allocator, tmp.dir, "reference.mdb");
    defer allocator.free(reference_path);
}
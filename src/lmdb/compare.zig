const std = @import("std");

const Environment = @import("./environment.zig").Environment;
const Transaction = @import("./transaction.zig").Transaction;
const Cursor = @import("./cursor.zig").Cursor;

const Options = struct {
  log: ?std.fs.File.Writer = null,
  mapSize: usize = 10485760,
};

pub fn compareEntries(comptime K: usize, comptime V: usize, pathA: []const u8, pathB: []const u8, options: Options) !usize {
  if (options.log) |log| try log.print("{s:-<80}\n", .{ "START DIFF " });

  var differences: usize = 0;

  var envA = try Environment(K, V).open(pathA, .{ .mapSize = options.mapSize });
  var envB = try Environment(K, V).open(pathB, .{ .mapSize = options.mapSize });
  var txnA = try Transaction(K, V).open(envA, true);
  var txnB = try Transaction(K, V).open(envB, true);
  var dbiA = try txnA.openDbi();
  var dbiB = try txnB.openDbi();
  var cursorA = try Cursor(K, V).open(txnA, dbiA);
  var cursorB = try Cursor(K, V).open(txnB, dbiB);

  var keyA = try cursorA.goToFirst();
  var keyB = try cursorB.goToFirst();
  while (keyA != null or keyB != null) {
    if (keyA) |bytesA| {
      const valueA = cursorA.getCurrentValue().?;
      if (keyB) |bytesB| {
        const valueB = cursorB.getCurrentValue().?;
        switch (std.mem.order(u8, bytesA, bytesB)) {
          .lt => {
            differences += 1;
            if (options.log) |log| try log.print("{s}\n- a: {s}\n- b: null\n", .{
              std.fmt.fmtSliceHexLower(bytesA),
              std.fmt.fmtSliceHexLower(valueA),
            });

            keyA = try cursorA.goToNext();
          },
          .gt => {
            differences += 1;
            if (options.log) |log| try log.print("{s}\n- a: null\n- b: {s}\n", .{
              std.fmt.fmtSliceHexLower(bytesA),
              std.fmt.fmtSliceHexLower(valueB),
            });

            keyB = try cursorB.goToNext();
          },
          .eq =>{
            if (!std.mem.eql(u8, valueA, valueB)) {
              differences += 1;
              if (options.log) |log| try log.print("{s}\n- a: {s}\n- b: {s}\n", .{
                std.fmt.fmtSliceHexLower(bytesA),
                std.fmt.fmtSliceHexLower(valueA),
                std.fmt.fmtSliceHexLower(valueB),
              });
            }

            keyA = try cursorA.goToNext();
            keyB = try cursorB.goToNext();
          }
        }
      } else {
        differences += 1;
        if (options.log) |log| try log.print("{s}\n- a: {s}\n- b: null\n", .{
          std.fmt.fmtSliceHexLower(bytesA),
          std.fmt.fmtSliceHexLower(valueA),
        });

        keyA = try cursorA.goToNext();
      }
    } else {
      if (keyB) |bytesB| {
        const valueB = cursorB.getCurrentValue().?;
        differences += 1;
        if (options.log) |log| try log.print("{s}\n- a: null\n- b: {s}\n", .{
          std.fmt.fmtSliceHexLower(bytesB),
          std.fmt.fmtSliceHexLower(valueB),
        });

        keyB = try cursorB.goToNext();
      } else {
        break;
      }
    }
  }

  if (options.log) |log| try log.print("{s:-<80}\n", .{ "END DIFF " });

  cursorA.close();
  cursorB.close();
  txnA.abort();
  txnB.abort();
  envA.close();
  envB.close();

  return differences;
}


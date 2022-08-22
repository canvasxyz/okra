const std = @import("std");

const Environment = @import("./environment.zig").Environment;
const Transaction = @import("./transaction.zig").Transaction;
const Cursor = @import("./cursor.zig").Cursor;

const Options = struct {
  log: ?std.fs.File.Writer = null,
};

pub fn compareEntries(comptime K: usize, comptime V: usize, envA: Environment(K, V), envB: Environment(K, V), options: Options) !usize {
  if (options.log) |log| try log.print("{s:-<80}\n", .{ "START DIFF " });

  var differences: usize = 0;

  var txnA = try Transaction(K, V).open(envA, true);
  var txnB = try Transaction(K, V).open(envB, true);
  var dbiA = try txnA.openDBI();
  var dbiB = try txnB.openDBI();
  var cursorA = try Cursor(K, V).open(txnA, dbiA);
  var cursorB = try Cursor(K, V).open(txnB, dbiB);

  var keyA = try cursorA.goToFirst();
  var keyB = try cursorB.goToFirst();
  while (keyA != null or keyB != null) {
    if (keyA) |bytesA| {
      const valueA = try cursorA.getCurrentValue();
      if (keyB) |bytesB| {
        const valueB = try cursorB.getCurrentValue();
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
        const valueB = try cursorB.getCurrentValue();
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

  return differences;
}


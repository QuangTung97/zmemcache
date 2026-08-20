const std = @import("std");

pub const SystemRoot = struct {};

fn incCounterAsync(counter: *std.atomic.Value(u64)) void {
    for (0..10_000) |_| {
        _ = counter.fetchAdd(1, .seq_cst);
    }
}

test "hello" {
    const io = std.testing.io;

    var group = std.Io.Group.init;
    defer group.cancel(io);

    var counter = std.atomic.Value(u64).init(0);
    for (0..10) |_| {
        try group.concurrent(io, incCounterAsync, .{&counter});
    }
    try group.await(io);
    try std.testing.expectEqual(10 * 10_000, counter.load(.seq_cst));
}

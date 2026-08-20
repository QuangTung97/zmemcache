const std = @import("std");

pub const SystemRoot = struct {};

fn incCounterAsync(counter: *u64) void {
    for (0..50_000) |_| {
        counter.* += 1;
    }
}

test "hello" {
    const io = std.testing.io;

    var group = std.Io.Group.init;
    defer group.cancel(io);

    var counter: u64 = 0;
    for (0..10) |_| {
        try group.concurrent(io, incCounterAsync, .{&counter});
    }
    try group.await(io);
    // try std.testing.expectEqual(10 * 10_000, counter);
}

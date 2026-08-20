const std = @import("std");

pub const SystemRoot = struct {};

test "hello" {
    try std.testing.expectEqual(1, 1);
}

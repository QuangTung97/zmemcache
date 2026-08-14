const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn expectIteratorValues(T: type, expected: []const T, iter: anytype) !void {
    const gpa = std.testing.allocator;

    var values = std.ArrayList(T).empty;
    defer values.deinit(gpa);

    var it = iter;
    while (it.next()) |x| {
        try values.append(gpa, x);
    }

    try std.testing.expectEqualSlices(T, expected, values.items);
}

test "expect iterator values" {
    const arr = [_]u64{ 11, 12, 13, 14 };

    const IterTest = struct {
        index: usize,
        data: []const u64,
        fn next(self: *@This()) ?u64 {
            if (self.index >= self.data.len) {
                return null;
            }
            const result = self.data[self.index];
            self.index += 1;
            return result;
        }
    };

    const iter = IterTest{
        .index = 0,
        .data = &arr,
    };

    try expectIteratorValues(u64, &.{ 11, 12, 13, 14 }, iter);
}

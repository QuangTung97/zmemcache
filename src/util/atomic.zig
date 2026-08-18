const std = @import("std");

pub fn Value(T: type) type {
    return struct {
        const Self = @This();

        _value: std.atomic.Value(T),

        pub fn init(v: T) Self {
            return .{
                ._value = .init(v),
            };
        }

        pub fn load(self: *const Self) T {
            return self._value.load(.seq_cst);
        }

        pub fn store(self: *Self, value: T) void {
            self._value.store(value, .seq_cst);
        }

        pub fn fetchAdd(self: *Self, num: T) T {
            return self._value.fetchAdd(num, .seq_cst);
        }

        pub fn fetchSub(self: *Self, num: T) T {
            return self._value.fetchSub(num, .seq_cst);
        }

        pub fn cmpxchgWeak(self: *Self, expected: T, new_val: T) ?T {
            return self._value.cmpxchgWeak(
                expected,
                new_val,
                .seq_cst,
                .seq_cst,
            );
        }
    };
}

test "normal" {
    var v = Value(u64).init(11);
    try std.testing.expectEqual(11, v.load());

    v.store(12);
    try std.testing.expectEqual(12, v.load());

    try std.testing.expectEqual(12, v.fetchAdd(2));
    try std.testing.expectEqual(14, v.load());

    try std.testing.expectEqual(14, v.fetchSub(3));
    try std.testing.expectEqual(11, v.load());
}

const std = @import("std");

pub fn Iterator(T: type) type {
    return struct {
        const Self = @This();
        _ptr: *anyopaque,
        _yield: *const fn (self: *anyopaque, item: T) bool,

        pub fn init(ptr: anytype) Self {
            const S = @TypeOf(ptr.*);
            return .{
                ._ptr = ptr,
                ._yield = newIteratorImpl(T, S).yield_any,
            };
        }

        pub fn yield(self: Self, item: T) bool {
            return self._yield(self._ptr, item);
        }
    };
}

fn newIteratorImpl(T: type, S: type) type {
    return struct {
        fn yield_any(self_any: *anyopaque, item: T) bool {
            const self: *S = @ptrCast(@alignCast(self_any));
            return self.yield(item);
        }
    };
}

test "normal" {
    var ctx = struct {
        counter: u64,
        fn yield(self: *@This(), x: u64) bool {
            self.counter += x;
            return true;
        }
    }{
        .counter = 0,
    };

    const iter = Iterator(u64).init(&ctx);
    try std.testing.expect(iter.yield(11));
    try std.testing.expect(iter.yield(12));
    try std.testing.expect(iter.yield(13));

    try std.testing.expectEqual(36, ctx.counter);
}

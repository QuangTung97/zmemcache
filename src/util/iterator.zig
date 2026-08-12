const std = @import("std");

pub fn Iterator(T: type) type {
    return struct {
        _ctx: *anyopaque,
        _yield: *const fn (ctx: *anyopaque, x: T) bool,

        const Self = @This();

        pub fn init(ctx: anytype) Self {
            const CtxType = @TypeOf(ctx.*);
            return .{
                ._ctx = ctx,
                ._yield = CtxType.yield,
            };
        }

        pub fn yield(self: Self, x: T) bool {
            return self._yield(self._ctx, x);
        }
    };
}

const expectEqual = std.testing.expectEqual;

test "iterator" {
    const TestCtx = struct {
        sum: i32 = 0,
        fn yield(ctx: *anyopaque, x: i32) bool {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.sum = c.sum + x;
            return true;
        }
    };
    var ctx = TestCtx{};

    const callback = Iterator(i32).init(&ctx);
    try expectEqual(true, callback.yield(11));
    try expectEqual(true, callback.yield(12));
    try expectEqual(true, callback.yield(13));

    try expectEqual(36, ctx.sum);
}

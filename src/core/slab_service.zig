const types = @import("types.zig");

pub fn ISlabService(T: type) type {
    return struct {
        self: *T,
        private: struct {
            putItem: *const fn (self: *T, item: *types.Item) void,
            touchItem: *const fn (self: *T, item: *types.Item) void,
            deleteItem: *const fn (self: *T, item: *types.Item) void,
        },
    };
}

pub fn NewISlabService(T: type, obj: *T) ISlabService(T) {
    return ISlabService(T){
        .self = obj,
        .private = .{
            .putItem = T.putItem,
            .touchItem = T.touchItem,
            .deleteItem = T.deleteItem,
        },
    };
}

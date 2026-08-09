const types = @import("types.zig");

pub fn ISlabService(T: type) type {
    return struct {
        putItem: fn (self: *T, item: *types.Item) void,
        touchItem: fn (self: *T, item: *types.Item) void,
        deleteItem: fn (self: *T, item: *types.Item) void,
    };
}

pub fn NewISlabService(T: type) ISlabService(T) {
    return ISlabService(T){
        .putItem = T.putItem,
        .touchItem = T.touchItem,
        .deleteItem = T.deleteItem,
    };
}

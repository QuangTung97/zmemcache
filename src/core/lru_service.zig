const types = @import("types.zig");

pub fn ILruService(T: type) type {
    return struct {
        private: struct {
            self: *T,
            putItem: *const fn (self: *T, item: *types.Item) void,
            touchItem: *const fn (self: *T, item: *types.Item) void,
            deleteItem: *const fn (self: *T, item: *types.Item) void,
        },

        const Self = @This();

        pub fn put(self: *Self, item: *types.Item) void {
            self.private.putItem(self.private.self, item);
        }

        pub fn touch(self: *Self, item: *types.Item) void {
            self.private.touchItem(self.private.self, item);
        }

        pub fn delete(self: *Self, item: *types.Item) void {
            self.private.deleteItem(self.private.self, item);
        }
    };
}

pub fn NewILruService(T: type, obj: *T) ILruService(T) {
    return ILruService(T){
        .self = obj,
        .private = .{
            .putItem = T.put,
            .touchItem = T.touch,
            .deleteItem = T.delete,
        },
    };
}

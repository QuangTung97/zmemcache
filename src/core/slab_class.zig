const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Item = types.Item;
const SlabClass = types.SlabClass;

pub const SlabSize = struct {
    slab_class: SlabClass,
    item_size: usize,

    pub fn init(slab: u32, size: usize) @This() {
        return .{
            .slab_class = SlabClass.init(slab),
            .item_size = size,
        };
    }
};

pub const SlabClassConfig = struct {
    const Self = @This();
    const ClassList = std.ArrayList(usize);

    _gpa: Allocator,
    _all_classes: ClassList,

    pub fn init(gpa: Allocator, min_size: usize, max_size: usize, ratio: f64) !Self {
        if (!Item.Alignment.check(max_size)) {
            @panic("slab max size is not aligned");
        }

        var all_classes = ClassList.empty;

        var current: f64 = @floatFromInt(min_size);
        const max_size_float: f64 = @floatFromInt(max_size);
        var last_size: usize = 0;

        while (current <= max_size_float) {
            const current_int: usize = @intFromFloat(@ceil(current));

            const item_align = Item.Alignment.toByteUnits();
            const size_multiple = (current_int + item_align - 1) / item_align;
            const size_aligned = size_multiple * item_align;
            last_size = size_aligned;

            try all_classes.append(gpa, size_aligned);
            current = current * ratio;
        }

        if (max_size != last_size) {
            try all_classes.append(gpa, max_size);
        }

        return .{
            ._gpa = gpa,
            ._all_classes = all_classes,
        };
    }

    pub fn deinit(self: *Self) void {
        self._all_classes.deinit(self._gpa);
    }

    pub fn getSlab(self: *Self, item_size: usize) SlabSize {
        const index = self.lowerBound(item_size);
        const slab: u32 = @intCast(index);
        return .init(slab, self._all_classes.items[index]);
    }

    fn compareFunc(key: usize, item: usize) std.math.Order {
        return std.math.order(key, item);
    }

    fn lowerBound(self: *Self, key: usize) usize {
        return std.sort.lowerBound(
            usize,
            self._all_classes.items,
            key,
            compareFunc,
        );
    }
};

const expectEqual = std.testing.expectEqual;

test "normal" {
    const gpa = std.testing.allocator;
    var conf = try SlabClassConfig.init(gpa, 96, 1024, 1.5);
    defer conf.deinit();

    var expectedClasses = [_]usize{
        96,   144, 216,
        328,  488, 736,
        1024,
    };
    try std.testing.expectEqualSlices(usize, &expectedClasses, conf._all_classes.items);

    for (conf._all_classes.items) |x| {
        try std.testing.expect(Item.Alignment.check(x));
    }

    // get slab class
    try expectEqual(SlabSize.init(0, 96), conf.getSlab(95));
    try expectEqual(SlabSize.init(0, 96), conf.getSlab(50));
    try expectEqual(SlabSize.init(0, 96), conf.getSlab(96));
    try expectEqual(SlabSize.init(1, 144), conf.getSlab(97));

    try expectEqual(SlabSize.init(4, 488), conf.getSlab(488));
    try expectEqual(SlabSize.init(5, 736), conf.getSlab(489));
}

test "max size is included" {
    const gpa = std.testing.allocator;
    var conf = try SlabClassConfig.init(gpa, 256, 1024, 2);
    defer conf.deinit();

    var expectedClasses = [_]usize{ 256, 512, 1024 };
    try std.testing.expectEqualSlices(usize, &expectedClasses, conf._all_classes.items);

    for (conf._all_classes.items) |x| {
        try std.testing.expect(Item.Alignment.check(x));
    }
}

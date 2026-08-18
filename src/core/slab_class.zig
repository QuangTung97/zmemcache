const std = @import("std");
const types = @import("types.zig");
const zutil = @import("zutil");

const Allocator = std.mem.Allocator;
const Item = types.Item;
const SlabClass = types.SlabClass;
const CachePadding = types.CachePadding;

pub const SlabSize = struct {
    slab_class: SlabClass,
    item_size: usize,

    pub fn init(slab: SlabClass.IntType, size: usize) @This() {
        return .{
            .slab_class = SlabClass.init(slab),
            .item_size = size,
        };
    }
};

pub const SlabSizeIter = struct {
    _config: *const SlabClassConfig,
    _current: SlabClass,
    pub fn next(self: *@This()) ?SlabSize {
        if (self._current.slab >= self._config._all_classes.items.len) {
            return null;
        }
        const item_size = self._config._all_classes.items[self._current.slab];
        const result = SlabSize{
            .slab_class = self._current,
            .item_size = item_size,
        };
        self._current.slab += 1;
        return result;
    }
};

pub const SlabClassConfig = struct {
    const Self = @This();
    const ClassList = std.ArrayList(usize);

    _before_padding: CachePadding = undefined,
    _gpa: Allocator,
    _all_classes: ClassList,
    _after_padding: CachePadding = undefined,

    pub fn init(gpa: Allocator, min_size: usize, max_size: usize, ratio: f64) !Self {
        zutil.runtimeAssert(Item.Alignment.check(max_size));

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

        zutil.runtimeAssert(SlabClass.MaxNumClass <= SlabClass.MaxIntValue);
        zutil.runtimeAssert(all_classes.items.len <= SlabClass.MaxNumClass);

        return .{
            ._gpa = gpa,
            ._all_classes = all_classes,
        };
    }

    pub fn deinit(self: *Self) void {
        self._all_classes.deinit(self._gpa);
    }

    pub fn getSlabFromItemSize(self: *const Self, item_size: usize) SlabSize {
        const index = self.lowerBound(item_size);

        std.debug.assert(index <= SlabClass.MaxNumClass);
        const slab: SlabClass.IntType = @intCast(index);

        return .init(slab, self._all_classes.items[index]);
    }

    pub fn getItemSizeOfSlab(self: *const Self, slab: SlabClass) usize {
        return self._all_classes.items[slab.slab];
    }

    fn compareFunc(key: usize, item: usize) std.math.Order {
        return std.math.order(key, item);
    }

    fn lowerBound(self: *const Self, key: usize) usize {
        for (self._all_classes.items, 0..) |item_size, index| {
            if (item_size >= key) {
                return index;
            }
        }
        @panic("item size is too big");
    }

    pub fn getAllSlabClasses(self: *const Self) SlabSizeIter {
        return .{
            ._config = self,
            ._current = SlabClass.init(0),
        };
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
    try expectEqual(SlabSize.init(0, 96), conf.getSlabFromItemSize(95));
    try expectEqual(SlabSize.init(0, 96), conf.getSlabFromItemSize(50));
    try expectEqual(SlabSize.init(0, 96), conf.getSlabFromItemSize(96));
    try expectEqual(SlabSize.init(1, 144), conf.getSlabFromItemSize(97));

    try expectEqual(SlabSize.init(4, 488), conf.getSlabFromItemSize(488));
    try expectEqual(SlabSize.init(5, 736), conf.getSlabFromItemSize(489));

    try expectEqual(96, conf.getItemSizeOfSlab(SlabClass.init(0)));
    try expectEqual(144, conf.getItemSizeOfSlab(SlabClass.init(1)));

    // get all sizes
    try zutil.expectIteratorValues(SlabSize, &.{
        SlabSize.init(0, 96),
        SlabSize.init(1, 144),
        SlabSize.init(2, 216),
        SlabSize.init(3, 328),
        SlabSize.init(4, 488),
        SlabSize.init(5, 736),
        SlabSize.init(6, 1024),
    }, conf.getAllSlabClasses());

    // test lower bound
    try expectEqual(0, conf.lowerBound(95));
    try expectEqual(0, conf.lowerBound(96));
    try expectEqual(1, conf.lowerBound(97));

    try expectEqual(3, conf.lowerBound(327));
    try expectEqual(3, conf.lowerBound(328));
    try expectEqual(4, conf.lowerBound(329));
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

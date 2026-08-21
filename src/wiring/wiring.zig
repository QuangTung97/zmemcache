const std = @import("std");
const zcore = @import("zcore");

const Allocator = std.mem.Allocator;

pub const SystemRoot = struct {
    const Self = @This();

    const Hasher = zcore.types.RealHashFunc;
    const ItemLocks = zcore.item_lock.ItemLockService;
    const TouchList = zcore.touch_list.TouchRingBuffer;

    const LruSvc = zcore.modern_lru.ModernLru(
        TouchList,
        zcore.touch_list.NewTouchListFuncs(TouchList),
        1,
    );

    const ItemSvc = zcore.item_service.ItemService(
        Hasher,
        ItemLocks,
        LruSvc,
        zcore.types.NewHashFunc(Hasher),
        zcore.item_lock.NewItemLockFuncs(ItemLocks),
        zcore.lru_service.NewLruFuncs(LruSvc),
    );

    pub const Config = struct {
        num_pages: u64,

        page_size_log2: u6 = 20, // 1MB

        min_slab_size: u64 = 96,
        slab_growth_factor: f64 = 1.5,

        num_mutex_log2: u6 = 16, // 2^16 mutexes => 256KB
        touch_list_size_log2: u6 = 12, // 4096

        hot_ratio: f64 = 0.2,
        warm_ratio: f64 = 0.4,
        max_repeated_in_warm: usize = 5,
    };

    io: std.Io,
    gpa: Allocator,
    hasher: Hasher,
    slab_conf: *zcore.slab_class.SlabClassConfig,
    pager: *zcore.page.GlobalPager,
    locker: ItemLocks,
    touch_list: *TouchList,
    lru: LruSvc,
    item_svc: ItemSvc,
    group_run: std.Io.Group,

    pub fn init(io: std.Io, gpa: Allocator, config: Config) !*Self {
        const page_size = @as(u64, 1) << config.page_size_log2;
        const avg_num_items = (page_size * config.num_pages) / (config.min_slab_size * 2);
        const num_items_log2: u6 = std.math.log2_int_ceil(u63, @intCast(avg_num_items));
        const num_mutex_log2 = @min(config.num_mutex_log2, num_items_log2);

        const slab_conf = try gpa.create(zcore.slab_class.SlabClassConfig);
        slab_conf.* = try zcore.slab_class.SlabClassConfig.init(
            gpa,
            config.min_slab_size,
            page_size,
            config.slab_growth_factor,
        );

        const pager = try zcore.page.GlobalPager.init(
            io,
            gpa,
            config.page_size_log2,
            config.num_pages,
        );

        const touch_list = try gpa.create(TouchList);
        touch_list.* = try TouchList.init(
            io,
            gpa,
            config.touch_list_size_log2,
        );

        const root = try gpa.create(Self);
        root.* = .{
            .io = io,
            .gpa = gpa,
            .hasher = Hasher.init(io),
            .slab_conf = slab_conf,
            .pager = pager,
            .locker = try zcore.item_lock.ItemLockService.init(
                io,
                gpa,
                num_mutex_log2,
            ),
            .touch_list = touch_list,
            .lru = try LruSvc.init(
                io,
                gpa,
                pager,
                .{touch_list},
                .{
                    .num_classes = slab_conf.getNumSlabClasses(),
                    .hot_ratio = config.hot_ratio,
                    .warm_ratio = config.warm_ratio,
                    .max_repeated_in_warm = config.max_repeated_in_warm,
                },
            ),
            .item_svc = undefined,
            .group_run = .init,
        };

        root.item_svc = try ItemSvc.init(
            io,
            gpa,
            &root.hasher,
            root.slab_conf,
            root.pager,
            &root.locker,
            &root.lru,
            .{
                .hash_size_log = num_items_log2,
            },
        );

        // run background thread
        try root.group_run.concurrent(io, runTouchRunner, .{root});

        return root;
    }

    fn runTouchRunner(self: *Self) void {
        while (true) {
            const err_item = self.touch_list.pop();
            const touch_item = err_item catch return;
            self.lru.asyncTouchItem(touch_item);
        }
    }

    pub fn deinit(self: *Self) void {
        // close touch list
        self.touch_list.close();

        self.group_run.cancel(self.io);

        self.item_svc.deinit();
        self.lru.deinit();

        self.touch_list.deinit();
        self.gpa.destroy(self.touch_list);

        self.locker.deinit();
        self.pager.deinit();

        self.slab_conf.deinit();
        self.gpa.destroy(self.slab_conf);

        self.gpa.destroy(self);
    }
};

const ItemGetter = zcore.item_service.ItemGetter;

const expectEqual = std.testing.expectEqual;

test "simple get set" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var root = try SystemRoot.init(io, gpa, .{
        .num_pages = 10, // 10MB
    });
    defer root.deinit();

    const svc = &root.item_svc;

    const key01 = "test_key01";
    const key02 = "test_key02";
    const value01 = "test_value_01";

    // get not found
    var getter1 = svc.get(key01);
    try expectEqual(ItemGetter.NotFound, std.meta.activeTag(getter1));

    // set
    const setter1 = svc.put(key01, value01.len).?;
    @memcpy(setter1.item.getValue(), value01);
    svc.finishPut(setter1);

    // get again
    getter1 = svc.get(key01);
    try expectEqual(ItemGetter.Found, std.meta.activeTag(getter1));

    try std.testing.expectEqualStrings(key01, getter1.Found.item.getKey());
    try std.testing.expectEqualStrings(value01, getter1.Found.item.getValue());

    svc.finishGet(getter1.Found);

    // get key02
    const getter2 = svc.get(key02);
    try expectEqual(ItemGetter.NotFound, std.meta.activeTag(getter2));
}

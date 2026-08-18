const std = @import("std");
const zutil = @import("zutil");
const types = @import("types.zig");
const zpage = @import("page.zig");

const Allocator = std.mem.Allocator;
const ListHead = zutil.ListHead;
const SlabClass = types.SlabClass;
const PageNum = zpage.PageNum;

pub const ModernLru = struct {
    const Self = @This();

    const SlabClassState = struct {
        mutex: std.Io.Mutex,
        is_locked: bool,

        free_list: ListHead,
        hot_list: ListHead,
        warm_list: ListHead,
        cold_list: ListHead,

        num_free: usize,
        num_hot: usize,
        num_warm: usize,
        num_cold: usize,

        page_list: ListHead,
        moving_page: ?PageNum,

        _padding: [8 * 7]u8 = undefined,
    };

    _io: std.Io,
    _gpa: Allocator,
    _all_classes: []SlabClassState,

    pub fn init(io: std.Io, gpa: Allocator, num_classes: usize) !Self {
        zutil.runtimeAssert(num_classes <= SlabClass.MaxNumClass);

        const all_classes = try gpa.alloc(SlabClassState, num_classes);
        for (all_classes) |*s| {
            s.* = .{
                .mutex = .init,
                .is_locked = false,

                .free_list = undefined,
                .hot_list = undefined,
                .warm_list = undefined,
                .cold_list = undefined,

                .num_free = 0,
                .num_hot = 0,
                .num_warm = 0,
                .num_cold = 0,

                .page_list = undefined,
                .moving_page = null,
            };

            ListHead.initHeader(&s.free_list);
            ListHead.initHeader(&s.hot_list);
            ListHead.initHeader(&s.warm_list);
            ListHead.initHeader(&s.cold_list);

            ListHead.initHeader(&s.page_list);

            ListHead.validateInit(&s.free_list);
            ListHead.validateInit(&s.hot_list);
            ListHead.validateInit(&s.warm_list);
            ListHead.validateInit(&s.cold_list);
            ListHead.validateInit(&s.page_list);
        }

        return .{
            ._io = io,
            ._gpa = gpa,
            ._all_classes = all_classes,
        };
    }

    pub fn deinit(self: *Self) void {
        self._gpa.free(self._all_classes);
    }

    pub fn lockSlab(self: *Self, slab: SlabClass) void {
        const state = self.getSlabState(slab);
        state.mutex.lockUncancelable(self._io);
        state.is_locked = true;
    }

    pub fn isSlabLocked(self: *Self, slab: SlabClass) bool {
        const state = self.getSlabState(slab);
        return state.is_locked;
    }

    pub fn unlockSlab(self: *Self, slab: SlabClass) void {
        const state = self.getSlabState(slab);
        state.is_locked = false;
        state.mutex.unlock(self._io);
    }

    fn getSlabState(self: *Self, slab: SlabClass) *SlabClassState {
        return &self._all_classes[slab.slab];
    }
};

const expectEqual = std.testing.expectEqual;

test "slab class state size" {
    try expectEqual(64 * 3, @sizeOf(ModernLru.SlabClassState));
}

// TODO check impl

test "locking" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var s = try ModernLru.init(io, gpa, 5);
    defer s.deinit();

    const slab0 = SlabClass.init(0);
    const slab1 = SlabClass.init(1);

    try expectEqual(false, s.isSlabLocked(slab0));
    try expectEqual(false, s.isSlabLocked(slab1));

    s.lockSlab(slab1);

    try expectEqual(false, s.isSlabLocked(slab0));
    try expectEqual(true, s.isSlabLocked(slab1));

    s.unlockSlab(slab1);

    try expectEqual(false, s.isSlabLocked(slab0));
    try expectEqual(false, s.isSlabLocked(slab1));
}

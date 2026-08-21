const std = @import("std");
const types = @import("types.zig");
const zutil = @import("zutil");
const zatomic = zutil.atomic;

const Item = types.Item;
const SlabClass = types.SlabClass;
const CachePadding = types.CachePadding;
const ListHead = zutil.ListHead;

const ItemAlignBytes = Item.Alignment.toByteUnits();

pub const Page = []align(ItemAlignBytes) u8;

pub const PageNum = struct {
    page_num: u64,

    const Self = @This();

    pub fn init(x: u64) Self {
        return .{ .page_num = x };
    }

    pub fn nullEqual(self: Self, other: ?Self) bool {
        const other_val = if (other) |v| v else {
            return false;
        };
        return self.page_num == other_val.page_num;
    }
};

pub const AtomicSlabNull = std.math.maxInt(u64);

pub const GlobalPager = struct {
    const Self = @This();
    const AtomicSlab = zatomic.Value(u64);

    _io: std.Io,
    _gpa: std.mem.Allocator,
    _page_size: u64,
    _page_size_shift: u6,
    _all_pages: []align(ItemAlignBytes) u8,

    _padding1: CachePadding = undefined,

    _num_empty_pages: zatomic.Value(u64),
    _mut: std.Io.Mutex,
    _pages_to_slab: []AtomicSlab,
    _all_page_heads: []ListHead,

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        page_size_log: u6,
        num_pages: u64,
    ) !*Self {
        const page_size: u64 = @as(u64, 1) << page_size_log;
        const all_pages = try gpa.alignedAlloc(
            u8,
            Item.Alignment,
            page_size * num_pages,
        );
        std.debug.assertAligned(all_pages, Item.Alignment);

        // fill all pages with random value
        std.debug.assert(blk: {
            const current_time = std.Io.Clock.real.now(io);
            const seed: u64 = @intCast(current_time.toNanoseconds());

            var prng = std.Random.DefaultPrng.init(seed);
            const rand = prng.random();

            for (all_pages) |*x| {
                x.* = rand.int(u8);
            }
            break :blk true;
        });

        // init page to slab array
        const pages_to_slab = try gpa.alloc(AtomicSlab, num_pages);
        for (pages_to_slab) |*x| {
            x.* = .init(AtomicSlabNull);
        }

        // init all page list heads
        const all_page_heads = try gpa.alloc(ListHead, num_pages);

        const svc = try gpa.create(Self);
        svc.* = .{
            ._io = io,
            ._gpa = gpa,
            ._page_size = page_size,
            ._page_size_shift = page_size_log,
            ._all_pages = all_pages,
            ._num_empty_pages = .init(num_pages),
            ._mut = .init,
            ._pages_to_slab = pages_to_slab,
            ._all_page_heads = all_page_heads,
        };
        return svc;
    }

    pub fn deinit(self: *Self) void {
        const gpa = self._gpa;

        gpa.free(self._all_page_heads);
        gpa.free(self._all_pages);
        gpa.free(self._pages_to_slab);
        gpa.destroy(self);
    }

    pub fn allocPage(self: *Self, slab: types.SlabClass) ?Page {
        var num_empty = self._num_empty_pages.load();
        if (num_empty == 0) {
            return null;
        }

        // lock the mutex
        self._mut.lockUncancelable(self._io);
        defer self._mut.unlock(self._io);

        // check again
        num_empty = self._num_empty_pages.load();
        if (num_empty == 0) {
            return null;
        }

        const num_pages = self._pages_to_slab.len;
        const index = num_pages - num_empty;
        self._num_empty_pages.store(num_empty - 1);

        const page_num = PageNum{ .page_num = index };
        self.updatePageSlab(page_num, slab);

        const offset_start = index << self._page_size_shift;
        const offset_end = offset_start + self._page_size;
        return @alignCast(self._all_pages[offset_start..offset_end]);
    }

    pub fn getPageNumOfItem(self: *const Self, item: *Item) PageNum {
        const item_addr: [*]u8 = item.toItemAddr();
        const offset = item_addr - self._all_pages.ptr;
        const page_num = offset >> self._page_size_shift;
        return .{ .page_num = page_num };
    }

    pub fn getPageNumOfPage(self: *const Self, page: Page) PageNum {
        const offset = page.ptr - self._all_pages.ptr;
        const page_num = offset >> self._page_size_shift;
        return .{ .page_num = page_num };
    }

    pub fn getPageOfPageNum(self: *const Self, page_num: PageNum) Page {
        const start_offset = page_num.page_num * self._page_size;
        const end_offset = start_offset + self._page_size;
        return @alignCast(self._all_pages[start_offset..end_offset]);
    }

    pub fn updatePageSlab(self: *Self, page_num: PageNum, slab: ?types.SlabClass) void {
        const num_pages = self._pages_to_slab.len;
        std.debug.assert(page_num.page_num < num_pages);
        if (slab) |s| {
            self._pages_to_slab[page_num.page_num].store(s.slab);
        } else {
            self._pages_to_slab[page_num.page_num].store(AtomicSlabNull);
        }
    }

    pub fn getSlabClass(self: *const Self, page_num: PageNum) ?types.SlabClass {
        const slab_num = self._pages_to_slab[page_num.page_num].load();
        if (slab_num == AtomicSlabNull) {
            return null;
        }

        std.debug.assert(slab_num <= SlabClass.MaxNumClass);
        return .{
            .slab = @intCast(slab_num),
        };
    }

    pub fn iterateItemsOfPage(
        self: *const Self,
        page: Page,
        item_size: u64,
        ctx: anytype,
        yield: fn (ctx: @TypeOf(ctx), item: *Item) bool,
    ) void {
        std.debug.assertAligned(page, Item.Alignment);
        std.debug.assert(Item.Alignment.check(item_size));
        std.debug.assert(item_size <= self._page_size);

        const num_items = self.getNumItemsPerPage(item_size);
        var current_addr: [*]align(ItemAlignBytes) u8 = page.ptr;

        for (0..num_items) |_| {
            const item: *Item = @ptrCast(@alignCast(current_addr));
            const ok = yield(ctx, item);
            if (!ok) {
                break;
            }
            current_addr = @alignCast(current_addr + item_size);
        }
    }

    pub fn getNumItemsPerPage(self: *const Self, item_size: usize) usize {
        return self._page_size / item_size;
    }

    pub fn getBaseAddr(self: *const Self) [*]u8 {
        return self._all_pages.ptr;
    }

    const Iterator = struct {
        _index: usize,
        _pager: *const Self,

        pub fn next(self: *@This()) ?PageNum {
            if (self._index >= self._pager._pages_to_slab.len) {
                return null;
            }
            const result = PageNum.init(self._index);
            self._index += 1;
            return result;
        }
    };

    pub fn getAllPages(self: *const Self) Iterator {
        return .{
            ._index = 0,
            ._pager = self,
        };
    }

    pub fn getPageListHead(self: *Self, num: PageNum) *ListHead {
        return &self._all_page_heads[num.page_num];
    }

    pub fn getPageNumOfListHead(self: *Self, entry: *ListHead) PageNum {
        const base: [*]ListHead = self._all_page_heads.ptr;
        const ptr: [*]ListHead = @ptrCast(entry);

        const offset = ptr - base;
        std.debug.assert(offset < self._all_page_heads.len);

        return PageNum.init(offset);
    }
};

// ===========================================================================
// Testing
// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "max slab" {
    try std.testing.expect(AtomicSlabNull > 1_000_000);
}

test "basic" {
    var g = try GlobalPager.init(
        std.testing.io,
        std.testing.allocator,
        20,
        3,
    );
    defer g.deinit();

    try expectEqual(3 * 1024 * 1024, g._all_pages.len);
    try expectEqual(3, g._pages_to_slab.len);
    try expectEqual(0xffff_ffff_ffff_ffff, g._pages_to_slab[0].load());
    try expectEqual(0xffff_ffff_ffff_ffff, g._pages_to_slab[2].load());

    // test allocate pages
    const p1 = g.allocPage(.{ .slab = 11 }).?;
    try expectEqual(g._all_pages.ptr, p1.ptr);
    try expectEqual(3, g._pages_to_slab.len);

    const p2 = g.allocPage(.{ .slab = 12 }).?;
    try expectEqual(g._all_pages.ptr + g._page_size, p2.ptr);
    try expectEqual(11, g._pages_to_slab[0].load());
    try expectEqual(12, g._pages_to_slab[1].load());

    const p3 = g.allocPage(.{ .slab = 13 }).?;
    try expectEqual(g._all_pages.ptr + 2 * g._page_size, p3.ptr);

    const p4 = g.allocPage(.{ .slab = 14 });
    try expectEqual(null, p4);

    // check get all pages
    try zutil.expectIteratorValues(PageNum, &.{
        PageNum.init(0),
        PageNum.init(1),
        PageNum.init(2),
    }, g.getAllPages());

    // check page num <=> page
    const page_num2 = g.getPageNumOfPage(p2);
    try expectEqual(PageNum.init(1), page_num2);
    try expectEqual(p2, g.getPageOfPageNum(page_num2));

    // test get page num
    const item1: *Item = @ptrCast(@alignCast(p1));
    const num1 = g.getPageNumOfItem(item1);
    try expectEqual(0, num1.page_num);
    try expectEqual(11, g.getSlabClass(num1).?.slab);

    const item2: *Item = @ptrCast(@alignCast(p2));
    const num2 = g.getPageNumOfItem(item2);
    try expectEqual(1, num2.page_num);
    try expectEqual(12, g.getSlabClass(num2).?.slab);

    // check get page number
    const item3: *Item = @ptrCast(@alignCast(p3));
    try expectEqual(2, g.getPageNumOfItem(item3).page_num);

    // iterate items of page
    const IterateCtx = struct {
        counter: u64,
        base_addr: [*]u8,
        fn yield(self: *@This(), x: *Item) bool {
            const item_addr: *u8 = @ptrCast(x);
            expectEqual(3 * 1024 * self.counter, item_addr - self.base_addr) catch unreachable;
            self.counter = self.counter + 1;
            return true;
        }
    };
    var ctx = IterateCtx{
        .counter = 0,
        .base_addr = p1.ptr,
    };
    g.iterateItemsOfPage(p1, 3 * 1024, &ctx, IterateCtx.yield);
    try expectEqual(341, ctx.counter); // check total
}

test "page list head" {
    var g = try GlobalPager.init(
        std.testing.io,
        std.testing.allocator,
        20,
        3,
    );
    defer g.deinit();

    const page1 = PageNum.init(1);
    const entry = g.getPageListHead(page1);
    try expectEqual(page1, g.getPageNumOfListHead(entry));
}

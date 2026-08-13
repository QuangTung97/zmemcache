const std = @import("std");
const types = @import("types.zig");

const Item = types.Item;

const PageSizeShift = 20;

pub const PageSize = 1 << PageSizeShift; // 1MB

pub const Page = [PageSize]u8;

pub const PageNum = struct { page_num: u64 };

pub const MaxSlab: u32 = 0xffffffff;

pub const GlobalPager = struct {
    priv: struct {
        io: std.Io,
        gpa: std.mem.Allocator,

        all_pages: []Page,
        num_empty_pages: std.atomic.Value(u64),
        mut: std.Io.Mutex,
        pages_to_slab: []std.atomic.Value(u32),
    },

    const Self = @This();

    pub fn init(io: std.Io, gpa: std.mem.Allocator, num_pages: u64) !Self {
        const all_pages = try gpa.alignedAlloc(
            Page,
            Item.Alignment,
            num_pages,
        );
        const pages_to_slab = try gpa.alloc(std.atomic.Value(u32), num_pages);

        for (pages_to_slab) |*x| {
            x.* = .init(MaxSlab);
        }

        return Self{
            .priv = .{
                .io = io,
                .gpa = gpa,
                .all_pages = all_pages,
                .num_empty_pages = .init(num_pages),
                .mut = .init,
                .pages_to_slab = pages_to_slab,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.priv.gpa.free(self.priv.all_pages);
        self.priv.gpa.free(self.priv.pages_to_slab);
    }

    pub fn allocPage(self: *Self, slab: types.SlabClass) ?*Page {
        const this = &self.priv;

        var num_empty = this.num_empty_pages.load(.seq_cst);
        if (num_empty == 0) {
            return null;
        }

        // lock the mutex
        this.mut.lockUncancelable(this.io);
        defer this.mut.unlock(this.io);

        // check again
        num_empty = this.num_empty_pages.load(.seq_cst);
        if (num_empty == 0) {
            return null;
        }

        this.num_empty_pages.store(num_empty - 1, .seq_cst);

        const index = this.all_pages.len - num_empty;
        const page_num = PageNum{ .page_num = index };
        self.updatePageSlab(page_num, slab);

        return &this.all_pages[index];
    }

    pub fn getPageNumOfItem(self: Self, item: *Item) PageNum {
        const this = self.priv;
        const base_addr: *u8 = @ptrCast(&this.all_pages[0]);
        const item_addr: *u8 = @ptrCast(item);
        const offset = item_addr - base_addr;

        const page_num = offset >> PageSizeShift;
        return .{ .page_num = page_num };
    }

    pub fn updatePageSlab(self: *Self, page_num: PageNum, slab: types.SlabClass) void {
        const this = &self.priv;
        std.debug.assert(page_num.page_num < this.all_pages.len);
        this.pages_to_slab[page_num.page_num].store(slab.slab, .seq_cst);
    }

    pub fn getSlabClass(self: Self, page_num: PageNum) types.SlabClass {
        return .{
            .slab = self.priv.pages_to_slab[page_num.page_num].load(.seq_cst),
        };
    }
};

const ItemIterator = struct {
    item_size: u64,
    page_addr: [*]u8,
    current: u64,
    max_offset: u64,

    const Self = @This();

    pub fn next(self: *Self) ?*Item {
        if (self.current >= self.max_offset) {
            return null;
        }

        const item_addr = self.page_addr + (self.current * self.item_size);
        self.current = self.current + 1;

        const item: *Item = @ptrCast(@alignCast(item_addr));
        return item;
    }
};

pub fn iterateItemsOfPage(
    page: *Page,
    item_size: u64,
    ctx: anytype,
    yield: fn (ctx: @TypeOf(ctx), item: *Item) bool,
) void {
    std.debug.assertAligned(page, Item.Alignment);
    std.debug.assert(Item.Alignment.check(item_size));

    const base_addr: [*]u8 = @ptrCast(page);
    const num_items = PageSize / item_size;
    var current_addr = base_addr;

    for (0..num_items) |_| {
        const item: *Item = @ptrCast(@alignCast(current_addr));
        const ok = yield(ctx, item);
        if (!ok) {
            break;
        }
        current_addr = current_addr + item_size;
    }
}

// ===========================================================================
// Testing
// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "page size" {
    try expectEqual(1024 * 1024, @sizeOf(Page));
    try std.testing.expect(MaxSlab > 1_000_000);
    try expectEqual(1, @alignOf(Page));
}

test "basic" {
    var g = try GlobalPager.init(
        std.testing.io,
        std.testing.allocator,
        3,
    );
    defer g.deinit();

    try expectEqual(3, g.priv.all_pages.len);
    try expectEqual(3, g.priv.pages_to_slab.len);
    try expectEqual(0xffff_ffff, g.priv.pages_to_slab[0].load(.seq_cst));
    try expectEqual(0xffff_ffff, g.priv.pages_to_slab[2].load(.seq_cst));

    // test allocate pages
    const p1 = g.allocPage(.{ .slab = 11 });
    try expectEqual(&g.priv.all_pages[0], p1);
    try expectEqual(3, g.priv.pages_to_slab.len);

    const p2 = g.allocPage(.{ .slab = 12 });
    try expectEqual(&g.priv.all_pages[1], p2);
    try expectEqual(11, g.priv.pages_to_slab[0].load(.seq_cst));
    try expectEqual(12, g.priv.pages_to_slab[1].load(.seq_cst));

    const p3 = g.allocPage(.{ .slab = 13 });
    try expectEqual(&g.priv.all_pages[2], p3);

    const p4 = g.allocPage(.{ .slab = 14 });
    try expectEqual(null, p4);

    // test get page num
    const item1: *Item = @ptrCast(@alignCast(p1));
    const num1 = g.getPageNumOfItem(item1);
    try expectEqual(0, num1.page_num);
    try expectEqual(11, g.getSlabClass(num1).slab);

    const item2: *Item = @ptrCast(@alignCast(p2));
    const num2 = g.getPageNumOfItem(item2);
    try expectEqual(1, num2.page_num);
    try expectEqual(12, g.getSlabClass(num2).slab);

    const item3: *Item = @ptrCast(@alignCast(p3));
    // check item getters
    item3.key_len = 31;
    item3.value_len = 51;
    const item3_base: [*]u8 = @ptrCast(item3);
    try expectEqual(2, g.getPageNumOfItem(item3).page_num);
    try expectEqual(31, item3.getKey().len);
    try expectEqual(Item.Size, &item3.getKey()[0] - item3_base);
    try expectEqual(51, item3.getValue().len);
    try expectEqual(Item.Size + 31, &item3.getValue()[0] - item3_base);

    // test iterate
    const page1 = p1.?;

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
        .base_addr = page1,
    };
    iterateItemsOfPage(page1, 3 * 1024, &ctx, IterateCtx.yield);
    try expectEqual(341, ctx.counter); // check total
}

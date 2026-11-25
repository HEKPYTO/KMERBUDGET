const std = @import("std");

const encoding = blk: {
    var table: [256]u8 = @splat(4);
    table['A'] = 0;
    table['C'] = 1;
    table['G'] = 2;
    table['T'] = 3;
    table['a'] = 0;
    table['c'] = 1;
    table['g'] = 2;
    table['t'] = 3;
    break :blk table;
};

pub inline fn encode(base: u8) u8 {
    return encoding[base];
}

pub const Rolling = struct {
    value: u64 = 0,
    validity: u64 = 0,
    keep: u64,
    valid_keep: u64,
    span: u16,

    pub fn init(span: u16) Rolling {
        std.debug.assert(span > 0 and span <= 32);
        const keep: u64 = if (span >= 32) ~@as(u64, 0) else (@as(u64, 1) << @intCast(2 * span)) - 1;
        return .{ .keep = keep, .valid_keep = (@as(u64, 1) << @intCast(span)) - 1, .span = span };
    }

    pub inline fn push(self: *Rolling, code: u8) void {
        self.value = (self.value << 2 | @as(u64, code & 3)) & self.keep;
        self.validity = (self.validity << 1 | @intFromBool(code < 4)) & self.valid_keep;
    }

    pub inline fn valid(self: *const Rolling, mask_bits: u64) bool {
        return (self.validity & mask_bits) == mask_bits;
    }
};

test "encode maps bases and rejects invalid" {
    try std.testing.expectEqual(@as(u8, 0), encode('A'));
    try std.testing.expectEqual(@as(u8, 1), encode('C'));
    try std.testing.expectEqual(@as(u8, 2), encode('G'));
    try std.testing.expectEqual(@as(u8, 3), encode('T'));
    try std.testing.expectEqual(@as(u8, 0), encode('a'));
    try std.testing.expectEqual(@as(u8, 1), encode('c'));
    try std.testing.expectEqual(@as(u8, 2), encode('g'));
    try std.testing.expectEqual(@as(u8, 3), encode('t'));
    try std.testing.expectEqual(@as(u8, 4), encode('N'));
    try std.testing.expectEqual(@as(u8, 4), encode('X'));
}

test "rolling window keeps packed bases and validity bits" {
    var r = Rolling.init(3);
    r.push(encode('A'));
    r.push(encode('C'));
    r.push(encode('G'));
    try std.testing.expectEqual(@as(u64, 0b00_01_10), r.value);
    try std.testing.expect(r.valid(0b111));
    r.push(encode('N'));
    try std.testing.expectEqual(@as(u64, 0b01_10_00), r.value);
    try std.testing.expect(!r.valid(0b001));
    try std.testing.expect(r.valid(0b110));
    try std.testing.expect(r.valid(0b100));
    try std.testing.expect(!r.valid(0b101));
}

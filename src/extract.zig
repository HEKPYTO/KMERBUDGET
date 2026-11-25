const std = @import("std");
const builtin = @import("builtin");

pub const Mask = struct {
    span: u16,
    weight: u16,
    bits: u64,

    pub fn parse(text: []const u8) !Mask {
        if (text.len == 0 or text.len > 32) return error.InvalidMask;
        var bits: u64 = 0;
        for (text) |c| {
            bits <<= 1;
            if (c == '1') {
                bits |= 1;
            } else if (c != '0') {
                return error.InvalidMask;
            }
        }
        const weight = std.mem.count(u8, text, "1");
        if (weight == 0) return error.InvalidMask;
        return .{ .span = @intCast(text.len), .weight = @intCast(weight), .bits = bits };
    }

    pub fn expanded(self: Mask) u64 {
        var out: u64 = 0;
        var i: u16 = 0;
        while (i < self.span) : (i += 1) {
            if ((self.bits >> @intCast(i)) & 1 != 0) {
                out |= @as(u64, 3) << @intCast(2 * i);
            }
        }
        return out;
    }
};

pub fn naive(kmer: u64, mask: Mask) u64 {
    var out: u64 = 0;
    var shift: usize = 0;
    var i: u16 = 0;
    while (i < mask.span and i < 32) : (i += 1) {
        if ((mask.bits >> @intCast(i)) & 1 != 0) {
            out |= ((kmer >> @intCast(2 * i)) & 3) << @intCast(shift);
            shift += 2;
        }
    }
    return out;
}

pub const Butterfly = struct {
    initial: u64,
    moves: [6]u64,
    shifts: [6]u6,

    pub fn init(mask: Mask) Butterfly {
        const m = mask.expanded();
        var mk = ~m << 1;
        var cur = m;
        var moves: [6]u64 = undefined;
        var shifts: [6]u6 = undefined;
        var stage: u6 = 0;
        while (stage < 6) : (stage += 1) {
            var mp = mk ^ (mk << 1);
            mp ^= mp << 2;
            mp ^= mp << 4;
            mp ^= mp << 8;
            mp ^= mp << 16;
            mp ^= mp << 32;
            const mv = mp & cur;
            const step: u6 = @as(u6, 1) << @intCast(stage);
            cur = (cur ^ mv) | (mv >> step);
            moves[stage] = mv;
            shifts[stage] = step;
            mk &= ~mp;
        }
        return .{ .initial = m, .moves = moves, .shifts = shifts };
    }

    pub inline fn apply(self: Butterfly, kmer: u64) u64 {
        var x = kmer & self.initial;
        inline for (0..6) |i| {
            const t = x & self.moves[i];
            x = (x ^ t) | (t >> self.shifts[i]);
        }
        return x;
    }

    pub inline fn applyVec(self: Butterfly, comptime n: usize, kmers: @Vector(n, u64)) @Vector(n, u64) {
        const V = @Vector(n, u64);
        const S = @Vector(n, u6);
        var x: V = kmers & @as(V, @splat(self.initial));
        inline for (0..6) |i| {
            const t = x & @as(V, @splat(self.moves[i]));
            x = (x ^ t) | (t >> @as(S, @splat(self.shifts[i])));
        }
        return x;
    }
};

pub const Engine = enum { butterfly, pext };

pub fn nativeEngine() Engine {
    if (builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2)) {
        return .pext;
    }
    return .butterfly;
}

pub fn pext(value: u64, mask: u64) u64 {
    if (builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2)) {
        return asm ("pext %[mask], %[value], %[out]"
            : [out] "=r" (-> u64),
            : [value] "r" (value),
              [mask] "r" (mask),
        );
    }
    unreachable;
}

test "mask parses only binary strings with at least one position" {
    const m = try Mask.parse("1011");
    try std.testing.expectEqual(@as(u16, 4), m.span);
    try std.testing.expectEqual(@as(u16, 3), m.weight);
    try std.testing.expectEqual(@as(u64, 0b1011), m.bits);
    try std.testing.expectError(error.InvalidMask, Mask.parse("10a1"));
    try std.testing.expectError(error.InvalidMask, Mask.parse(""));
    try std.testing.expectError(error.InvalidMask, Mask.parse("0000"));
    try std.testing.expectError(error.InvalidMask, Mask.parse("111111111111111111111111111111111"));
}

test "naive extraction keeps selected symbols in order" {
    const m = try Mask.parse("1011");
    const kmer = 0b11_00_01_10;
    try std.testing.expectEqual(@as(u64, 0b11_01_10), naive(kmer, m));
}

test "butterfly matches naive for every mask over 8 bits" {
    var bits: u64 = 0;
    while (bits < 1 << 8) : (bits += 1) {
        const m = Mask{ .span = 8, .weight = @intCast(@popCount(bits)), .bits = bits };
        const b = Butterfly.init(m);
        var kmer: u64 = 0;
        while (kmer < 1 << 16) : (kmer += 977) {
            try std.testing.expectEqual(naive(kmer, m), b.apply(kmer));
        }
    }
}

test "vector butterfly matches scalar" {
    const m = try Mask.parse("1011010101");
    const b = Butterfly.init(m);
    const raw: [4]u64 = .{ 0x123456789abcdef0, 0xabcd, 0xffff000000000000, 0x0001 };
    const out = b.applyVec(4, raw);
    const arr: [4]u64 = out;
    for (raw, 0..) |k, i| {
        try std.testing.expectEqual(b.apply(k), arr[i]);
        try std.testing.expectEqual(naive(k, m), arr[i]);
    }
}

test "butterfly matches naive at span 32" {
    var rng = std.Random.DefaultPrng.init(0x1234);
    var random = rng.random();
    var t: usize = 0;
    while (t < 256) : (t += 1) {
        const bits = random.int(u64) & 0xffffffff;
        if (bits == 0) continue;
        const m = Mask{ .span = 32, .weight = @intCast(@popCount(bits)), .bits = bits };
        const b = Butterfly.init(m);
        var s: usize = 0;
        while (s < 32) : (s += 1) {
            const kmer = random.int(u64);
            try std.testing.expectEqual(naive(kmer, m), b.apply(kmer));
        }
    }
}

fn fuzzMask(_: void, smith: *std.testing.Smith) !void {
    var buffer: [64]u8 = undefined;
    const length = smith.slice(&buffer);
    if (length == 0 or length > 32) return;
    const mask = Mask.parse(buffer[0..length]) catch return;
    try std.testing.expectEqual(@as(u16, @intCast(length)), mask.span);
    try std.testing.expect(mask.weight > 0);
    const span_bits: u64 = (@as(u64, 1) << @intCast(mask.span)) - 1;
    try std.testing.expectEqual(@as(u64, 0), mask.bits & ~span_bits);
    try std.testing.expectEqual(@as(u32, 2 * mask.weight), @popCount(mask.expanded()));
    const kmer = smith.value(u64);
    try std.testing.expectEqual(naive(kmer, mask), Butterfly.init(mask).apply(kmer));
}

test "fuzz mask parsing and extraction" {
    try std.testing.fuzz({}, fuzzMask, .{});
}

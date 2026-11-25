const std = @import("std");
const pack = @import("pack.zig");
const extract = @import("extract.zig");

pub const Scanner = struct {
    mask: extract.Mask,
    butterfly: extract.Butterfly,
    ext: u64,
    kind: extract.Engine,

    pub fn init(mask: extract.Mask) Scanner {
        return .{
            .mask = mask,
            .butterfly = extract.Butterfly.init(mask),
            .ext = mask.expanded(),
            .kind = extract.nativeEngine(),
        };
    }

    pub fn scan(self: Scanner, seq: []const u8, sink: anytype) !void {
        switch (self.kind) {
            .butterfly => try self.scanButterfly(seq, sink),
            .pext => try self.scanPext(seq, sink),
        }
    }

    fn scanButterfly(self: Scanner, seq: []const u8, sink: anytype) !void {
        var rolling = pack.Rolling.init(self.mask.span);
        var i: usize = 0;
        while (i + 4 <= seq.len) : (i += 4) {
            var kmers: [4]u64 = undefined;
            var valid: [4]bool = undefined;
            var all = true;
            inline for (0..4) |j| {
                rolling.push(pack.encode(seq[i + j]));
                kmers[j] = rolling.value;
                valid[j] = i + j + 1 >= self.mask.span and rolling.valid(self.mask.bits);
                all = all and valid[j];
            }
            if (all) {
                const out = self.butterfly.applyVec(4, kmers);
                const arr: [4]u64 = out;
                inline for (0..4) |j| {
                    try sink.emit(arr[j]);
                }
            } else {
                inline for (0..4) |j| {
                    if (valid[j]) {
                        try sink.emit(self.butterfly.apply(kmers[j]));
                    }
                }
            }
        }
        while (i < seq.len) : (i += 1) {
            rolling.push(pack.encode(seq[i]));
            if (i + 1 >= self.mask.span and rolling.valid(self.mask.bits)) {
                try sink.emit(self.butterfly.apply(rolling.value));
            }
        }
    }

    fn scanPext(self: Scanner, seq: []const u8, sink: anytype) !void {
        var rolling = pack.Rolling.init(self.mask.span);
        for (seq, 0..) |base, index| {
            rolling.push(pack.encode(base));
            if (index + 1 >= self.mask.span and rolling.valid(self.mask.bits)) {
                try sink.emit(extract.pext(rolling.value, self.ext));
            }
        }
    }
};

const Collector = struct {
    items: [16]u64 = undefined,
    len: usize = 0,

    pub fn emit(self: *Collector, kmer: u64) !void {
        if (self.len == self.items.len) return error.TooMany;
        self.items[self.len] = kmer;
        self.len += 1;
    }
};

test "scanner extracts every full valid window" {
    const scanner = Scanner.init(try extract.Mask.parse("101"));
    var out: Collector = .{};
    try scanner.scan("ACGTAC", &out);
    try std.testing.expectEqualSlices(u64, &.{ 2, 7, 8, 13 }, out.items[0..out.len]);
}

test "scanner skips only windows with an invalid selected base" {
    const scanner = Scanner.init(try extract.Mask.parse("101"));
    var out: Collector = .{};
    try scanner.scan("ACNGTA", &out);
    try std.testing.expectEqualSlices(u64, &.{ 6, 8 }, out.items[0..out.len]);
}

test "scanner does not emit windows before a full span" {
    const m = try extract.Mask.parse("0011");
    const scanner = Scanner.init(m);
    var out: Collector = .{};
    try scanner.scan("ACGT", &out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u64, 11), out.items[0]);
}

test "scanner vector path matches scalar across engines" {
    const m = try extract.Mask.parse("1011010101");
    const seq = "ACGTACGTACGTACGT";
    var rolling = pack.Rolling.init(m.span);
    var expected: Collector = .{};
    for (seq) |base| {
        rolling.push(pack.encode(base));
        if (rolling.valid(m.bits)) {
            try expected.emit(extract.naive(rolling.value, m));
        }
    }
    for ([_]extract.Engine{ .butterfly, .pext }) |engine| {
        if (engine == .pext and extract.nativeEngine() != .pext) continue;
        var scanner = Scanner.init(m);
        scanner.kind = engine;
        var out: Collector = .{};
        try scanner.scan(seq, &out);
        try std.testing.expectEqualSlices(u64, expected.items[0..expected.len], out.items[0..out.len]);
    }
}

const FuzzSink = struct {
    items: std.ArrayList(u64) = .empty,

    pub fn emit(self: *FuzzSink, kmer: u64) !void {
        try self.items.append(std.testing.allocator, kmer);
    }
};

fn fuzzScanner(_: void, smith: *std.testing.Smith) !void {
    var buffer: [128]u8 = undefined;
    const length = smith.slice(&buffer);
    for (buffer[0..length]) |*base| base.* = "ACGTN"[base.* % 5];

    const span = smith.valueRangeAtMost(u16, 1, 32);
    const span_bits: u64 = (@as(u64, 1) << @intCast(span)) - 1;
    var bits = smith.value(u64) & span_bits;
    if (bits == 0) bits = 1;
    const mask = extract.Mask{ .span = span, .weight = @intCast(@popCount(bits)), .bits = bits };

    var got: FuzzSink = .{};
    defer got.items.deinit(std.testing.allocator);
    try Scanner.init(mask).scan(buffer[0..length], &got);

    var expected: FuzzSink = .{};
    defer expected.items.deinit(std.testing.allocator);
    var rolling = pack.Rolling.init(span);
    for (buffer[0..length], 0..) |base, index| {
        rolling.push(pack.encode(base));
        if (index + 1 >= span and rolling.valid(mask.bits)) {
            try expected.emit(extract.naive(rolling.value, mask));
        }
    }
    try std.testing.expectEqualSlices(u64, expected.items.items, got.items.items);
}

test "fuzz scanner matches naive enumeration" {
    try std.testing.fuzz({}, fuzzScanner, .{});
}

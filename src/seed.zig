const std = @import("std");

pub fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

pub fn generate(allocator: std.mem.Allocator, bases: usize, seed: u64, invalid_rate: f64) ![]u8 {
    const out = try allocator.alloc(u8, bases);
    var state = seed;
    for (out) |*base| {
        const r = splitmix64(&state);
        const draw = @as(f64, @floatFromInt(r >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
        base.* = if (draw < invalid_rate) 'N' else "ACGT"[r & 3];
    }
    return out;
}

test "generator is deterministic for a seed" {
    const allocator = std.testing.allocator;
    const a = try generate(allocator, 1024, 20261125, 0);
    defer allocator.free(a);
    const b = try generate(allocator, 1024, 20261125, 0);
    defer allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    for (a) |base| try std.testing.expect(std.mem.indexOfScalar(u8, "ACGT", base) != null);
}

test "different seeds change the sequence" {
    const allocator = std.testing.allocator;
    const a = try generate(allocator, 64, 1, 0);
    defer allocator.free(a);
    const b = try generate(allocator, 64, 2, 0);
    defer allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "invalid rate injects N" {
    const allocator = std.testing.allocator;
    const seq = try generate(allocator, 4096, 3, 0.5);
    defer allocator.free(seq);
    const n_count = std.mem.count(u8, seq, "N");
    try std.testing.expect(n_count > 1000 and n_count < 3000);
}

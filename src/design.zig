const std = @import("std");
const pack = @import("pack.zig");
const extract = @import("extract.zig");

pub const Outcome = struct {
    mask: extract.Mask,
    proxy: f64,
    events: usize,
};

const Event = struct {
    reference: u64,
    candidates: [3]u64,
};

fn packWindow(bases: []const u8) u64 {
    var value: u64 = 0;
    for (bases) |base| value = (value << 2) | (pack.encode(base) & 3);
    return value;
}

fn validBases(bases: []const u8) bool {
    for (bases) |base| {
        if (pack.encode(base) > 3) return false;
    }
    return true;
}

fn buildEvents(
    allocator: std.mem.Allocator,
    records: []const []const u8,
    span: u16,
    error_rate: f64,
    seed: u64,
    count: usize,
) ![]Event {
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();
    var events: std.ArrayList(Event) = .empty;
    errdefer events.deinit(allocator);
    var attempts: usize = 0;
    const max_attempts = count * 64;

    while (events.items.len < count and attempts < max_attempts) : (attempts += 1) {
        const record = records[random.intRangeLessThan(usize, 0, records.len)];
        if (record.len < span + 3) continue;
        const start = random.intRangeLessThan(usize, 1, record.len - span - 1);
        var buffer: [64]u8 = undefined;
        const context = record[start - 1 .. start + span + 2];
        if (!validBases(context)) continue;
        @memcpy(buffer[0..context.len], context);
        var len = context.len;
        const reference = packWindow(buffer[1 .. 1 + span]);

        var mutated = false;
        var events_applied: usize = 0;
        var q: usize = 0;
        while (q < span and events_applied < 4) : (q += 1) {
            if (random.float(f64) >= error_rate) continue;
            const pos = 1 + random.intRangeLessThan(usize, 0, len - 2);
            const roll = random.float(f64);
            if (roll < 0.7) {
                const base = "ACGT"[random.intRangeLessThan(usize, 0, 4)];
                buffer[pos] = base;
            } else if (roll < 0.85 and len + 1 < buffer.len) {
                const base = "ACGT"[random.intRangeLessThan(usize, 0, 4)];
                std.mem.copyBackwards(u8, buffer[pos + 1 .. len + 1], buffer[pos..len]);
                buffer[pos] = base;
                len += 1;
            } else if (len > span + 2) {
                std.mem.copyForwards(u8, buffer[pos .. len - 1], buffer[pos + 1 .. len]);
                len -= 1;
            }
            mutated = true;
            events_applied += 1;
        }
        if (!mutated or len < span + 2) continue;

        var candidates: [3]u64 = undefined;
        var o: usize = 0;
        while (o < 3) : (o += 1) {
            candidates[o] = packWindow(buffer[o .. o + span]);
        }
        try events.append(allocator, .{ .reference = reference, .candidates = candidates });
    }
    return events.toOwnedSlice(allocator);
}

fn scoreMask(mask: extract.Mask, events: []const Event) f64 {
    const butterfly = extract.Butterfly.init(mask);
    var detected: usize = 0;
    for (events) |event| {
        const reference = butterfly.apply(event.reference);
        for (event.candidates) |candidate| {
            if (butterfly.apply(candidate) == reference) {
                detected += 1;
                break;
            }
        }
    }
    return @as(f64, @floatFromInt(detected)) / @as(f64, @floatFromInt(events.len));
}

fn initialMask(span: u16, weight: u16, random: std.Random) extract.Mask {
    var bits: u64 = 0;
    var placed: u16 = 0;
    while (placed < weight) {
        const bit = random.intRangeLessThan(u16, 0, span);
        if ((bits >> @intCast(bit)) & 1 == 0) {
            bits |= @as(u64, 1) << @intCast(bit);
            placed += 1;
        }
    }
    return .{ .span = span, .weight = weight, .bits = bits };
}

fn swapBits(mask: extract.Mask, drop: u16, add: u16) extract.Mask {
    return .{
        .span = mask.span,
        .weight = mask.weight,
        .bits = (mask.bits & ~(@as(u64, 1) << @intCast(drop))) | (@as(u64, 1) << @intCast(add)),
    };
}

pub fn design(
    allocator: std.mem.Allocator,
    records: []const []const u8,
    span: u16,
    weight: u16,
    error_rate: f64,
    iterations: usize,
    seed: u64,
    event_count: usize,
) !Outcome {
    if (span == 0 or span > 32) return error.InvalidSpan;
    if (weight == 0 or weight > span) return error.InvalidWeight;
    if (!(error_rate > 0 and error_rate <= 1)) return error.InvalidErrorRate;

    const events = try buildEvents(allocator, records, span, error_rate, seed, event_count);
    defer allocator.free(events);
    if (events.len == 0) return error.NoUsableWindows;

    var rng = std.Random.DefaultPrng.init(seed ^ 0x9e3779b97f4a7c15);
    const random = rng.random();
    var best = initialMask(span, weight, random);
    var best_score = scoreMask(best, events);

    var iteration: usize = 0;
    while (iteration < iterations and weight < span) : (iteration += 1) {
        var drop: u16 = undefined;
        while (true) {
            const bit = random.intRangeLessThan(u16, 0, span);
            if ((best.bits >> @intCast(bit)) & 1 == 1) {
                drop = bit;
                break;
            }
        }
        var add: u16 = undefined;
        while (true) {
            const bit = random.intRangeLessThan(u16, 0, span);
            if ((best.bits >> @intCast(bit)) & 1 == 0) {
                add = bit;
                break;
            }
        }
        const candidate = swapBits(best, drop, add);
        const candidate_score = scoreMask(candidate, events);
        if (candidate_score > best_score) {
            best = candidate;
            best_score = candidate_score;
        }
    }

    return .{ .mask = best, .proxy = best_score, .events = events.len };
}

pub fn formatMask(mask: extract.Mask, buffer: *[32]u8) []const u8 {
    var i: u16 = 0;
    while (i < mask.span) : (i += 1) {
        const bit = (mask.bits >> @intCast(mask.span - 1 - i)) & 1;
        buffer[i] = if (bit == 1) '1' else '0';
    }
    return buffer[0..mask.span];
}

test "design returns the requested span and weight deterministically" {
    var seq_buf: [128]u8 = undefined;
    for (0..32) |j| @memcpy(seq_buf[j * 4 ..][0..4], "ACGT");
    const records = [_][]const u8{&seq_buf};
    const a = try design(std.testing.allocator, &records, 16, 8, 0.05, 60, 7, 256);
    const b = try design(std.testing.allocator, &records, 16, 8, 0.05, 60, 7, 256);
    try std.testing.expectEqual(a.mask.bits, b.mask.bits);
    try std.testing.expectEqual(@as(u16, 16), a.mask.span);
    try std.testing.expectEqual(@as(u16, 8), a.mask.weight);
    try std.testing.expect(a.proxy >= 0 and a.proxy <= 1);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 16), formatMask(a.mask, &buffer).len);
}

test "design rejects impossible bounds" {
    const records = [_][]const u8{"ACGTACGTACGT"};
    try std.testing.expectError(error.InvalidSpan, design(std.testing.allocator, &records, 0, 1, 0.05, 1, 1, 8));
    try std.testing.expectError(error.InvalidWeight, design(std.testing.allocator, &records, 8, 9, 0.05, 1, 1, 8));
    try std.testing.expectError(error.InvalidErrorRate, design(std.testing.allocator, &records, 8, 4, 0, 1, 1, 8));
}

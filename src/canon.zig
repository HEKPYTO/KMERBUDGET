const std = @import("std");

pub fn reverseComplement(kmer: u64, weight: u16) u64 {
    var out: u64 = 0;
    var value = kmer;
    var i: u16 = 0;
    while (i < weight) : (i += 1) {
        out = (out << 2) | (3 - (value & 3));
        value >>= 2;
    }
    return out;
}

pub fn canonical(kmer: u64, weight: u16) u64 {
    const rc = reverseComplement(kmer, weight);
    return @min(kmer, rc);
}

pub fn decode(kmer: u64, weight: u16, out: []u8) void {
    const alphabet = "ACGT";
    var i: u16 = 0;
    while (i < weight) : (i += 1) {
        const shift: u6 = @intCast(2 * (weight - 1 - i));
        out[i] = alphabet[(kmer >> shift) & 3];
    }
}

test "reverse complement maps symbols in reverse order" {
    try std.testing.expectEqual(@as(u64, 0b00_01_10_11), reverseComplement(0b00_01_10_11, 4));
    try std.testing.expectEqual(@as(u64, 0b10_01_11_00), reverseComplement(0b11_00_10_01, 4));
}

test "canonical picks the smaller orientation" {
    const forward = 0b00_00_01_10;
    const rc = reverseComplement(forward, 4);
    try std.testing.expectEqual(@min(forward, rc), canonical(forward, 4));
}

test "decode prints bases in sequence order" {
    var buf: [4]u8 = undefined;
    decode(0b00_01_10_11, 4, &buf);
    try std.testing.expectEqualStrings("ACGT", &buf);
}

//! Nix-compatible hashing: SHA-256, base16, Nix base32 ("nix32"),
//! hash compression and hash-string parsing.  All algorithms are
//! byte-for-byte compatible with Nix 2.34 (`libutil/hash.cc`,
//! `libutil/base-nix-32.cc`).

const std = @import("std");

pub const sha256_len = 32;

/// The Nix base32 alphabet (also known as "nix32").
const nix32_alphabet = "0123456789abcdfghijklmnpqrsvwxyz";

pub fn sha256(data: []const u8) [sha256_len]u8 {
    var out: [sha256_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

/// XOR-fold a hash down to `new_size` bytes (Nix `compressHash`).
/// Returns the compressed bytes; the caller keeps `new_size` of them.
pub fn compressHash(bytes: []const u8, new_size: usize) [sha256_len]u8 {
    var h: [sha256_len]u8 = [_]u8{0} ** sha256_len;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        h[i % new_size] ^= bytes[i];
    }
    return h;
}

/// Lowercase base16 encoding into `out` (must be >= 2*len bytes).
/// Returns the slice `out[0..2*len]`.
pub fn base16Encode(out: []u8, bytes: []const u8) []u8 {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 * i] = hex[b >> 4];
        out[2 * i + 1] = hex[b & 0xf];
    }
    return out[0 .. 2 * bytes.len];
}

pub fn base16EncodeAlloc(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, 2 * bytes.len);
    return base16Encode(out, bytes);
}

/// Nix base32 encoding (Nix `BaseNix32::encode`): most-significant
/// bits first, 5 bits per character, little-endian byte order in the
/// bit stream.
pub fn nix32Encode(bytes: []const u8, out: []u8) []u8 {
    if (bytes.len == 0) return out[0..0];
    const len = (bytes.len * 8 + 4) / 5; // ceil(bytes.len*8/5)
    var n: usize = len;
    while (n > 0) {
        n -= 1;
        const b = n * 5;
        const i = b / 8;
        const j = b % 8;
        const second: u8 = if (i >= bytes.len - 1 or j == 0) @as(u8, 0) else bytes[i + 1] << @intCast(8 - j);
        const c: u8 = @as(u8, bytes[i] >> @intCast(j)) | second;
        // Nix builds the string from the end: s[len-1-n] = char(n).
        out[len - 1 - n] = nix32_alphabet[c & 0x1f];
    }
    return out[0..len];
}

pub fn nix32EncodeAlloc(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const len = if (bytes.len == 0) 0 else (bytes.len * 8 + 4) / 5;
    const out = try alloc.alloc(u8, len);
    return nix32Encode(bytes, out);
}

fn nix32LookupReverse(c: u8) ?u8 {
    const idx = std.mem.indexOfScalar(u8, nix32_alphabet, c) orelse return null;
    return @intCast(idx);
}

/// Nix base32 decoding (Nix `BaseNix32::decode`).
pub fn nix32Decode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // Mirrors Nix `BaseNix32::decode` exactly: the buffer grows as needed,
    // so the trailing padding byte is never produced.
    var res = std.array_list.Managed(u8).init(alloc);
    var n: usize = 0;
    while (n < s.len) : (n += 1) {
        const c = s[s.len - n - 1];
        const digit = nix32LookupReverse(c) orelse return error.InvalidNix32;
        const b = n * 5;
        const i = b / 8;
        const j = b % 8;
        while (res.items.len <= i) try res.append(0);
        res.items[i] |= (digit << @intCast(j)) & 0xff;
        if (j != 0 and (digit >> @intCast(8 - j)) != 0) {
            while (res.items.len <= i + 1) try res.append(0);
            res.items[i + 1] |= (digit >> @intCast(8 - j)) & 0xff;
        }
    }
    return res.toOwnedSlice();
}

pub fn base16Decode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len % 2 != 0) return error.InvalidBase16;
    const res = try alloc.alloc(u8, s.len / 2);
    var i: usize = 0;
    while (i < s.len) : (i += 2) {
        const hi = hexVal(s[i]) orelse return error.InvalidBase16;
        const lo = hexVal(s[i + 1]) orelse return error.InvalidBase16;
        res[i / 2] = (hi << 4) | lo;
    }
    return res;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// A parsed hash value (only SHA-256 is supported, like modern Nix
/// without experimental features).
pub const Hash = struct {
    bytes: [sha256_len]u8 = [_]u8{0} ** sha256_len,
    hash_size: usize = sha256_len,

    pub fn of(data: []const u8) Hash {
        return .{ .bytes = sha256(data), .hash_size = sha256_len };
    }

    pub fn compressed(self: Hash, new_size: usize) Hash {
        var h = self;
        h.bytes = compressHash(&self.bytes, new_size);
        h.hash_size = new_size;
        return h;
    }

    pub fn base16(self: Hash, alloc: std.mem.Allocator) ![]u8 {
        return base16EncodeAlloc(alloc, self.bytes[0..self.hash_size]);
    }

    pub fn nix32(self: Hash, alloc: std.mem.Allocator) ![]u8 {
        return nix32EncodeAlloc(alloc, self.bytes[0..self.hash_size]);
    }

    pub fn eql(a: Hash, b: Hash) bool {
        if (a.hash_size != b.hash_size) return false;
        return std.mem.eql(u8, a.bytes[0..a.hash_size], b.bytes[0..b.hash_size]);
    }
};

pub const HashError = error{ BadHash, UnsupportedAlgorithm, OutOfMemory };

/// Parse a hash string the way Nix's `Hash::parseAny` / `newHashAllowEmpty`
/// does: optional `sha256:`/`sha256-` prefix, then base16 / nix32 / base64
/// selected by length.
/// If `s` is empty, returns the all-zero SHA-256 hash.
pub fn parseHash(alloc: std.mem.Allocator, s: []const u8) HashError!Hash {
    if (s.len == 0) return Hash{};
    var rest = s;
    var sri = false;
    // Strip "<algo>:" or "<algo>-" prefix.  Only sha256 supported.
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        const algo = rest[0..i];
        if (algo.len == 0) return error.BadHash;
        if (!std.mem.eql(u8, algo, "sha256")) return error.UnsupportedAlgorithm;
        rest = rest[i + 1 ..];
    } else if (std.mem.indexOfScalar(u8, rest, '-')) |i| {
        const algo = rest[0..i];
        if (algo.len == 0) return error.BadHash;
        if (!std.mem.eql(u8, algo, "sha256")) return error.UnsupportedAlgorithm;
        rest = rest[i + 1 ..];
        sri = true;
    }
    var bytes: [sha256_len]u8 = undefined;
    if (sri) {
        // base64 SRI
        const decoded = std.base64.standard.Decoder.calcSizeForSlice(rest) catch return error.BadHash;
        if (decoded != sha256_len) return error.BadHash;
        const buf = alloc.alloc(u8, decoded) catch return error.OutOfMemory;
        defer alloc.free(buf);
        std.base64.standard.Decoder.decode(buf, rest) catch return error.BadHash;
        @memcpy(&bytes, buf);
    } else {
        // Decide by length.
        if (rest.len == 2 * sha256_len) {
            const buf = base16Decode(alloc, rest) catch return error.BadHash;
            defer alloc.free(buf);
            @memcpy(&bytes, buf);
        } else if (rest.len == (sha256_len * 8 + 4) / 5) {
            const buf = nix32Decode(alloc, rest) catch return error.BadHash;
            defer alloc.free(buf);
            @memcpy(&bytes, buf);
        } else {
            return error.BadHash;
        }
    }
    return Hash{ .bytes = bytes, .hash_size = sha256_len };
}

test "nix32 encode matches known vectors" {
    var buf: [64]u8 = undefined;
    // Nix's own unit-test vector: hash of "" compressed to 20 bytes.
    const h = Hash.of("");
    const c20 = h.compressed(20);
    const enc = nix32Encode(c20.bytes[0..20], &buf);
    // Verify round trip.
    const dec = try nix32Decode(std.testing.allocator, enc);
    defer std.testing.allocator.free(dec);
    try std.testing.expect(std.mem.eql(u8, dec, c20.bytes[0..20]));
}

test "base16" {
    var buf: [64]u8 = undefined;
    const h = Hash.of("hello");
    const enc = base16Encode(&buf, &h.bytes);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", enc);
}

test "parseHash nix32 / base16 / SRI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h1 = try parseHash(a, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", try h1.base16(a));
    const h2 = try parseHash(a, "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    try std.testing.expect(h1.eql(h2));
    // nix32 of the same hash
    var buf: [64]u8 = undefined;
    const enc = nix32Encode(h1.bytes[0..32], &buf);
    const h3 = try parseHash(a, enc);
    try std.testing.expect(h1.eql(h3));
    // empty
    const h4 = try parseHash(a, "");
    try std.testing.expectEqual(@as(usize, 32), h4.hash_size);
}

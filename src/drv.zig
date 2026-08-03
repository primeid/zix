//! Derivations: ATerm serialization/parsing and `hashDerivationModulo`,
//! byte-for-byte compatible with Nix 2.34 (`derivations.cc`).

const std = @import("std");
const nixhash = @import("nixhash.zig");
const store = @import("store.zig");

pub const Output = struct {
    name: []const u8,
    path: []const u8, // store path or "" when masked
    hash_algo: []const u8, // e.g. "" | "sha256" | "r:sha256"
    hash: []const u8, // base16 (lowercase, no prefix) or ""
};

pub const InputDrv = struct {
    path: []const u8,
    outputs: []const []const u8, // output names used
};

pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const Derivation = struct {
    name: []const u8,
    outputs: []const Output, // sorted by name
    input_drvs: []const InputDrv,
    input_srcs: []const []const u8,
    platform: []const u8,
    builder: []const u8,
    args: []const []const u8,
    env: []const EnvPair, // sorted by name

    pub fn outputPathName(drv_name: []const u8, output_name: []const u8, alloc: std.mem.Allocator) ![]const u8 {
        if (std.mem.eql(u8, output_name, "out")) return drv_name;
        return std.fmt.allocPrint(alloc, "{s}-{s}", .{ drv_name, output_name });
    }

    /// Nix `Derivation::unparse` (traditional, unversioned ATerm).
    pub fn unparse(
        self: *const Derivation,
        alloc: std.mem.Allocator,
        st: *const store.Store,
        mask_outputs: bool,
        actual_inputs: ?[]const HashInput,
    ) ![]u8 {
        _ = st;
        var w = std.array_list.Managed(u8).init(alloc);
        try w.appendSlice("Derive([");
        for (self.outputs, 0..) |o, i| {
            if (i > 0) try w.append(',');
            try w.append('(');
            try printUnquoted(&w, o.name);
            try w.append(',');
            try printUnquoted(&w, if (mask_outputs) "" else o.path);
            try w.append(',');
            try printUnquoted(&w, o.hash_algo);
            try w.append(',');
            try printUnquoted(&w, o.hash);
            try w.append(')');
        }
        try w.appendSlice("],[");
        if (actual_inputs) |inputs| {
            for (inputs, 0..) |h, i| {
                if (i > 0) try w.append(',');
                try w.append('(');
                try printUnquoted(&w, h.hash);
                try w.appendSlice(",[");
                for (h.outputs, 0..) |o, j| {
                    if (j > 0) try w.append(',');
                    try printUnquoted(&w, o);
                }
                try w.appendSlice("])");
            }
        } else {
            for (self.input_drvs, 0..) |id, i| {
                if (i > 0) try w.append(',');
                try w.append('(');
                try printUnquoted(&w, id.path);
                try w.appendSlice(",[");
                for (id.outputs, 0..) |o, j| {
                    if (j > 0) try w.append(',');
                    try printUnquoted(&w, o);
                }
                try w.appendSlice("])");
            }
        }
        try w.appendSlice("],[");
        for (self.input_srcs, 0..) |s, i| {
            if (i > 0) try w.append(',');
            try printUnquoted(&w, s);
        }
        try w.append(']');
        try w.append(',');
        try printUnquoted(&w, self.platform);
        try w.append(',');
        try printString(&w, self.builder);
        try w.append(',');
        try printStrings(&w, self.args);
        try w.appendSlice(",[");
        for (self.env, 0..) |e, i| {
            if (i > 0) try w.append(',');
            try w.append('(');
            try printString(&w, e.name);
            try w.append(',');
            try printString(&w, if (mask_outputs and isOutput(self, e.name)) "" else e.value);
            try w.append(')');
        }
        try w.appendSlice("])");
        return w.toOwnedSlice();
    }
};

fn isOutput(drv: *const Derivation, name: []const u8) bool {
    for (drv.outputs) |o| {
        if (std.mem.eql(u8, o.name, name)) return true;
    }
    return false;
}

fn printUnquoted(w: *std.array_list.Managed(u8), s: []const u8) !void {
    try w.append('"');
    try w.appendSlice(s);
    try w.append('"');
}

fn printString(w: *std.array_list.Managed(u8), s: []const u8) !void {
    try w.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.appendSlice("\\\""),
            '\\' => try w.appendSlice("\\\\"),
            '\n' => try w.appendSlice("\\n"),
            '\r' => try w.appendSlice("\\r"),
            '\t' => try w.appendSlice("\\t"),
            else => try w.append(c),
        }
    }
    try w.append('"');
}

fn printStrings(w: *std.array_list.Managed(u8), args: []const []const u8) !void {
    try w.append('[');
    for (args, 0..) |a, i| {
        if (i > 0) try w.append(',');
        try printString(w, a);
    }
    try w.append(']');
}

pub const HashInput = struct {
    hash: []const u8, // base16 lowercase, no prefix
    outputs: []const []const u8,
};

pub const ReadDrvFn = *const fn (
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    path: []const u8,
) error{ OutOfMemory, IoError, ParseError, StoreError }!Derivation;

/// Nix `hashDerivationModulo`: compute per-output hashes.
/// `read_input_drv` reads+parses an input derivation by store path.
pub fn hashDerivationModulo(
    alloc: std.mem.Allocator,
    st: *const store.Store,
    drv: *const Derivation,
    mask_outputs: bool,
    read_input_drv: ReadDrvFn,
    ctx: *anyopaque,
    memo: *std.StringHashMap(nixhash.Hash),
) error{ OutOfMemory, IoError, ParseError, StoreError, BadDrv }![]const HashOut {
    // Fixed-output derivation → fixed hash per output.
    var fixed = false;
    for (drv.outputs) |o| {
        if (o.hash_algo.len > 0) {
            fixed = true;
            break;
        }
    }
    if (fixed) {
        var outs = std.array_list.Managed(HashOut).init(alloc);
        for (drv.outputs) |o| {
            const algo = o.hash_algo;
            const hex_str = o.hash;
            const out_path = o.path;
            const payload = try std.fmt.allocPrint(alloc, "fixed:out:{s}:{s}:{s}", .{ algo, hex_str, out_path });
            const h = nixhash.Hash.of(payload);
            try outs.append(.{ .name = o.name, .hash = h });
        }
        return outs.toOwnedSlice();
    }

    // Regular derivation: replace input drv paths with their hashes modulo.
    var inputs2 = std.array_list.Managed(HashInput).init(alloc);
    for (drv.input_drvs) |id| {
        const h = try hashDerivationModuloOfPath(alloc, st, id.path, read_input_drv, ctx, memo);
        for (id.outputs) |out_name| {
            var found = false;
            for (inputs2.items) |*hi| {
                if (std.mem.eql(u8, hi.hash, h)) {
                    const names = try alloc.alloc([]const u8, hi.outputs.len + 1);
                    @memcpy(names[0..hi.outputs.len], hi.outputs);
                    names[hi.outputs.len] = out_name;
                    hi.outputs = names;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try inputs2.append(.{ .hash = h, .outputs = &.{out_name} });
            }
        }
    }
    const contents = try drv.unparse(alloc, st, mask_outputs, inputs2.items);
    const h = nixhash.Hash.of(contents);
    var outs = std.array_list.Managed(HashOut).init(alloc);
    for (drv.outputs) |o| {
        try outs.append(.{ .name = o.name, .hash = h });
    }
    return outs.toOwnedSlice();
}

/// hashDerivationModulo for an input drv looked up by store path (memoized).
fn hashDerivationModuloOfPath(
    alloc: std.mem.Allocator,
    st: *const store.Store,
    path: []const u8,
    read_input_drv: ReadDrvFn,
    ctx: *anyopaque,
    memo: *std.StringHashMap(nixhash.Hash),
) error{ OutOfMemory, IoError, ParseError, StoreError, BadDrv }![]const u8 {
    if (memo.get(path)) |h| {
        return hex(alloc, h);
    }
    const drv = try read_input_drv(ctx, alloc, path);
    const outs = try hashDerivationModulo(alloc, st, &drv, false, read_input_drv, ctx, memo);
    var h: nixhash.Hash = undefined;
    var first = true;
    for (outs) |o| {
        if (first) {
            h = o.hash;
            first = false;
        } else if (!h.eql(o.hash)) {
            return error.BadDrv;
        }
    }
    if (first) return error.BadDrv;
    try memo.put(path, h);
    return hex(alloc, h);
}

pub const HashOut = struct {
    name: []const u8,
    hash: nixhash.Hash,
};

fn hex(alloc: std.mem.Allocator, h: nixhash.Hash) ![]const u8 {
    return nixhash.base16EncodeAlloc(alloc, h.bytes[0..h.hash_size]);
}

/// Compute the output path for an input-addressed output.
pub fn makeOutputPath(st: *const store.Store, output_name: []const u8, hash: nixhash.Hash, drv_name: []const u8) ![]const u8 {
    return st.makeOutputPath(output_name, hash, drv_name);
}

// ---------------------------------------------------------------------------
// ATerm parsing (for reading input derivations and `import` of .drv files)
// ---------------------------------------------------------------------------

pub const DrvParseError = error{ OutOfMemory, IoError, ParseError, StoreError, BadDrv };

pub const DrvParser = struct {
    alloc: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,

    fn expect(self: *DrvParser, what: []const u8) DrvParseError!void {
        if (!std.mem.startsWith(u8, self.s[self.i..], what)) return error.BadDrv;
        self.i += what.len;
    }

    fn peek(self: *DrvParser) u8 {
        if (self.i >= self.s.len) return 0;
        return self.s[self.i];
    }

    fn get(self: *DrvParser) DrvParseError!u8 {
        if (self.i >= self.s.len) return error.BadDrv;
        const c = self.s[self.i];
        self.i += 1;
        return c;
    }

    fn parseString(self: *DrvParser) DrvParseError![]const u8 {
        try self.expect("\"");
        var out = std.array_list.Managed(u8).init(self.alloc);
        while (true) {
            const c = try self.get();
            if (c == '"') break;
            if (c == '\\') {
                const e = try self.get();
                switch (e) {
                    'n' => try out.append('\n'),
                    'r' => try out.append('\r'),
                    't' => try out.append('\t'),
                    else => try out.append(e),
                }
            } else {
                try out.append(c);
            }
        }
        return out.toOwnedSlice();
    }

    fn parseStringList(self: *DrvParser) DrvParseError![]const []const u8 {
        try self.expect("[");
        var out = std.array_list.Managed([]const u8).init(self.alloc);
        while (true) {
            if (self.peek() == ']') {
                _ = try self.get();
                break;
            }
            if (self.peek() == ',') _ = try self.get();
            try out.append(try self.parseString());
        }
        return out.toOwnedSlice();
    }
};

/// Parse a `Derive(...)` ATerm (traditional form only).
pub fn parseDerivation(alloc: std.mem.Allocator, contents: []const u8) DrvParseError!Derivation {
    var p = DrvParser{ .alloc = alloc, .s = contents };
    try p.expect("Derive([");
    // outputs
    var outputs = std.array_list.Managed(Output).init(alloc);
    while (true) {
        if (p.peek() == ']') {
            _ = try p.get();
            break;
        }
        if (p.peek() == ',') _ = try p.get();
        try p.expect("(");
        const name = try p.parseString();
        try p.expect(",");
        const path = try p.parseString();
        try p.expect(",");
        const algo = try p.parseString();
        try p.expect(",");
        const hash = try p.parseString();
        try p.expect(")");
        try outputs.append(.{ .name = name, .path = path, .hash_algo = algo, .hash = hash });
    }
    try p.expect(",[");
    // input drvs
    var input_drvs = std.array_list.Managed(InputDrv).init(alloc);
    while (true) {
        if (p.peek() == ']') {
            _ = try p.get();
            break;
        }
        if (p.peek() == ',') _ = try p.get();
        try p.expect("(");
        const path = try p.parseString();
        try p.expect(",");
        const outs = try p.parseStringList();
        try p.expect(")");
        try input_drvs.append(.{ .path = path, .outputs = outs });
    }
    try p.expect(",");
    const input_srcs = try p.parseStringList();
    try p.expect(",");
    const platform = try p.parseString();
    try p.expect(",");
    const builder = try p.parseString();
    try p.expect(",");
    const args = try p.parseStringList();
    try p.expect(",[");
    var env = std.array_list.Managed(EnvPair).init(alloc);
    while (true) {
        if (p.peek() == ']') {
            _ = try p.get();
            break;
        }
        if (p.peek() == ',') _ = try p.get();
        try p.expect("(");
        const name = try p.parseString();
        try p.expect(",");
        const val = try p.parseString();
        try p.expect(")");
        try env.append(.{ .name = name, .value = val });
    }
    try p.expect(")");
    const name = storeNameFromPath(alloc, input_srcs, builder) catch "drv";
    // Derivation name = basename of drv path minus ".drv"; we recover it from
    // the caller. Use a placeholder and let callers overwrite.
    _ = name;
    return Derivation{
        .name = "",
        .outputs = outputs.items,
        .input_drvs = input_drvs.items,
        .input_srcs = input_srcs,
        .platform = platform,
        .builder = builder,
        .args = args,
        .env = env.items,
    };
}

fn storeNameFromPath(alloc: std.mem.Allocator, srcs: []const []const u8, builder: []const u8) ![]const u8 {
    _ = alloc;
    _ = srcs;
    _ = builder;
    return "drv";
}

test "drv unparse matches Nix ground truth" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var st = store.Store.init(a, "/nix/store", true);
    const outputs = [_]Output{.{ .name = "out", .path = "/nix/store/ak4bnbd0hy44016ypx2p50acsqdsms6p-testdrv", .hash_algo = "", .hash = "" }};
    const envs = [_]EnvPair{
        .{ .name = "builder", .value = "/bin/sh" },
        .{ .name = "name", .value = "testdrv" },
        .{ .name = "out", .value = "/nix/store/ak4bnbd0hy44016ypx2p50acsqdsms6p-testdrv" },
        .{ .name = "system", .value = "x86_64-linux" },
    };
    var drv = Derivation{
        .name = "testdrv",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .platform = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &envs,
    };
    const s = try drv.unparse(a, &st, false, null);
    try std.testing.expectEqualStrings(
        "Derive([(\"out\",\"/nix/store/ak4bnbd0hy44016ypx2p50acsqdsms6p-testdrv\",\"\",\"\")],[],[],\"x86_64-linux\",\"/bin/sh\",[],[(\"builder\",\"/bin/sh\"),(\"name\",\"testdrv\"),(\"out\",\"/nix/store/ak4bnbd0hy44016ypx2p50acsqdsms6p-testdrv\"),(\"system\",\"x86_64-linux\")])",
        s,
    );
    // masked unparse → output path empty; env "out" empty
    const sm = try drv.unparse(a, &st, true, null);
    try std.testing.expectEqualStrings(
        "Derive([(\"out\",\"\",\"\",\"\")],[],[],\"x86_64-linux\",\"/bin/sh\",[],[(\"builder\",\"/bin/sh\"),(\"name\",\"testdrv\"),(\"out\",\"\"),(\"system\",\"x86_64-linux\")])",
        sm,
    );
    // hashDerivationModulo of this drv must yield the known output path.
    var memo = std.StringHashMap(nixhash.Hash).init(a);
    const outs = try hashDerivationModulo(a, &st, &drv, true, readDrvStub, undefined, &memo);
    const out_path = try st.makeOutputPath("out", outs[0].hash, "testdrv");
    try std.testing.expectEqualStrings("/nix/store/ak4bnbd0hy44016ypx2p50acsqdsms6p-testdrv", out_path);
}

fn readDrvStub(ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8) error{ OutOfMemory, IoError, ParseError, StoreError }!Derivation {
    _ = ctx;
    _ = alloc;
    _ = path;
    return error.ParseError;
}

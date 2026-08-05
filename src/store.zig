//! Nix-compatible store: store path computation, NAR serialization and
//! source-path hashing.  Algorithms byte-for-byte compatible with Nix 2.34
//! (`store-dir-config.cc`, `archive.cc`, `path.cc`).

const std = @import("std");
const nixhash = @import("nixhash.zig");
const fsutil = @import("fsutil.zig");

pub const Hash = nixhash.Hash;
pub const sha256 = nixhash.sha256;

pub const FileIngestionMethod = enum { flat, recursive, git };

pub fn ingestionPrefix(method: FileIngestionMethod) []const u8 {
    return switch (method) {
        .flat => "",
        .recursive => "r:",
        .git => "git:",
    };
}

/// `StorePath`-style name validation (Nix `checkName`).
pub fn checkName(name: []const u8) error{InvalidName}!void {
    if (name.len == 0) return error.InvalidName;
    for (name) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or c == '+' or c == '-' or c == '.' or
            c == '_' or c == '?' or c == '=';
        if (!ok) return error.InvalidName;
    }
}

pub const PathInfo = struct {
    typ: []const u8, // "text" | "source" | "output:out" | ...
    nar_hash: []const u8, // base16
    refs: []const []const u8,
    deriver: ?[]const u8 = null,
    outputs: ?[]const []const u8 = null,
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    store_dir: []const u8,
    read_only: bool,
    /// realisation index (store path -> info)
    db: std.StringHashMap(PathInfo),

    pub fn init(alloc: std.mem.Allocator, store_dir: []const u8, read_only: bool) Store {
        return .{ .alloc = alloc, .store_dir = store_dir, .read_only = read_only, .db = std.StringHashMap(PathInfo).init(alloc) };
    }

    /// Load the realisation index (zix-db.json) if present.
    pub fn loadDb(self: *Store) !void {
        if (self.read_only) return;
        const db_path = try std.fs.path.join(self.alloc, &.{ self.store_dir, "zix-db.json" });
        const contents = fsutil.readFileAlloc(self.alloc, db_path, 1 << 30) catch return;
        var p = JsonDbParser{ .alloc = self.alloc, .s = contents };
        _ = p.parseInto(&self.db) catch return;
    }

    pub fn isRealised(self: *const Store, path: []const u8) bool {
        return self.db.contains(path);
    }

    /// Register a realised store object and persist the index.
    pub fn register(self: *Store, path: []const u8, info: PathInfo) !void {
        try self.db.put(path, info);
        if (!self.read_only) try self.saveDb();
    }

    fn saveDb(self: *Store) !void {
        try fsutil.makePath(self.store_dir);
        var w = std.array_list.Managed(u8).init(self.alloc);
        try w.appendSlice("{\n");
        var first = true;
        var it = self.db.iterator();
        while (it.next()) |e| {
            if (!first) try w.appendSlice(",\n");
            first = false;
            try w.appendSlice(try std.fmt.allocPrint(self.alloc, "  \"{s}\": {{\"type\":\"{s}\",\"narHash\":\"{s}\",\"refs\":[", .{ e.key_ptr.*, e.value_ptr.typ, e.value_ptr.nar_hash }));
            for (e.value_ptr.refs, 0..) |r, i| {
                if (i > 0) try w.appendSlice(",");
                try w.appendSlice(try std.fmt.allocPrint(self.alloc, "\"{s}\"", .{r}));
            }
            try w.appendSlice("]}");
        }
        try w.appendSlice("\n}\n");
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}/zix-db.json.tmp", .{self.store_dir});
        try fsutil.writeFile(tmp, w.items);
        const final = try std.fmt.allocPrint(self.alloc, "{s}/zix-db.json", .{self.store_dir});
        // Atomic rename so a crash never leaves a truncated database.
        try fsutil.renameFile(tmp, final);
    }

    fn cat(self: *const Store, parts: []const []const u8) ![]u8 {
        var len: usize = 0;
        for (parts) |p| len += p.len;
        const out = try self.alloc.alloc(u8, len);
        var off: usize = 0;
        for (parts) |p| {
            @memcpy(out[off .. off + p.len], p);
            off += p.len;
        }
        return out;
    }

    /// Nix `StoreDirConfig::makeStorePath(type, hash, name)`:
    /// s = type:sha256:hex:/nix/store:name, sha256(s), compress to 20 bytes.
    pub fn makeStorePath(self: *const Store, typ: []const u8, hash: Hash, name: []const u8) ![]const u8 {
        var hexbuf: [2 * 32]u8 = undefined;
        const hex = nixhash.base16Encode(&hexbuf, hash.bytes[0..hash.hash_size]);
        const s = try self.cat(&.{ typ, ":", "sha256:", hex, ":", self.store_dir, ":", name });
        const h = sha256(s);
        const c20 = nixhash.compressHash(&h, 20);
        var b32buf: [64]u8 = undefined;
        const b32 = nixhash.nix32Encode(c20[0..20], &b32buf);
        return self.cat(&.{ self.store_dir, "/", b32, "-", name });
    }

    /// Nix `makeOutputPath(id, hash, name)`.
    pub fn makeOutputPath(self: *const Store, id: []const u8, hash: Hash, drv_name: []const u8) ![]const u8 {
        const out_name = if (std.mem.eql(u8, id, "out")) drv_name else try self.cat(&.{ drv_name, "-", id });
        const typ = try self.cat(&.{ "output:", id });
        return self.makeStorePath(typ, hash, out_name);
    }

    /// Nix `makeFixedOutputPath(name, info)`.
    /// recursive+sha256 → type "source"; everything else → "fixed:out:" digest.
    pub fn makeFixedOutputPath(
        self: *const Store,
        name: []const u8,
        method: FileIngestionMethod,
        hash: Hash,
        refs: []const []const u8,
    ) ![]const u8 {
        if (hash.hash_size == 32 and method == .recursive) {
            var typ: []const u8 = "source";
            if (refs.len > 0) {
                var parts = std.array_list.Managed([]const u8).init(self.alloc);
                try parts.append("source");
                for (refs) |r| {
                    try parts.append(":");
                    try parts.append(r);
                }
                typ = try self.cat(parts.items);
            }
            return self.makeStorePath(typ, hash, name);
        }
        if (refs.len > 0) return error.FixedOutputWithRefs;
        var hexbuf: [2 * 32]u8 = undefined;
        const hex = nixhash.base16Encode(&hexbuf, hash.bytes[0..hash.hash_size]);
        // "fixed:out:" + rec + algo + ":" + hash + ":" (hash with algo prefix)
        const payload = try self.cat(&.{ "fixed:out:", ingestionPrefix(method), "sha256:", hex, ":" });
        const digest = Hash{ .bytes = sha256(payload), .hash_size = 32 };
        return self.makeOutputPath("out", digest, name);
    }

    /// Nix `makeTextPath` / `makeFixedOutputPathFromCA(TextInfo)`.
    pub fn makeTextPath(self: *const Store, name: []const u8, hash: Hash, refs: []const []const u8) ![]const u8 {
        var parts = std.array_list.Managed([]const u8).init(self.alloc);
        try parts.append("text");
        for (refs) |r| {
            try parts.append(":");
            try parts.append(r);
        }
        const typ = try self.cat(parts.items);
        return self.makeStorePath(typ, hash, name);
    }

    pub fn isInStore(self: *const Store, path: []const u8) bool {
        if (path.len <= self.store_dir.len) return false;
        return std.mem.startsWith(u8, path, self.store_dir) and path[self.store_dir.len] == '/';
    }

    pub fn storePathName(self: *const Store, path: []const u8) ?[]const u8 {
        if (!self.isInStore(path)) return null;
        const rest = path[self.store_dir.len + 1 ..];
        const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
        return rest[dash + 1 ..];
    }

    /// Write a text file to the store (like `builtins.toFile` / `addTextToStore`).
    pub fn writeText(self: *const Store, name: []const u8, contents: []const u8, refs: []const []const u8) ![]const u8 {
        try checkName(name);
        const hash = Hash.of(contents);
        const path = try self.makeTextPath(name, hash, refs);
        if (!self.read_only) {
            try fsutil.makePath(self.store_dir);
            if (contents.len > 1 << 26) {
            }
            try fsutil.writeFile(path, contents);
        }
        return path;
    }
};

// ---------------------------------------------------------------------------
// NAR serialization (Nix `archive.cc`).  Every token is:
//   u64-le length ++ bytes ++ zero padding to a multiple of 8.
// ---------------------------------------------------------------------------

pub const NarWriter = struct {
    alloc: std.mem.Allocator,
    buf: std.array_list.Managed(u8),

    pub fn init(alloc: std.mem.Allocator) NarWriter {
        return .{ .alloc = alloc, .buf = std.array_list.Managed(u8).init(alloc) };
    }

    pub fn writeString(self: *NarWriter, s: []const u8) !void {
        try self.buf.appendSlice(std.mem.asBytes(&@as(u64, s.len)));
        try self.buf.appendSlice(s);
        const pad = (8 - (s.len % 8)) % 8;
        var i: usize = 0;
        while (i < pad) : (i += 1) try self.buf.append(0);
    }
};

/// Serialize `path` into NAR format (Nix `dumpPath`).
pub const FilterFn = *const fn (ctx: *anyopaque, path: []const u8, kind: []const u8) bool;

pub fn narDump(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var w = NarWriter.init(alloc);
    try w.writeString("nix-archive-1");
    try narNode(&w, path);
    return w.buf.items;
}

/// NAR dump with a per-entry filter (for `builtins.path { filter = ...; }`).
/// Excluded entries are omitted entirely, like Nix's filterSource.
pub fn narDumpFiltered(alloc: std.mem.Allocator, path: []const u8, filter_ctx: *anyopaque, filter: FilterFn) ![]const u8 {
    var w = NarWriter.init(alloc);
    try w.writeString("nix-archive-1");
    _ = try narNodeFiltered(&w, path, filter_ctx, filter);
    return w.buf.items;
}

fn kindString(kind: fsutil.Kind) []const u8 {
    return switch (kind) {
        .file => "regular",
        .directory => "directory",
        .symlink => "symlink",
        else => "unknown",
    };
}

fn narNode(w: *NarWriter, path: []const u8) !void {
    const st = try fsutil.statPath(path);
    switch (st.kind) {
        .symlink => {
            const target = try fsutil.readLinkAlloc(w.alloc, path);
            try w.writeString("(");
            try w.writeString("type");
            try w.writeString("symlink");
            try w.writeString("target");
            try w.writeString(target);
            try w.writeString(")");
        },
        .file => {
            try w.writeString("(");
            try w.writeString("type");
            try w.writeString("regular");
            if (st.executable) {
                try w.writeString("executable");
                try w.writeString("");
            }
            try w.writeString("contents");
            const contents = try fsutil.readFileAlloc(w.alloc, path, 1 << 30);
            try w.writeString(contents);
            try w.writeString(")");
        },
        .directory => {
            try w.writeString("(");
            try w.writeString("type");
            try w.writeString("directory");
            const names = try fsutil.readDirNames(w.alloc, path);
            for (names) |name| {
                const child = try std.fs.path.join(w.alloc, &.{ path, name });
                try w.writeString("entry");
                try w.writeString("(");
                try w.writeString("name");
                try w.writeString(name);
                try w.writeString("node");
                try narNode(w, child);
                try w.writeString(")");
            }
            try w.writeString(")");
        },
        .other => return error.NotAValidPath,
    }
}

fn narNodeFiltered(w: *NarWriter, path: []const u8, ctx: *anyopaque, filter: FilterFn) !bool {
    const st = try fsutil.statPath(path);
    if (!filter(ctx, path, kindString(st.kind))) {
        return false; // excluded — caller skips the entry
    }
    switch (st.kind) {
        .symlink => {
            const target = try fsutil.readLinkAlloc(w.alloc, path);
            try w.writeString("(");
            try w.writeString("type");
            try w.writeString("symlink");
            try w.writeString("target");
            try w.writeString(target);
            try w.writeString(")");
            return true;
        },
        .file => {
            try w.writeString("(");
            try w.writeString("type");
            try w.writeString("regular");
            if (st.executable) {
                try w.writeString("executable");
                try w.writeString("");
            }
            try w.writeString("contents");
            const contents = try fsutil.readFileAlloc(w.alloc, path, 1 << 30);
            try w.writeString(contents);
            try w.writeString(")");
            return true;
        },
        .directory => {
            try w.writeString("(");
            try w.writeString("type");
            try w.writeString("directory");
            const names = try fsutil.readDirNames(w.alloc, path);
            for (names) |name| {
                const child = try std.fs.path.join(w.alloc, &.{ path, name });
                const cst = try fsutil.statPath(child);
                if (!filter(ctx, child, kindString(cst.kind))) continue;
                try w.writeString("entry");
                try w.writeString("(");
                try w.writeString("name");
                try w.writeString(name);
                try w.writeString("node");
                _ = try narNodeFiltered(w, child, ctx, filter);
                try w.writeString(")");
            }
            try w.writeString(")");
            return true;
        },
        .other => return error.NotAValidPath,
    }
}

/// Nix `hashPath` flat: sha256 of file contents.
pub fn hashFlatFile(alloc: std.mem.Allocator, path: []const u8) !Hash {
    const contents = try fsutil.readFileAlloc(alloc, path, 1 << 30);
    return Hash.of(contents);
}

/// Nix `hashPath` recursive: sha256 of the NAR serialization.
pub fn hashRecursive(alloc: std.mem.Allocator, path: []const u8) !Hash {
    const nar = try narDump(alloc, path);
    return Hash.of(nar);
}

/// Compute the store path for copying `path` into the store (recursive
/// sha256, no refs — the default for `import`/path coercion).
/// Copy a path into the store applying a Nix filter predicate
/// (path: type: bool) — used by `builtins.filterSource`.
pub const FilterCtx = struct {
    st: *anyopaque,
    filterCheck: *const fn (ctx: *anyopaque, p: []const u8, kind: []const u8) bool,
};

pub fn addPathToStoreFiltered(self: *const Store, name: []const u8, path: []const u8, filter_ctx: FilterCtx) ![]const u8 {
    try checkName(name);
    const nar = try narDumpFiltered(self.alloc, path, filter_ctx.st, filter_ctx.filterCheck);
    const hash = Hash.of(nar);
    return self.makeFixedOutputPath(name, .recursive, hash, &.{});
}

pub fn addPathToStore(self: *const Store, name: []const u8, path: []const u8) ![]const u8 {
    // Nix's `copyPathToStore` uses `ContentAddressMethod::Raw::NixArchive`:
    // the NAR hash of the path (files AND directories alike).
    try checkName(name);
    const nar = try narDump(self.alloc, path);
    const hash = Hash.of(nar);
    return self.makeFixedOutputPath(name, .recursive, hash, &.{});
}

/// Copy `path` into the store: compute the path, dump the NAR (or copy the
/// file), register it. Returns the store path.
pub fn addToStoreWrite(self: *Store, name: []const u8, path: []const u8, method: FileIngestionMethod) ![]const u8 {
    try fsutil.makePath(self.store_dir);
    const sp = if (method == .recursive)
        try addPathToStore(self, name, path)
    else
        blk: {
            const st = try fsutil.statPath(path);
            if (st.kind != .file) return error.NotAValidPath;
            const h = try hashFlatFile(self.alloc, path);
            break :blk try self.makeFixedOutputPath(name, .flat, h, &.{});
        };
    try writeObject(self, sp, path, method);
    const h = if (method == .recursive) try hashRecursive(self.alloc, path) else try hashFlatFile(self.alloc, path);
    var hexbuf: [2 * 32]u8 = undefined;
    const hex = nixhash.base16Encode(&hexbuf, h.bytes[0..h.hash_size]);
    try self.register(sp, .{
        .typ = if (method == .recursive) "source" else "output:out",
        .nar_hash = try self.alloc.dupe(u8, hex),
        .refs = &.{},
    });
    return sp;
}

/// Write a store object: recursive → NAR file; flat → plain file copy.
fn writeObject(self: *Store, store_path: []const u8, src: []const u8, method: FileIngestionMethod) !void {
    try fsutil.makePath(self.store_dir);
    const st = try fsutil.statPath(src);
    if (method == .recursive) {
        if (st.kind == .file or st.kind == .symlink) {
            const contents = if (st.kind == .file) try fsutil.readFileAlloc(self.alloc, src, 1 << 30) else try fsutil.readLinkAlloc(self.alloc, src);
            try fsutil.writeFile(store_path, contents);
        } else {
            // directory: write the NAR as the object content (like Nix)
            const nar = try narDump(self.alloc, src);
            try fsutil.writeFile(store_path, nar);
        }
    } else {
        const contents = try fsutil.readFileAlloc(self.alloc, src, 1 << 30);
        try fsutil.writeFile(store_path, contents);
    }
}

/// Minimal JSON object parser for zix-db.json.
const JsonDbParser = struct {
    alloc: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,

    fn skipWs(self: *JsonDbParser) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\n' or self.s[self.i] == '\t' or self.s[self.i] == '\r')) self.i += 1;
    }

    fn parseString(self: *JsonDbParser) ![]const u8 {
        if (self.i >= self.s.len or self.s[self.i] != '"') return error.BadDb;
        self.i += 1;
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] != '"') self.i += 1;
        if (self.i >= self.s.len) return error.BadDb;
        const out = self.s[start..self.i];
        self.i += 1;
        return out;
    }

    fn parseInto(self: *JsonDbParser, db: *std.StringHashMap(PathInfo)) !void {
        self.skipWs();
        if (self.i >= self.s.len or self.s[self.i] != '{') return error.BadDb;
        self.i += 1;
        while (true) {
            self.skipWs();
            if (self.i < self.s.len and self.s[self.i] == '}') break;
            const key = try self.parseString();
            self.skipWs();
            if (self.i >= self.s.len or self.s[self.i] != ':') return error.BadDb;
            self.i += 1;
            self.skipWs();
            if (self.i < self.s.len and self.s[self.i] == '{') {
                self.i += 1;
                var typ: []const u8 = "";
                var nar: []const u8 = "";
                var refs = std.array_list.Managed([]const u8).init(self.alloc);
                while (true) {
                    self.skipWs();
                    if (self.i < self.s.len and self.s[self.i] == '}') {
                        self.i += 1;
                        break;
                    }
                    const field = try self.parseString();
                    self.skipWs();
                    if (self.i >= self.s.len or self.s[self.i] != ':') return error.BadDb;
                    self.i += 1;
                    self.skipWs();
                    if (std.mem.eql(u8, field, "refs") and self.i < self.s.len and self.s[self.i] == '[') {
                        self.i += 1;
                        while (true) {
                            self.skipWs();
                            if (self.i < self.s.len and self.s[self.i] == ']') {
                                self.i += 1;
                                break;
                            }
                            try refs.append(try self.parseString());
                            self.skipWs();
                            if (self.i < self.s.len and self.s[self.i] == ',') self.i += 1;
                        }
                    } else {
                        const v = try self.parseString();
                        if (std.mem.eql(u8, field, "type")) typ = v;
                        if (std.mem.eql(u8, field, "narHash")) nar = v;
                    }
                }
                try db.put(key, .{ .typ = typ, .nar_hash = nar, .refs = refs.items });
            } else {
                _ = try self.parseString();
            }
            self.skipWs();
            if (self.i < self.s.len and self.s[self.i] == ',') self.i += 1;
        }
    }
};

test "store path for toFile matches Nix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var store = Store.init(alloc, "/nix/store", true);
    // `builtins.toFile "x" "hello"` computed by real Nix 2.34.
    const hash = Hash.of("hello");
    const p = try store.makeTextPath("x", hash, &.{});
    try std.testing.expectEqualStrings("/nix/store/4g4g9i669dl63abpww0djbl2jxl6bwiz-x", p);
}

fn decodeBase64Digest(alloc: std.mem.Allocator, sri: []const u8) !Hash {
    const rest = sri[7..];
    const decoded = try alloc.alloc(u8, 32);
    defer alloc.free(decoded);
    _ = try std.base64.standard.Decoder.decode(decoded, rest);
    var h: Hash = undefined;
    @memcpy(&h.bytes, decoded);
    h.hash_size = 32;
    return h;
}

test "nar hash matches nix hash path (ground truth from Nix 2.34)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctr: usize = 0;
    const ts = std.Io.Clock.now(.real, fsutil.io);
    const stamp: i64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
    const dir = try std.fmt.allocPrint(alloc, "zix-test-nar-{d}-{d}", .{ stamp, @atomicRmw(usize, &ctr, .Add, 1, .seq_cst) });
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(fsutil.io, dir) catch {};
    try fsutil.makePath(dir);
    const fpath = try std.fs.path.join(alloc, &.{ dir, "hello.txt" });
    defer alloc.free(fpath);
    try fsutil.writeFile(fpath, "hello");
    // `nix hash path <file> --type sha256` (recursive, single file)
    const expected_file = try decodeBase64Digest(alloc, "sha256-CkMIecJm+LV/QJKg+TXPP6zUi7zN5XYNR0jKQFFx6Wk=");
    const hf = try hashRecursive(alloc, fpath);
    try std.testing.expect(hf.eql(expected_file));
    // flat mode: plain sha256 of contents
    const hflat = try hashFlatFile(alloc, fpath);
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        try hflat.base16(alloc),
    );
    // `nix hash path <dir>` — directory NAR
    const expected_dir = try decodeBase64Digest(alloc, "sha256-KAu6dmvIOUDFbBf9INpPeZtIaA0nfu2LV8byhsTF9LU=");
    const hd = try hashRecursive(alloc, dir);
    try std.testing.expect(hd.eql(expected_dir));
}

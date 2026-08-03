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

pub const Store = struct {
    alloc: std.mem.Allocator,
    store_dir: []const u8,
    read_only: bool,

    pub fn init(alloc: std.mem.Allocator, store_dir: []const u8, read_only: bool) Store {
        return .{ .alloc = alloc, .store_dir = store_dir, .read_only = read_only };
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
                for (refs) |r| try parts.append(r);
                typ = try self.cat(parts.items);
            }
            return self.makeStorePath(typ, hash, name);
        }
        if (refs.len > 0) return error.FixedOutputWithRefs;
        var hexbuf: [2 * 32]u8 = undefined;
        const hex = nixhash.base16Encode(&hexbuf, hash.bytes[0..hash.hash_size]);
        const payload = try self.cat(&.{ "fixed:out:", ingestionPrefix(method), hex, ":" });
        const digest = Hash{ .bytes = sha256(payload), .hash_size = 32 };
        return self.makeOutputPath("out", digest, name);
    }

    /// Nix `makeTextPath` / `makeFixedOutputPathFromCA(TextInfo)`.
    pub fn makeTextPath(self: *const Store, name: []const u8, hash: Hash, refs: []const []const u8) ![]const u8 {
        var parts = std.array_list.Managed([]const u8).init(self.alloc);
        try parts.append("text");
        for (refs) |r| try parts.append(r);
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
pub fn narDump(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var w = NarWriter.init(alloc);
    try w.writeString("nix-archive-1");
    try narNode(&w, path);
    return w.buf.items;
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
pub fn addPathToStore(self: *const Store, name: []const u8, path: []const u8) ![]const u8 {
    try checkName(name);
    const st = try fsutil.statPath(path);
    const hash = switch (st.kind) {
        .symlink => blk: {
            const target = try fsutil.readLinkAlloc(self.alloc, path);
            break :blk Hash.of(target);
        },
        .file => try hashFlatFile(self.alloc, path),
        .directory => try hashRecursive(self.alloc, path),
        else => return error.NotAValidPath,
    };
    return self.makeFixedOutputPath(name, .recursive, hash, &.{});
}

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
    const tmp_root = "/tmp/zix-test-nar";
    var ctr: usize = 0;
    const pid: u64 = @intCast(@as(std.posix.pid_t, std.os.linux.getpid()));
    const dir = try std.fmt.allocPrint(alloc, "{s}-{d}-{d}", .{ tmp_root, pid, @atomicRmw(usize, &ctr, .Add, 1, .seq_cst) });
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

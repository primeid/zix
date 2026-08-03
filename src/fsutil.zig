//! Thin filesystem helpers over Zig 0.16's `std.Io` API.

const std = @import("std");

/// The default (single-threaded, debug) Io instance.
pub const io: std.Io = std.Options.debug_io;

pub const Kind = enum { file, directory, symlink, other };

pub const Stat = struct {
    kind: Kind,
    executable: bool,
    size: u64,
};

pub fn statPath(path: []const u8) !Stat {
    // Check symlink first (statFile follows links).
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().readLink(io, path, &buf)) |_| {
        return .{ .kind = .symlink, .executable = false, .size = 0 };
    } else |_| {}
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    var executable = false;
    _ = std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch |e| switch (e) {
        error.AccessDenied => {},
        else => {},
    };
    if (std.Io.Dir.cwd().access(io, path, .{ .execute = true })) |_| {
        executable = true;
    } else |_| {}
    return .{
        .kind = switch (st.kind) {
            .file => .file,
            .directory => .directory,
            else => .other,
        },
        .executable = executable,
        .size = st.size,
    };
}

pub fn isDirectory(path: []const u8) bool {
    const st = statPath(path) catch return false;
    return st.kind == .directory;
}

pub fn isSymlink(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return std.Io.Dir.cwd().readLink(io, path, &buf) != error.NotLink;
}

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max));
}

pub fn readLinkAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, path, &buf);
    return alloc.dupe(u8, buf[0..n]);
}

/// Names of the entries of `path` (files and dirs), sorted byte-wise.
pub fn readDirNames(alloc: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var names = std.array_list.Managed([]const u8).init(alloc);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try names.append(try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return names.items;
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try std.Io.File.writeStreamingAll(f, io, data);
}

pub fn realpathAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().realpathAlloc(io, path, alloc);
}

pub fn makePath(path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

pub fn pathExists(path: []const u8) bool {
    _ = statPath(path) catch return false;
    return true;
}

pub fn homeDir() []const u8 {
    return "/";
}

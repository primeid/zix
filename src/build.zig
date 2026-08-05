//! The realisation layer: build derivations into store outputs.
//! Phase 1 of the roadmap — `zix build`.

const std = @import("std");
const store = @import("store.zig");
const drvmod = @import("drv.zig");
const fsutil = @import("fsutil.zig");
const nixhash = @import("nixhash.zig");

pub const BuildError = error{
    OutOfMemory,
    IoError,
    NotFound,
    Cycle,
    BadDrv,
    BuildFailed,
    OutputMissing,
    HashMismatch,
    StoreError,
    Unsupported,
} || std.mem.Allocator.Error;

pub const Step = struct {
    drv: drvmod.Derivation,
    drv_path: []const u8,
    done: bool = false,
};

/// Read a `.drv` from the store and parse it.
pub fn loadDrv(alloc: std.mem.Allocator, st: *const store.Store, drv_path: []const u8) BuildError!drvmod.Derivation {
    if (!st.isInStore(drv_path)) return error.NotFound;
    const contents = fsutil.readFileAlloc(alloc, drv_path, 1 << 30) catch return error.IoError;
    var d = drvmod.parseDerivation(alloc, contents) catch return error.BadDrv;
    d.name = st.storePathName(drv_path) orelse return error.BadDrv;
    return d;
}

/// Topologically sort a drv and all its input drvs (dependencies first).
pub fn planBuild(alloc: std.mem.Allocator, st: *const store.Store, drv_path: []const u8) BuildError![]Step {
    var steps = std.array_list.Managed(Step).init(alloc);
    var seen = std.StringHashMap(void).init(alloc);
    var visiting = std.array_list.Managed([]const u8).init(alloc);
    try addDrv(alloc, st, drv_path, &steps, &seen, &visiting);
    return steps.toOwnedSlice();
}

fn addDrv(
    alloc: std.mem.Allocator,
    st: *const store.Store,
    drv_path: []const u8,
    steps: *std.array_list.Managed(Step),
    seen: *std.StringHashMap(void),
    visiting: *std.array_list.Managed([]const u8),
) BuildError!void {
    if (seen.contains(drv_path)) return;
    for (visiting.items) |v| {
        if (std.mem.eql(u8, v, drv_path)) return error.Cycle;
    }
    try visiting.append(drv_path);
    const drv = try loadDrv(alloc, st, drv_path);
    for (drv.input_drvs) |id| {
        try addDrv(alloc, st, id.path, steps, seen, visiting);
    }
    _ = visiting.pop();
    try seen.put(drv_path, {});
    try steps.append(.{ .drv = drv, .drv_path = drv_path });
}

/// Execute one build step: run the builder, validate and register outputs.
pub fn buildOne(
    alloc: std.mem.Allocator,
    st: *store.Store,
    step: *Step,
    build_dir: []const u8,
    verbose: bool,
    parent_env: ?*const std.process.Environ.Map,
    sandbox: bool,
) BuildError!void {
    if (step.done) return;
    const drv = &step.drv;

    // Build environment from the drv env.  For variables the derivation
    // doesn't set (PATH/HOME/TMPDIR), fall back to the parent environment so
    // builders find host tools on any system (e.g. NixOS has no /usr/bin).
    var env = std.process.Environ.Map.init(alloc);
    for (drv.env) |e| {
        env.put(e.name, e.value) catch return error.OutOfMemory;
    }
    // Structured attributes: write the __json blob to a file and point
    // NIX_ATTRS_JSON_FILE at it (like Nix's `__structuredAttrs`).
    if (env.get("__json")) |json| {
        const json_file = try std.fmt.allocPrint(alloc, "{s}/attrs.json", .{build_dir});
        fsutil.makePath(build_dir) catch {};
        fsutil.writeFile(json_file, json) catch return error.IoError;
        env.put("NIX_ATTRS_JSON_FILE", json_file) catch return error.OutOfMemory;
        env.put("NIX_ATTRS_SH_FILE", try std.fmt.allocPrint(alloc, "{s}/attrs.sh", .{build_dir})) catch return error.OutOfMemory;
    }
    // Sandboxed builds get a scrubbed environment: only PATH/HOME/TMPDIR
    // fall back to the parent; everything else comes from the derivation.
    const defaults = [_][]const u8{ "PATH", "HOME", "TMPDIR" };
    for (defaults) |d| {
        if (env.get(d) == null) {
            if (parent_env) |pe| {
                if (pe.get(d)) |v| {
                    env.put(d, v) catch return error.OutOfMemory;
                    continue;
                }
            }
            if (std.mem.eql(u8, d, "HOME")) env.put("HOME", "/homeless-shelter") catch return error.OutOfMemory;
            if (std.mem.eql(u8, d, "TMPDIR")) env.put("TMPDIR", "/tmp") catch return error.OutOfMemory;
        }
    }

    // Make sure the output directories don't exist yet (fresh outputs).
    for (drv.outputs) |o| {
        if (fsutil.pathExists(o.path)) {
            std.debug.print("zix: warning: output {s} already exists, refusing to build\n", .{o.path});
            step.done = true;
            return;
        }
    }

    if (verbose) {
        std.debug.print("zix: building {s}\n", .{step.drv_path});
    }

    var argv = std.array_list.Managed([]const u8).init(alloc);
    if (sandbox) {
        // Sandbox via bubblewrap: read-only root, isolated network/PID/mount
        // namespaces, tmpfs for scratch dirs.  The store and build dirs stay
        // writable (the build must write outputs into the store).
        const bwrap_path = "bwrap";
        try argv.append(bwrap_path);
        try argv.append("--unshare-all");
        try argv.append("--die-with-parent");
        try argv.append("--ro-bind");
        try argv.append("/");
        try argv.append("/");
        try argv.append("--proc");
        try argv.append("/proc");
        try argv.append("--tmpfs");
        try argv.append("/tmp");
        try argv.append("--dev");
        try argv.append("/dev");
        // The store is read-only inside the sandbox (a builder must not
        // tamper with unrelated store objects); only the output paths are
        // writable.  The build dir is also writable for scratch work.
        try argv.append("--ro-bind");
        try argv.append(st.store_dir);
        try argv.append(st.store_dir);
        try argv.append("--bind");
        try argv.append(build_dir);
        try argv.append(build_dir);
        for (drv.outputs) |o| {
            if (o.path.len > 0) {
                // bwrap can only bind existing paths: pre-create the output
                // directories (the builder writes into them).
                fsutil.makePath(o.path) catch {};
                try argv.append("--bind");
                try argv.append(o.path);
                try argv.append(o.path);
            }
        }
        try argv.append("--");
    }
    try argv.append(drv.builder);
    for (drv.args) |a| try argv.append(a);

    var child = std.process.spawn(fsutil.io, .{
        .argv = argv.items,
        .environ_map = &env,
        .cwd = .{ .path = build_dir },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        std.debug.print("zix: error: cannot spawn builder {s}: {s}\n", .{ drv.builder, @errorName(e) });
        return error.BuildFailed;
    };
    const term = child.wait(fsutil.io) catch return error.BuildFailed;
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("zix: error: builder for {s} failed with exit code {d}\n", .{ step.drv_path, code });
            return error.BuildFailed;
        },
        else => {
            std.debug.print("zix: error: builder for {s} terminated abnormally\n", .{step.drv_path});
            return error.BuildFailed;
        },
    }

    // Validate and register outputs.
    for (drv.outputs) |o| {
        if (!fsutil.pathExists(o.path)) {
            std.debug.print("zix: error: builder for {s} did not produce output '{s}'\n", .{ step.drv_path, o.path });
            return error.OutputMissing;
        }
        // Fixed-output derivations: verify the hash.
        if (o.hash_algo.len > 0) {
            const expected = nixhash.parseHash(alloc, o.hash) catch return error.BadDrv;
            const recursive = std.mem.startsWith(u8, o.hash_algo, "r:");
            const actual = if (recursive)
                store.hashRecursive(alloc, o.path) catch return error.IoError
            else
                store.hashFlatFile(alloc, o.path) catch return error.IoError;
            if (!expected.eql(actual)) {
                std.debug.print("zix: error: hash mismatch for output {s}\n", .{o.path});
                return error.HashMismatch;
            }
        }
        const h = store.hashRecursive(alloc, o.path) catch return error.IoError;
        var hexbuf: [2 * 32]u8 = undefined;
        const hex = nixhash.base16Encode(&hexbuf, h.bytes[0..h.hash_size]);
        // references: input sources + input drv paths
        var refs = std.array_list.Managed([]const u8).init(alloc);
        try refs.appendSlice(drv.input_srcs);
        for (drv.input_drvs) |id| try refs.append(id.path);
        st.register(o.path, .{
            .typ = try std.fmt.allocPrint(alloc, "output:{s}", .{o.name}),
            .nar_hash = try alloc.dupe(u8, hex),
            .refs = refs.items,
            .deriver = step.drv_path,
            .outputs = &[_][]const u8{o.name},
        }) catch return error.StoreError;
        if (verbose) std.debug.print("zix: registered {s}\n", .{o.path});
    }
    step.done = true;
}

/// Build a drv and all its inputs.
pub fn buildAll(
    alloc: std.mem.Allocator,
    st: *store.Store,
    drv_path: []const u8,
    build_dir: []const u8,
    verbose: bool,
    parent_env: ?*const std.process.Environ.Map,
    sandbox: bool,
) BuildError![]const []const u8 {
    const plan = try planBuild(alloc, st, drv_path);
    var out = std.array_list.Managed([]const u8).init(alloc);
    for (plan) |*step| {
        try buildOne(alloc, st, step, build_dir, verbose, parent_env, sandbox);
        for (step.drv.outputs) |o| try out.append(o.path);
    }
    return out.toOwnedSlice();
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default: interpreter recursion needs small stack frames;
    // pass -Doptimize=Debug for debugging.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const lib = b.addModule("zix", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zix", .module = lib },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const lib_tests = b.addTest(.{ .root_module = lib });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // `zig build verify`: run the nix-vs-zix comparison battery and the
    // golden language tests (requires `nix` on PATH).
    const verify_step = b.step("verify", "Run the nix-vs-zix comparison battery (requires nix)");
    const verify_cmd = b.addSystemCommand(&.{ "bash", "tests/nix-vs-zix.sh" });
    verify_step.dependOn(&verify_cmd.step);
    verify_cmd.step.dependOn(b.getInstallStep());

    const build_step = b.step("build-smoke", "Build a derivation end-to-end in a temp store");
    const build_cmd = b.addSystemCommand(&.{ "bash", "tests/build-smoke.sh" });
    build_step.dependOn(&build_cmd.step);
    build_cmd.step.dependOn(b.getInstallStep());

    const fuzz_step = b.step("fuzz", "Fuzz smoke: random inputs must not crash the CLI");
    const fuzz_cmd = b.addSystemCommand(&.{ "bash", "tests/fuzz.sh" });
    fuzz_step.dependOn(&fuzz_cmd.step);
    fuzz_cmd.step.dependOn(b.getInstallStep());

    const lang_step = b.step("lang", "Run the golden language tests (tests/lang)");
    const lang_cmd = b.addSystemCommand(&.{ "bash", "tests/run-lang.sh" });
    lang_step.dependOn(&lang_cmd.step);
    lang_cmd.step.dependOn(b.getInstallStep());
}

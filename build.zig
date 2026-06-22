const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/openfugu.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "openfugu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("openfugu", mod);
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("openfugu", mod);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const fake_agent = b.addExecutable(.{
        .name = "openfugu-fake-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/fake_agent.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const fake_agent_step = b.addInstallArtifact(fake_agent, .{});
    const check_file = b.addExecutable(.{
        .name = "openfugu-check-file",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/check_file.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const check_file_step = b.addInstallArtifact(check_file, .{});
    const sleep_agent = b.addExecutable(.{
        .name = "openfugu-sleep-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/sleep_agent.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const sleep_agent_step = b.addInstallArtifact(sleep_agent, .{});
    const probe_cli = b.addExecutable(.{
        .name = "openfugu-probe-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/probe_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const probe_cli_step = b.addInstallArtifact(probe_cli, .{});
    tests.step.dependOn(&fake_agent_step.step);
    tests.step.dependOn(&check_file_step.step);
    tests.step.dependOn(&sleep_agent_step.step);
    tests.step.dependOn(&probe_cli_step.step);
    const run_tests = b.addRunArtifact(tests);
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "fake_agent_path", b.getInstallPath(.bin, "openfugu-fake-agent"));
    test_options.addOption([]const u8, "check_file_path", b.getInstallPath(.bin, "openfugu-check-file"));
    test_options.addOption([]const u8, "sleep_agent_path", b.getInstallPath(.bin, "openfugu-sleep-agent"));
    test_options.addOption([]const u8, "probe_cli_path", b.getInstallPath(.bin, "openfugu-probe-cli"));
    test_mod.addOptions("test_options", test_options);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const real_cli_tests = b.option(bool, "real-cli-tests", "Enable quota-consuming real CLI smoke tests") orelse false;
    const smoke_options = b.addOptions();
    smoke_options.addOption(bool, "real_cli_tests", real_cli_tests);
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tests/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_mod.addOptions("smoke_options", smoke_options);
    const smoke_tests = b.addTest(.{ .root_module = smoke_mod });
    const run_smoke = b.addRunArtifact(smoke_tests);
    const smoke_step = b.step("smoke", "Run opt-in real CLI smoke tests");
    smoke_step.dependOn(&run_smoke.step);
}

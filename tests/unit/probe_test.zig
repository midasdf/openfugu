const std = @import("std");
const openfugu = @import("openfugu");
const test_options = @import("test_options");

test "probe detects version subscription auth and runnable status" {
    const report = try openfugu.probe.detect(std.testing.allocator, std.testing.io, .{
        .name = "claude",
        .version_argv = &.{ test_options.probe_cli_path, "--version" },
        .auth_argv = &.{ test_options.probe_cli_path, "auth" },
        .supported_version = "supported-1",
        .profile = openfugu.claude_code.profileForVersion("supported-1"),
        .subscription = openfugu.config.Config.default().subscription,
    });

    try std.testing.expect(report.exists);
    try std.testing.expectEqualStrings("supported-1", report.version);
    try std.testing.expectEqual(openfugu.types.AuthKind.subscription, report.auth);
    try std.testing.expectEqual(openfugu.types.Compatibility.supported, report.compatibility);
    try std.testing.expect(report.non_interactive);
    try std.testing.expect(report.structured_output);
    try std.testing.expect(report.runnable);
}

test "probe rejects api key auth under subscription only" {
    const report = try openfugu.probe.detect(std.testing.allocator, std.testing.io, .{
        .name = "claude",
        .version_argv = &.{ test_options.probe_cli_path, "--version" },
        .auth_argv = &.{ test_options.probe_cli_path, "apikey" },
        .supported_version = "supported-1",
        .profile = openfugu.claude_code.profileForVersion("supported-1"),
        .subscription = openfugu.config.Config.default().subscription,
    });

    try std.testing.expectEqual(openfugu.types.AuthKind.api_key, report.auth);
    try std.testing.expect(!report.runnable);
}
